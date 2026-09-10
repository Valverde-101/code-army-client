param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
if(-not(Test-Path -LiteralPath $GitPath -PathType Leaf)){throw "SNOW_REFERENCE_CLOSURE=FAIL git_missing=$GitPath"}
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "SNOW_REFERENCE_CLOSURE=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$targetPath=Join-Path $RepoRoot 'src\config\army_config_base.json'
$donorPath=Join-Path $RepoRoot 'vendor\Test_army_attack\armyattack\config\army_config_base.json'
$backupPath=Join-Path $RepoRoot ('.work\scratch\snow-campaign-overlay\'+$ExpectedSha+'\army_config_base.original.json')
foreach($required in @($targetPath,$donorPath,$backupPath)){
  if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw "SNOW_REFERENCE_CLOSURE=FAIL required_missing=$required"}
}

function Clone-JsonValue($Value){(($Value|ConvertTo-Json -Depth 100 -Compress)|ConvertFrom-Json)}
function Set-JsonProperty($Target,[string]$Name,$Value){
  $existing=$Target.PSObject.Properties[$Name]
  if($null -ne $existing){$existing.Value=$Value}else{$Target|Add-Member -MemberType NoteProperty -Name $Name -Value $Value}
}
function Test-TableObject($Value){
  return ($null -ne $Value -and -not($Value -is [System.Array]) -and -not($Value -is [string]) -and -not($Value -is [ValueType]))
}
function Get-Row($Config,[string]$Section,[string]$Row){
  if($null -eq $Config){return $null}
  $sectionProperty=$Config.PSObject.Properties[$Section]
  if($null -eq $sectionProperty -or -not(Test-TableObject $sectionProperty.Value)){return $null}
  $rowProperty=$sectionProperty.Value.PSObject.Properties[$Row]
  if($null -eq $rowProperty){return $null}
  return $rowProperty.Value
}
function Test-RowExists($Config,[string]$Section,[string]$Row){
  if($null -eq $Config){return $false}
  $sectionProperty=$Config.PSObject.Properties[$Section]
  if($null -eq $sectionProperty -or -not(Test-TableObject $sectionProperty.Value)){return $false}
  return ($null -ne $sectionProperty.Value.PSObject.Properties[$Row])
}
function Get-ConfigReferences($Config){
  $results=New-Object System.Collections.Generic.List[object]
  if($null -eq $Config){return @()}
  foreach($sectionProperty in @($Config.PSObject.Properties)){
    $sourceSection=[string]$sectionProperty.Name
    $section=$sectionProperty.Value
    if(-not(Test-TableObject $section)){continue}
    foreach($rowProperty in @($section.PSObject.Properties)){
      $sourceRow=[string]$rowProperty.Name
      $row=$rowProperty.Value
      if(-not(Test-TableObject $row)){continue}
      foreach($fieldProperty in @($row.PSObject.Properties)){
        $sourceField=[string]$fieldProperty.Name
        $value=$fieldProperty.Value
        if($null -eq $value){continue}
        try{
          if($value -is [string]){$text=[string]$value}
          else{$text=$value|ConvertTo-Json -Depth 100 -Compress}
        }catch{continue}
        foreach($match in [regex]::Matches($text,'#(?<section>[A-Za-z0-9_]+)\.(?<row>[A-Za-z0-9_\-:]+)')){
          $targetSection=[string]$match.Groups['section'].Value
          $targetRow=[string]$match.Groups['row'].Value
          # TID is supplied/overlaid by the active language JSON at runtime. Do not
          # force language rows into the base config dependency graph here.
          if($targetSection -eq 'TID'){continue}
          $results.Add([pscustomobject]@{
            source_section=$sourceSection
            source_row=$sourceRow
            source_field=$sourceField
            reference=[string]$match.Value
            target_section=$targetSection
            target_row=$targetRow
            key=($sourceSection+'|'+$sourceRow+'|'+$sourceField+'|'+$targetSection+'|'+$targetRow)
            target_key=($targetSection+'|'+$targetRow)
          })
        }
      }
    }
  }
  return @($results)
}
function Get-UnresolvedReferences($Config){
  $missing=New-Object System.Collections.Generic.List[object]
  foreach($reference in @(Get-ConfigReferences $Config)){
    if(-not(Test-RowExists $Config ([string]$reference.target_section) ([string]$reference.target_row))){$missing.Add($reference)}
  }
  return @($missing)
}

