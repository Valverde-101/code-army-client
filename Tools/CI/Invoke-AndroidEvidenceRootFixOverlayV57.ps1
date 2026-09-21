# Apply V56 first. Embed the separately versioned unit-upgrade catalog in both
# authored config variants without rewriting their large, source-owned JSON.
# The published mobile binary uses an embedded root SWF; standalone SWF
# loading is shimmed to dummy.json, so the popup is part of GameHUD's root SWF.
param(
 [Parameter(Mandatory=$true)][string]$RepoRoot,
 [Parameter(Mandatory=$true)][string]$ExpectedSha,
 [Parameter(Mandatory=$true)][string]$GitPath,
 [ValidateSet('Apply','Restore')][string]$RequestedMode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
$head=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $head -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V57=FAIL exact_head expected=$ExpectedSha actual=$head"}
$predecessor=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV56.ps1'
$catalog=Join-Path $RepoRoot 'src\config\unit_upgrades.json'
$targets=@('src\config\army_config_base.json','src\config\army_config.json')
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v57\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'
function Sha([string]$p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToUpperInvariant()}
function Restore-V57 {
 if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){return}
 $m=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
 if([string]$m.source_sha -ne $ExpectedSha){throw 'ANDROID_EVIDENCE_ROOTFIX_V57=FAIL restore_manifest_sha'}
 foreach($entry in @($m.files)){
  $src=Join-Path $backupRoot ([string]$entry.backup)
  $dest=Join-Path $RepoRoot ([string]$entry.path)
  if(-not(Test-Path -LiteralPath $src -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V57=FAIL restore_backup_missing=$src"}
  Copy-Item -LiteralPath $src -Destination $dest -Force
  if((Sha $dest) -ne ([string]$entry.sha256).ToUpperInvariant()){throw "ANDROID_EVIDENCE_ROOTFIX_V57=FAIL restore_hash=$dest"}
 }
 Remove-Item -LiteralPath $backupRoot -Recurse -Force
 Write-Host "ANDROID_EVIDENCE_ROOTFIX_V57_OWNED_RESTORE=PASS files=2 sha=$ExpectedSha"
}
if($RequestedMode -eq 'Restore'){
 Restore-V57
 & $predecessor -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -RequestedMode Restore
 Write-Host "ANDROID_EVIDENCE_ROOTFIX_V57=PASS mode=restore sha=$ExpectedSha"
 return
}
$v56Applied=$false
try {
 & $predecessor -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -RequestedMode Apply
 $v56Applied=$true
 if(-not(Test-Path -LiteralPath $catalog -PathType Leaf)){throw 'ANDROID_EVIDENCE_ROOTFIX_V57=FAIL catalog_missing'}
 $raw=[IO.File]::ReadAllText($catalog)
 $config=$raw|ConvertFrom-Json
 if([string]$config.schema -ne 'armyattack-unit-upgrades/v1' -or [string]$config.scope -ne 'individual'){throw 'ANDROID_EVIDENCE_ROOTFIX_V57=FAIL catalog_schema'}
 $allowed=@('ArmoredCar','SpecialForces')
 if(@($config.units.PSObject.Properties).Count -ne 2){throw 'ANDROID_EVIDENCE_ROOTFIX_V57=FAIL unexpected_catalog_count'}
 foreach($unit in $allowed){
  $entry=$config.units.$unit.Level1
  if(-not $entry -or @($entry.Materials).Count -ne 3 -or [int]$entry.Health -lt 1 -or [int]$entry.Damage -lt 1 -or [int]$entry.AttackRange -lt 1){throw "ANDROID_EVIDENCE_ROOTFIX_V57=FAIL invalid_recipe=$unit"}
  $unique=@{}
  foreach($mat in @($entry.Materials)){
   if([int]$mat.Amount -ne 5 -or [string]::IsNullOrWhiteSpace([string]$mat.ID) -or $unique.ContainsKey([string]$mat.ID)){throw "ANDROID_EVIDENCE_ROOTFIX_V57=FAIL invalid_material=$unit"}
   $unique[[string]$mat.ID]=$true
  }
 }
 if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
 New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
 $manifest=@()
 for($i=0;$i -lt $targets.Count;$i++){
  $path=$targets[$i];$full=Join-Path $RepoRoot $path;$copy='config-'+$i+'.json'
  $baseline=Sha $full
  Copy-Item -LiteralPath $full -Destination (Join-Path $backupRoot $copy) -Force
  $manifest+=@([ordered]@{path=$path;backup=$copy;sha256=$baseline})
 }
 [ordered]@{source_sha=$ExpectedSha;files=$manifest}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $manifestPath -Encoding UTF8
 $unitJson=$config.units|ConvertTo-Json -Depth 8 -Compress
 foreach($path in $targets){
  $full=Join-Path $RepoRoot $path
  $content=[IO.File]::ReadAllText($full)
  if([regex]::Matches($content,'(?m)^\s*"UnitUpgrade"\s*:').Count -gt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V57=FAIL duplicate_catalog=$path"}
  $open=$content.IndexOf('{')
  if($open -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V57=FAIL config_root_missing=$path"}
  $updated=$content.Substring(0,$open+1)+"`n  `"UnitUpgrade`": "+$unitJson+','+$content.Substring($open+1)
  # Do not round-trip the legacy authored config through ConvertFrom-Json here.
  # It intentionally contains case-distinct keys such as ID/id that PowerShell
  # 5.1 collapses case-insensitively. Validate only the injected V57 fragment;
  # the existing config parser/build remains the authority for the legacy body.
  if([regex]::Matches($updated,'(?m)^\s*"UnitUpgrade"\s*:').Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V57=FAIL config_injection_count=$path"}
  if($updated.IndexOf('"ArmoredCar"',[StringComparison]::Ordinal) -lt 0 -or $updated.IndexOf('"SpecialForces"',[StringComparison]::Ordinal) -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V57=FAIL config_injection=$path"}
  [IO.File]::WriteAllText($full,$updated,(New-Object System.Text.UTF8Encoding($true)))
  Write-Host "UNIT_UPGRADE_CONFIG=PASS path=$path units=2 base_sha=$baseline validator=fragment_case_sensitive"
 }
 foreach($required in @('canOfflineUpgrade','applyOfflineUpgrade','unit_upgrade_level','openUnitUpgradeForSelection')){
  $p=if($required -eq 'unit_upgrade_level'){'src\game\utils\OfflineSave.as'}elseif($required -eq 'openUnitUpgradeForSelection'){'src\game\gui\GameHUD.as'}else{'src\game\characters\PlayerUnit.as'}
  if(-not([IO.File]::ReadAllText((Join-Path $RepoRoot $p)).Contains($required))){throw "ANDROID_EVIDENCE_ROOTFIX_V57=FAIL code_missing=$required"}
 }
 Write-Host "ANDROID_EVIDENCE_ROOTFIX_V57=PASS mode=apply sha=$ExpectedSha catalog=individual materials=inventory_only root_swf=embedded validator=fragment_case_sensitive"
}catch {
 $failed=$_
 try{Restore-V57}catch{Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V57_RESTORE_WARN $($_.Exception.Message)"}
 if($v56Applied){try{& $predecessor -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -RequestedMode Restore}catch{Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V57_PREDECESSOR_ROLLBACK_WARN $($_.Exception.Message)"}}
 throw $failed
}
