param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
if(-not(Test-Path -LiteralPath $GitPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V11=FAIL git_missing=$GitPath"}
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V11=FAIL exact_head expected=$ExpectedSha actual=$actual"}
$v10=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV10.ps1'
if(-not(Test-Path -LiteralPath $v10 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V11=FAIL predecessor_missing=$v10"}

$targets=[ordered]@{
  character='src\game\isometric\characters\IsometricCharacter.as'
  animation='src\game\characters\AnimationController.as'
  patcher='Tools\CI\Patch-AndroidPerformanceSwf.ps1'
  runtimeTest='Tools\CI\Test-AndroidRuntimePatch.ps1'
  androidBuild='Tools\CI\Build-Android.ps1'
}
$installerPath=Join-Path $RepoRoot 'Tools\CI\Install-AndroidExactCandidate.ps1'
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v11\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'
function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Target-Path([string]$Key){Join-Path $RepoRoot ([string]$targets[$Key])}
function Backup-Path([string]$Key){Join-Path $backupRoot ($Key+'.post-v10')}
function Require-Token([string]$Text,[string]$Token,[string]$Name){if(-not $Text.Contains($Token)){throw "ANDROID_EVIDENCE_ROOTFIX_V11=FAIL verify=$Name token=$Token"}}
function Replace-LiteralOne([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $first=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($first -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V11=FAIL patch=$Name literal_missing"}
  $second=$Text.IndexOf($Needle,$first+$Needle.Length,[StringComparison]::Ordinal)
  if($second -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_V11=FAIL patch=$Name literal_ambiguous"}
  Write-Host "EVIDENCE_ROOTFIX_V11_HOOK=PASS name=$Name matches=1"
  return $Text.Substring(0,$first)+$Replacement+$Text.Substring($first+$Needle.Length)
}
function Replace-RegexOne([string]$Text,[string]$Pattern,[string]$Replacement,[string]$Name){
  $matches=[regex]::Matches($Text,$Pattern)
  if($matches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V11=FAIL patch=$Name semantic_match_count=$($matches.Count)"}
  Write-Host "EVIDENCE_ROOTFIX_V11_HOOK=PASS name=$Name matches=1"
  return [regex]::Replace($Text,$Pattern,$Replacement,1)
}

if($Mode -eq 'Restore'){
  if(Test-Path -LiteralPath $manifestPath -PathType Leaf){
    $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
    if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V11=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
    foreach($entry in @($manifest.files)){
      $key=[string]$entry.key
      $src=Backup-Path $key
      $dst=Target-Path $key
      if(-not(Test-Path -LiteralPath $src -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V11=FAIL restore_backup_missing key=$key"}
      Copy-Item -LiteralPath $src -Destination $dst -Force
      if((Get-Sha256 $dst) -ne ([string]$entry.sha256).ToUpperInvariant()){throw "ANDROID_EVIDENCE_ROOTFIX_V11=FAIL restore_hash key=$key"}
    }
    Remove-Item -LiteralPath $backupRoot -Recurse -Force
  }
  & $v10 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V11=PASS mode=restore baseline_restored=true predecessor=v10 sha=$ExpectedSha"
  return
}

& $v10 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
foreach($key in $targets.Keys){
  $path=Target-Path $key
  if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V11=FAIL required_file_missing key=$key path=$path"}
}
if(-not(Test-Path -LiteralPath $installerPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V11=FAIL installer_missing=$installerPath"}
$tokens=$null;$errors=$null
[void][System.Management.Automation.Language.Parser]::ParseFile($installerPath,[ref]$tokens,[ref]$errors)
if(@($errors).Count -gt 0){$errors|ForEach-Object{Write-Host "V11_INSTALLER_PARSER_ERROR line=$($_.Extent.StartLineNumber) message=$($_.Message)"};throw 'ANDROID_EVIDENCE_ROOTFIX_V11=FAIL installer_parser'}
Write-Host 'MANUAL_INSTALL_SCRIPT_PRECHECK=PASS exact_sha=true portable_adb=true parser=true'

if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
$manifestFiles=@()
foreach($key in $targets.Keys){
  $src=Target-Path $key
  Copy-Item -LiteralPath $src -Destination (Backup-Path $key) -Force
  $manifestFiles+=@([ordered]@{key=$key;path=[string]$targets[$key];sha256=(Get-Sha256 $src)})
}
[ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v11';source_sha=$ExpectedSha;predecessor='v10';files=$manifestFiles}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $manifestPath -Encoding UTF8

try{
  # Projectile now owns its own ENTER_FRAME clock (V7), therefore the unit must not
  # retain the last projectile after construction. SceneHud is the active owner while
  # the projectile is visible; Projectile.destroy() removes that display-list owner.
  $characterPath=Target-Path 'character'
  $character=Normalize-Lf ([IO.File]::ReadAllText($characterPath))
  $characterPattern='(?ms)\t\tprotected function addProjectile\(param1: Number, param2: Number\): void \{.*?\n\t\t\}\n\n\t\tprivate function getProjectileClass'
  $characterReplacement=@'
		protected function addProjectile(param1: Number, param2: Number): void {
			var _loc3_: Class = null;
			var detachedProjectile: Projectile = null;
			if (mItem is PlayerUnitItem && PlayerUnitItem(mItem).mProjectileClassStr || mItem is EnemyUnitItem && EnemyUnitItem(mItem).mProjectileClassStr) {
				_loc3_ = this.getProjectileClass(Object(mItem).mProjectileClassStr);
				if (_loc3_) {
					detachedProjectile = new _loc3_(this, param1, param2) as Projectile;
					Utils.DiagEvent("PROJECTILE_SCENE_OWNED", "owner=" + mItem.mId + ";spawned=" + (detachedProjectile != null) + ";attached=" + (detachedProjectile != null && detachedProjectile.parent != null));
					detachedProjectile = null;
					this.mProjectile = null;
				}
			}
		}

		private function getProjectileClass
'@
  $character=Replace-RegexOne $character $characterPattern $characterReplacement.TrimEnd() 'character_detaches_projectile_owner_reference'
  foreach($token in @('PROJECTILE_SCENE_OWNED','var detachedProjectile: Projectile = null;','this.mProjectile = null;')){Require-Token $character $token 'character_scene_owned_projectile'}
  if($character.Contains('this.mProjectile = new _loc3_')){throw 'ANDROID_EVIDENCE_ROOTFIX_V11=FAIL regression=strong_projectile_owner_reference_remaining'}
  if($character.Contains('PROJECTILE_OWNER_OVERLAP')){throw 'ANDROID_EVIDENCE_ROOTFIX_V11=FAIL regression=obsolete_projectile_overlap_reference_remaining'}
  Write-Utf8Bom $characterPath $character

  # V7's cleanup hook is reached from stopAnim as well as owner teardown. Keep the
  # telemetry truthful so ZIP diagnostics do not misclassify every early cleanup.
  $animationPath=Target-Path 'animation'
  $animation=Normalize-Lf ([IO.File]::ReadAllText($animationPath))
  $animation=Replace-LiteralOne $animation ';reason=owner_destroy;elapsed_real_ms=0;frames=' ';reason=stop_or_owner_destroy;elapsed_real_ms=0;frames=' 'explosion_cleanup_reason_truthful'
  Require-Token $animation 'reason=stop_or_owner_destroy' 'animation_cleanup_reason'
  Write-Utf8Bom $animationPath $animation

  # Candidate APKs must be update-compatible. Keep a stable debug-only P12 on the
  # portable AndroidBuild root. This key is never used for RELEASE / Play signing.
  $androidBuildPath=Target-Path 'androidBuild'
  $androidBuild=Normalize-Lf ([IO.File]::ReadAllText($androidBuildPath))
  $certPrelude=@'
$cert=Join-Path $buildRoot 'android-ci-signing.p12'
$certPass='ArmyAttackLocalCI'
if(Test-Path $cert){Remove-Item $cert -Force}
'@
  $stableCertPrelude=@'
$signingInfraRoot=@($env:ANDROIDBUILD_ROOT,$AndroidBuildRoot)|Where-Object{$_ -and (Test-Path -LiteralPath $_ -PathType Container)}|Select-Object -First 1
if(-not $signingInfraRoot){throw 'ANDROID_CERT=FAIL stable_signing_root_missing'}
$signingInfraRoot=(Resolve-Path -LiteralPath $signingInfraRoot).Path
$signingRoot=Join-Path $signingInfraRoot 'State\signing\armyattack-candidate'
New-Item -ItemType Directory -Force -Path $signingRoot|Out-Null
$cert=Join-Path $signingRoot 'armyattack-candidate-debug.p12'
# Candidate/debug password is intentionally non-secret; the private key itself remains local to AndroidBuild and is never committed.
$certPass='ArmyAttackCandidateDebug'
$certCreated=$false
if(-not(Test-Path -LiteralPath $cert -PathType Leaf)){
  $tempCert=Join-Path $signingRoot ("armyattack-candidate-debug.$PID.tmp.p12")
  Remove-Item -LiteralPath $tempCert -Force -ErrorAction SilentlyContinue
  try{
    $certArgs=@('-certificate','-cn','ArmyAttackAndroidCandidateDebug','-ou','CandidateOnly','-o','ValverdeLocalBuild','-c','PE','2048-RSA',$tempCert,$certPass)
    $certProcess=Start-Process -FilePath $air.Adt -ArgumentList $certArgs -WorkingDirectory $buildRoot -NoNewWindow -PassThru -Wait
    if($certProcess.ExitCode -ne 0 -or -not(Test-Path -LiteralPath $tempCert -PathType Leaf)){throw "ANDROID_CERT=FAIL create_stable_candidate exit=$($certProcess.ExitCode)"}
    Move-Item -LiteralPath $tempCert -Destination $cert -Force
    $certCreated=$true
  }finally{
    Remove-Item -LiteralPath $tempCert -Force -ErrorAction SilentlyContinue
  }
}
$certSha=(Get-FileHash -LiteralPath $cert -Algorithm SHA256).Hash.ToUpperInvariant()
$signingMarker=Join-Path $signingRoot 'CANDIDATE-ONLY.txt'
if(-not(Test-Path -LiteralPath $signingMarker -PathType Leaf)){
  @('Army Attack stable local candidate/debug signing identity.','Never use this key for RELEASE or Play Store signing.','Purpose: permit adb install -r across candidate builds without deleting app data.')|Set-Content -LiteralPath $signingMarker -Encoding UTF8
}
Write-Host "ANDROID_CERT_PROFILE=PASS profile=stable-local-debug-v1 candidate_only=true persistent=true created=$certCreated cert_sha256=$certSha root=$signingRoot"
'@
  $androidBuild=Replace-LiteralOne $androidBuild $certPrelude.TrimEnd() $stableCertPrelude.TrimEnd() 'stable_candidate_signing_prelude'
  $oldCertCreate=@'
  $certArgs=@('-certificate','-cn','ArmyAttackAndroidCI','-ou','Dev','-o','ValverdeLocalBuild','-c','PE','2048-RSA',$cert,$certPass)
  $p=Start-Process -FilePath $air.Adt -ArgumentList $certArgs -WorkingDirectory $buildRoot -NoNewWindow -PassThru -Wait
  if($p.ExitCode -ne 0 -or -not (Test-Path $cert)){throw "ANDROID_CERT=FAIL exit=$($p.ExitCode)"}
  Write-Host "ANDROID_CERT=PASS"
'@
  $newCertCheck=@'
  if(-not(Test-Path -LiteralPath $cert -PathType Leaf)){throw "ANDROID_CERT=FAIL persistent_candidate_key_missing path=$cert"}
  Write-Host "ANDROID_CERT=PASS profile=stable-local-debug-v1 candidate_only=true persistent=true cert_sha256=$certSha"
'@
  $androidBuild=Replace-LiteralOne $androidBuild $oldCertCreate.TrimEnd() $newCertCheck.TrimEnd() 'stable_candidate_signing_package_use'
  $oldFinally=@'
}finally{
  Remove-Item -LiteralPath $cert -Force -ErrorAction SilentlyContinue
  Write-Host "ANDROID_CERT_CLEANUP=PASS"
}
'@
  $newFinally=@'
}finally{
  Write-Host "ANDROID_CERT_CLEANUP=PASS persistent_candidate_key_preserved=true profile=stable-local-debug-v1"
}
'@
  $androidBuild=Replace-LiteralOne $androidBuild $oldFinally.TrimEnd() $newFinally.TrimEnd() 'stable_candidate_signing_persist'
  foreach($token in @('stable-local-debug-v1','State\signing\armyattack-candidate','persistent_candidate_key_preserved=true','Never use this key for RELEASE or Play Store signing.')){Require-Token $androidBuild $token 'stable_candidate_signing'}
  if($androidBuild.Contains('$cert=Join-Path $buildRoot ''android-ci-signing.p12''')){throw 'ANDROID_EVIDENCE_ROOTFIX_V11=FAIL regression=ephemeral_candidate_cert_remaining'}
  Write-Utf8Bom $androidBuildPath $androidBuild

  $patcherPath=Target-Path 'patcher'
  $patcher=Normalize-Lf ([IO.File]::ReadAllText($patcherPath))
  $patcher=Replace-LiteralOne $patcher '$patchVersion=''mobile-engine-v3.27-projectile-autotick-hfe-v7''' '$patchVersion=''mobile-engine-v3.28-scene-owned-projectile-stable-signing-v11''' 'patch_version_v3_28_v11'
  Write-Utf8Bom $patcherPath $patcher

  # Migrate the regression contract after V8/V9/V10 have composed their checks.
  $testPath=Target-Path 'runtimeTest'
  $test=Normalize-Lf ([IO.File]::ReadAllText($testPath))
  $oldOverlap="Require-Contains `$character 'PROJECTILE_OWNER_OVERLAP' 'rapid_fire_overlap_is_observable'"
  $newOwnership=@'
Require-Contains $character 'PROJECTILE_SCENE_OWNED' 'projectile_scene_ownership_is_observable'
Require-Contains $character 'var detachedProjectile: Projectile = null;' 'projectile_spawn_uses_method_local_reference'
Require-Contains $character 'this.mProjectile = null;' 'character_projectile_owner_reference_is_cleared'
Require-NotContains $character 'this.mProjectile = new _loc3_' 'character_does_not_retain_spawned_projectile'
Require-NotContains $character 'PROJECTILE_OWNER_OVERLAP' 'obsolete_projectile_overlap_reference_removed'
Require-Contains $animation 'reason=stop_or_owner_destroy' 'explosion_cleanup_reason_matches_actual_paths'
Require-NotContains $animation 'reason=owner_destroy;elapsed_real_ms=0' 'misleading_explosion_cleanup_reason_removed'
Require-Contains $androidBuild 'profile=stable-local-debug-v1' 'candidate_signing_profile_is_stable'
Require-Contains $androidBuild 'State\signing\armyattack-candidate' 'candidate_signing_key_is_androidbuild_owned'
Require-Contains $androidBuild 'persistent_candidate_key_preserved=true' 'candidate_signing_key_survives_builds'
'@
  $test=Replace-LiteralOne $test $oldOverlap $newOwnership.TrimEnd() 'runtime_test_scene_owned_projectile_and_signing_contract'
  foreach($required in @('projectile_scene_ownership_is_observable','character_does_not_retain_spawned_projectile','explosion_cleanup_reason_matches_actual_paths','candidate_signing_profile_is_stable','candidate_signing_key_survives_builds')){
    if(-not $test.Contains($required)){throw "ANDROID_EVIDENCE_ROOTFIX_V11=FAIL verification_missing=$required"}
  }
  Write-Utf8Bom $testPath $test

  Write-Host 'REGRESSION_CHECK=PASS name=projectile_lifecycle_scene_owned owner_strong_reference=false enter_frame_self_clock=true'
  Write-Host 'REGRESSION_CHECK=PASS name=explosion_cleanup_telemetry_truthful reasons=final_frame,wallclock_timeout,stop_or_owner_destroy'
  Write-Host 'REGRESSION_CHECK=PASS name=candidate_signing_is_stable profile=stable-local-debug-v1 persistence=androidbuild-state release_key=false'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V11=PASS mode=apply sha=$ExpectedSha schema=v11 predecessor=v10"
}catch{
  $failure=$_
  foreach($key in $targets.Keys){
    $src=Backup-Path $key
    if(Test-Path -LiteralPath $src -PathType Leaf){Copy-Item -LiteralPath $src -Destination (Target-Path $key) -Force}
  }
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  try{& $v10 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore}catch{Write-Host "ANDROID_EVIDENCE_ROOTFIX_V11_RESTORE_AFTER_FAILURE=FAIL message=$($_.Exception.Message)"}
  throw $failure
}