$target=Get-Content -LiteralPath $targetPath -Raw|ConvertFrom-Json
$donor=Get-Content -LiteralPath $donorPath -Raw|ConvertFrom-Json
$baseline=Get-Content -LiteralPath $backupPath -Raw|ConvertFrom-Json
$baselineMissing=@{}
foreach($reference in @(Get-UnresolvedReferences $baseline)){$baselineMissing[[string]$reference.key]=$true}

$dependencyEntries=0
$round=0
while($true){
  $round++
  if($round -gt 100){throw 'SNOW_REFERENCE_CLOSURE=FAIL reason=max_rounds_exceeded'}
  $newMissing=@(Get-UnresolvedReferences $target|Where-Object{-not $baselineMissing.ContainsKey([string]$_.key)})
  if($newMissing.Count -eq 0){break}
  $addedThisRound=0
  $processedTargets=@{}
  foreach($reference in $newMissing){
    $targetKey=[string]$reference.target_key
    if($processedTargets.ContainsKey($targetKey)){continue}
    $processedTargets[$targetKey]=$true
    if(Test-RowExists $target ([string]$reference.target_section) ([string]$reference.target_row)){continue}
    $donorRow=Get-Row $donor ([string]$reference.target_section) ([string]$reference.target_row)
    if($null -eq $donorRow){
      throw "SNOW_REFERENCE_CLOSURE=FAIL source=$($reference.source_section).$($reference.source_row).$($reference.source_field) reference=$($reference.reference) target=$($reference.target_section).$($reference.target_row) reason=missing_in_target_and_donor"
    }
    $targetSectionProperty=$target.PSObject.Properties[[string]$reference.target_section]
    if($null -eq $targetSectionProperty){
      $targetSection=[pscustomobject]@{}
      Set-JsonProperty $target ([string]$reference.target_section) $targetSection
    }else{
      $targetSection=$targetSectionProperty.Value
      if(-not(Test-TableObject $targetSection)){throw "SNOW_REFERENCE_CLOSURE=FAIL target_section_not_object section=$($reference.target_section)"}
    }
    Set-JsonProperty $targetSection ([string]$reference.target_row) (Clone-JsonValue $donorRow)
    $dependencyEntries++
    $addedThisRound++
    Write-Host "SNOW_REFERENCE_DEPENDENCY=ADD source=$($reference.source_section).$($reference.source_row).$($reference.source_field) reference=$($reference.reference) target=$($reference.target_section).$($reference.target_row)"
  }
  if($addedThisRound -eq 0){
    $sample=$newMissing|Select-Object -First 1
    throw "SNOW_REFERENCE_CLOSURE=FAIL reason=no_progress source=$($sample.source_section).$($sample.source_row).$($sample.source_field) reference=$($sample.reference)"
  }
}

$finalNewMissing=@(Get-UnresolvedReferences $target|Where-Object{-not $baselineMissing.ContainsKey([string]$_.key)})
if($finalNewMissing.Count -gt 0){
  $sample=$finalNewMissing|Select-Object -First 1
  throw "SNOW_REFERENCE_CLOSURE=FAIL reason=unresolved_after_closure count=$($finalNewMissing.Count) source=$($sample.source_section).$($sample.source_row).$($sample.source_field) reference=$($sample.reference)"
}
if((Test-RowExists $target 'Mission' 'SaveMission2') -and -not(Test-RowExists $target 'Objective' 'SaveMission2')){
  throw 'SNOW_REFERENCE_CLOSURE=FAIL regression=SaveMission2_objective_missing'
}

$target|ConvertTo-Json -Depth 100|Set-Content -LiteralPath $targetPath -Encoding UTF8
$verify=Get-Content -LiteralPath $targetPath -Raw|ConvertFrom-Json
$verifyNewMissing=@(Get-UnresolvedReferences $verify|Where-Object{-not $baselineMissing.ContainsKey([string]$_.key)})
if($verifyNewMissing.Count -gt 0){throw "SNOW_REFERENCE_CLOSURE=FAIL serialization_regression unresolved=$($verifyNewMissing.Count)"}
$saveMission2Status=if(Test-RowExists $verify 'Mission' 'SaveMission2'){if(Test-RowExists $verify 'Objective' 'SaveMission2'){'complete'}else{'broken'}}else{'not_present'}
Write-Host "SNOW_REFERENCE_CLOSURE=PASS baseline_unresolved=$($baselineMissing.Count) dependency_entries=$dependencyEntries rounds=$round final_new_unresolved=0 save_mission2=$saveMission2Status"
