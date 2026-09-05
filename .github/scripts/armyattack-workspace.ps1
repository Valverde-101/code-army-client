Set-StrictMode -Version Latest

function Remove-ArmyLinkOrTree {
  param([Parameter(Mandatory=$true)][string]$Path)
  if(-not(Test-Path -LiteralPath $Path)){return}
  $item=Get-Item -LiteralPath $Path -Force
  if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){
    $cmd=(Get-Command cmd.exe -ErrorAction Stop).Source
    & $cmd /d /c ('rmdir "{0}"' -f $Path) | Out-Null
    if($LASTEXITCODE -ne 0 -and (Test-Path -LiteralPath $Path)){throw "ARMY_WORKSPACE=FAIL remove_junction path=$Path exit=$LASTEXITCODE"}
  } else {
    Remove-Item -LiteralPath $Path -Recurse -Force
  }
}

function Ensure-ArmyJunction {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Target
  )
  $targetFull=[IO.Path]::GetFullPath($Target).TrimEnd('\')
  if(-not(Test-Path -LiteralPath $targetFull)){throw "ARMY_WORKSPACE=FAIL junction_target_missing path=$Path target=$targetFull"}
  if(Test-Path -LiteralPath $Path){
    $item=Get-Item -LiteralPath $Path -Force
    $current=$null
    try{$current=$item.Target;if($current -is [array]){$current=$current|Select-Object -First 1}}catch{}
    if($current){
      $currentFull=[IO.Path]::GetFullPath([string]$current).TrimEnd('\')
      if($currentFull -ieq $targetFull){return}
    }
    Remove-ArmyLinkOrTree -Path $Path
  }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path)|Out-Null
  New-Item -ItemType Junction -Path $Path -Target $targetFull|Out-Null
}

function Ensure-ArmyHardLink {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Target
  )
  $targetFull=(Resolve-Path -LiteralPath $Target).Path
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path)|Out-Null
  if(Test-Path -LiteralPath $Path){Remove-Item -LiteralPath $Path -Force}
  try{
    New-Item -ItemType HardLink -Path $Path -Target $targetFull -ErrorAction Stop|Out-Null
  }catch{
    throw "ARMY_WORKSPACE=FAIL hardlink path=$Path target=$targetFull message=$($_.Exception.Message)"
  }
  $srcHash=(Get-FileHash -LiteralPath $targetFull -Algorithm SHA256).Hash
  $dstHash=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
  if($srcHash -ne $dstHash){throw "ARMY_WORKSPACE=FAIL hardlink_hash path=$Path"}
  Write-Host "ARMY_GLOBAL_TOOL_HARDLINK=PASS name=$([IO.Path]::GetFileName($Path)) target=$targetFull duplicated_bytes=false"
}

function Find-ArmyGlobalSdkTool {
  param(
    [Parameter(Mandatory=$true)][string[]]$Roots,
    [Parameter(Mandatory=$true)][string]$Name
  )
  foreach($candidateRoot in $Roots|Select-Object -Unique){
    if(-not $candidateRoot -or -not(Test-Path -LiteralPath $candidateRoot)){continue}
    $found=Get-ChildItem -LiteralPath $candidateRoot -Recurse -File -ErrorAction SilentlyContinue|Where-Object{$_.Name -ieq $Name}|Sort-Object FullName|Select-Object -First 1
    if($found){return $found.FullName}
  }
  return $null
}

function Merge-ArmyInputCache {
  param(
    [Parameter(Mandatory=$true)][string]$Source,
    [Parameter(Mandatory=$true)][string]$Destination
  )
  if(-not(Test-Path -LiteralPath $Source)){return 0}
  $srcItem=Get-Item -LiteralPath $Source -Force
  if($srcItem.Attributes -band [IO.FileAttributes]::ReparsePoint){Remove-ArmyLinkOrTree -Path $Source;return 0}
  New-Item -ItemType Directory -Force -Path $Destination|Out-Null
  $files=@(Get-ChildItem -LiteralPath $Source -Recurse -File -Force -ErrorAction SilentlyContinue)
  $moved=0
  foreach($file in $files){
    $relative=$file.FullName.Substring($Source.Length).TrimStart('\','/')
    $dest=Join-Path $Destination $relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest)|Out-Null
    if(Test-Path -LiteralPath $dest){
      $destInfo=Get-Item -LiteralPath $dest
      if($destInfo.Length -ne $file.Length){throw "ARMY_INPUT_CACHE=FAIL collision_size path=$relative"}
      $srcHash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
      $dstHash=(Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
      if($srcHash -ne $dstHash){throw "ARMY_INPUT_CACHE=FAIL collision_hash path=$relative"}
      Remove-Item -LiteralPath $file.FullName -Force
    } else {
      Move-Item -LiteralPath $file.FullName -Destination $dest
      $moved++
    }
  }
  if(Test-Path -LiteralPath $Source){Remove-Item -LiteralPath $Source -Recurse -Force -ErrorAction SilentlyContinue}
  return $moved
}

function Merge-ArmyBuildGenerations {
  param(
    [Parameter(Mandatory=$true)][string]$Source,
    [Parameter(Mandatory=$true)][string]$Destination
  )
  if(-not(Test-Path -LiteralPath $Source)){return 0}
  $srcItem=Get-Item -LiteralPath $Source -Force
  if($srcItem.Attributes -band [IO.FileAttributes]::ReparsePoint){Remove-ArmyLinkOrTree -Path $Source;return 0}
  New-Item -ItemType Directory -Force -Path $Destination|Out-Null
  $moved=0
  $dirs=@(Get-ChildItem -LiteralPath $Source -Directory -Force -ErrorAction SilentlyContinue|Where-Object{$_.Name -match '^[a-f0-9]{40}$'}|Sort-Object LastWriteTimeUtc -Descending)
  foreach($dir in $dirs){
    $dest=Join-Path $Destination $dir.Name
    if(Test-Path -LiteralPath $dest){Remove-Item -LiteralPath $dir.FullName -Recurse -Force}
    else{Move-Item -LiteralPath $dir.FullName -Destination $dest;$moved++}
  }
  if(Test-Path -LiteralPath $Source){Remove-Item -LiteralPath $Source -Recurse -Force -ErrorAction SilentlyContinue}
  return $moved
}

function Remove-ArmyScratchResidue {
  param([Parameter(Mandatory=$true)][string]$ScratchRoot)
  if(-not(Test-Path -LiteralPath $ScratchRoot)){return 0}
  $removed=0
  foreach($child in @(Get-ChildItem -LiteralPath $ScratchRoot -Force -ErrorAction SilentlyContinue)){
    if($child.Name -match '(?i)army|code-army-client'){Remove-ArmyLinkOrTree -Path $child.FullName;$removed++}
  }
  return $removed
}

function Invoke-ArmyAttackBuildRetention {
  param(
    [Parameter(Mandatory=$true)][string]$BuildRoot,
    [Parameter(Mandatory=$true)][string]$ExpectedSha,
    [int]$Keep=3
  )
  if($Keep -lt 1){throw 'ARMY_BUILD_RETENTION=FAIL keep_lt_1'}
  New-Item -ItemType Directory -Force -Path $BuildRoot|Out-Null
  $current=Join-Path $BuildRoot $ExpectedSha
  if(Test-Path -LiteralPath $current){(Get-Item -LiteralPath $current).LastWriteTimeUtc=[DateTime]::UtcNow}
  $dirs=@(Get-ChildItem -LiteralPath $BuildRoot -Directory -ErrorAction SilentlyContinue|Where-Object{$_.Name -match '^[a-f0-9]{40}$'}|Sort-Object LastWriteTimeUtc -Descending)
  $keepNames=New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
  if(Test-Path -LiteralPath $current){[void]$keepNames.Add($ExpectedSha)}
  foreach($dir in $dirs){if($keepNames.Count -lt $Keep){[void]$keepNames.Add($dir.Name)}}
  foreach($dir in $dirs){if(-not $keepNames.Contains($dir.Name)){Remove-Item -LiteralPath $dir.FullName -Recurse -Force}}
  $remaining=@(Get-ChildItem -LiteralPath $BuildRoot -Directory -ErrorAction SilentlyContinue|Where-Object{$_.Name -match '^[a-f0-9]{40}$'})
  if($remaining.Count -gt $Keep){throw "ARMY_BUILD_RETENTION=FAIL count=$($remaining.Count) maximum=$Keep"}
  Write-Host "ARMY_BUILD_RETENTION=PASS count=$($remaining.Count) maximum=$Keep shas=$((@($remaining.Name|Sort-Object)) -join ',')"
}

function Initialize-ArmyAttackWorkspace {
  param(
    [Parameter(Mandatory=$true)][string]$RepoRoot,
    [Parameter(Mandatory=$true)][string]$AndroidBuildRoot,
    [Parameter(Mandatory=$true)][string]$PinnedAndroidBuildRoot,
    [Parameter(Mandatory=$true)][string]$ExpectedSha,
    [Parameter(Mandatory=$true)][string]$AirHome,
    [Parameter(Mandatory=$true)][string]$AndroidSdk,
    [int]$RetentionGenerations=3
  )
  $repoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
  $root=(Resolve-Path -LiteralPath $AndroidBuildRoot).Path
  $pinned=(Resolve-Path -LiteralPath $PinnedAndroidBuildRoot).Path
  $globalSdk=(Resolve-Path -LiteralPath $AndroidSdk).Path
  $work=Join-Path $repoRoot '.work'
  $build=Join-Path $work 'build'
  $inputCache=Join-Path $work 'cache\inputs'
  $scratch=Join-Path $work 'scratch'
  $scratchCurrent=Join-Path $scratch 'current'
  $runtime=Join-Path $work 'runtime\AndroidBuild'
  foreach($path in @($build,$inputCache,$scratch,$runtime)){New-Item -ItemType Directory -Force -Path $path|Out-Null}
  if(Test-Path -LiteralPath $scratchCurrent){Remove-Item -LiteralPath $scratchCurrent -Recurse -Force}
  New-Item -ItemType Directory -Force -Path $scratchCurrent|Out-Null

  $legacyRoots=@($root,$pinned,(Split-Path -Parent $pinned))|Where-Object{$_}|Select-Object -Unique
  $legacyBuildInternal=Join-Path $work 'Builds\code-army-client'
  [void](Merge-ArmyBuildGenerations -Source $legacyBuildInternal -Destination $build)
  $movedInputs=0;$movedBuilds=0;$scratchRemoved=0
  foreach($legacyRoot in $legacyRoots){
    $legacyBuild=Join-Path $legacyRoot 'Builds\code-army-client'
    if([IO.Path]::GetFullPath($legacyBuild).TrimEnd('\') -ine [IO.Path]::GetFullPath((Join-Path $runtime 'Builds\code-army-client')).TrimEnd('\')){$movedBuilds += (Merge-ArmyBuildGenerations -Source $legacyBuild -Destination $build)}
    $legacyInputs=Join-Path $legacyRoot 'Inputs\code-army-client'
    if([IO.Path]::GetFullPath($legacyInputs).TrimEnd('\') -ine [IO.Path]::GetFullPath((Join-Path $runtime 'Inputs\code-army-client')).TrimEnd('\')){$movedInputs += (Merge-ArmyInputCache -Source $legacyInputs -Destination $inputCache)}
    $scratchRemoved += (Remove-ArmyScratchResidue -ScratchRoot (Join-Path $legacyRoot 'Scratch'))
  }

  Ensure-ArmyJunction -Path (Join-Path $runtime 'Builds\code-army-client') -Target $build
  Ensure-ArmyJunction -Path (Join-Path $runtime 'Inputs\code-army-client') -Target $inputCache
  Ensure-ArmyJunction -Path (Join-Path $runtime 'Scratch\code-army-client') -Target $scratchCurrent

  $globalGit=Join-Path $root 'Tools\Git'
  if(Test-Path -LiteralPath $globalGit){Ensure-ArmyJunction -Path (Join-Path $runtime 'Tools\Git') -Target $globalGit}
  $globalJava=Join-Path $root 'Tools\Java'
  if(Test-Path -LiteralPath $globalJava){Ensure-ArmyJunction -Path (Join-Path $runtime 'Tools\Java') -Target $globalJava}
  Ensure-ArmyJunction -Path (Join-Path $runtime 'Tools\AIRSDK-50.2.3.6') -Target $AirHome
  $air32=Join-Path $pinned 'Tools\AIRSDK-32'
  if(Test-Path -LiteralPath $air32){Ensure-ArmyJunction -Path (Join-Path $runtime 'Tools\AIRSDK-32') -Target $air32}

  # Android SDK compatibility facade. Directory junctions remain for direct exact paths; recursive legacy discovery uses hardlinked files.
  $runtimeSdk=Join-Path $runtime 'AndroidSDK'
  if(Test-Path -LiteralPath $runtimeSdk){Remove-ArmyLinkOrTree -Path $runtimeSdk}
  New-Item -ItemType Directory -Force -Path $runtimeSdk|Out-Null
  foreach($name in @('platforms','platform-tools','licenses')){
    $source=Join-Path $globalSdk $name
    if(Test-Path -LiteralPath $source){Ensure-ArmyJunction -Path (Join-Path $runtimeSdk $name) -Target $source}
  }
  $runtimeBuildTools=Join-Path $runtimeSdk 'build-tools'
  New-Item -ItemType Directory -Force -Path $runtimeBuildTools|Out-Null
  $exactBuildTools=Join-Path $globalSdk 'build-tools\33.0.2'
  if(-not(Test-Path -LiteralPath $exactBuildTools)){throw "ARMY_WORKSPACE=FAIL exact_build_tools_missing=$exactBuildTools"}
  Ensure-ArmyJunction -Path (Join-Path $runtimeBuildTools '33.0.2') -Target $exactBuildTools
  $toolRoots=@((Join-Path $globalSdk 'build-tools'),(Join-Path $root 'AndroidSDK\build-tools'),(Join-Path $pinned 'AndroidSDK\build-tools'))
  $compatDir=Join-Path $runtimeBuildTools '_compat-discovery'
  New-Item -ItemType Directory -Force -Path $compatDir|Out-Null
  foreach($toolName in @('aapt.exe','apksigner.bat','zipalign.exe')){
    $tool=Find-ArmyGlobalSdkTool -Roots $toolRoots -Name $toolName
    if(-not $tool){throw "ARMY_WORKSPACE=FAIL global_sdk_tool_missing=$toolName"}
    Ensure-ArmyHardLink -Path (Join-Path $compatDir $toolName) -Target $tool
  }
  Write-Host "ARMY_ANDROID_SDK_FACADE=PASS root=$runtimeSdk exact=33.0.2 recursive_tools=hardlinks"

  # AIR50 packaging view uses globally owned SDK bytes through junctions; marker points at the repo-local source facade.
  $packageSdk=Join-Path $runtime 'Tools\AndroidSDK-AIR50-api33'
  if(Test-Path -LiteralPath $packageSdk){Remove-ArmyLinkOrTree -Path $packageSdk}
  New-Item -ItemType Directory -Force -Path $packageSdk|Out-Null
  foreach($name in @('platforms','build-tools','platform-tools','licenses')){
    $source=Join-Path $globalSdk $name
    if(Test-Path -LiteralPath $source){Ensure-ArmyJunction -Path (Join-Path $packageSdk $name) -Target $source}
  }
  $platformJar=Join-Path $globalSdk 'platforms\android-33\android.jar'
  $aapt2=Join-Path $globalSdk 'build-tools\33.0.2\aapt2.exe'
  if(-not(Test-Path -LiteralPath $platformJar) -or -not(Test-Path -LiteralPath $aapt2)){throw 'ARMY_WORKSPACE=FAIL pinned_sdk_components'}
  [ordered]@{
    api=33
    build_tools='33.0.2'
    source_sdk=$runtimeSdk
    platform_jar_sha256=(Get-FileHash -LiteralPath $platformJar -Algorithm SHA256).Hash.ToLowerInvariant()
    aapt2_sha256=(Get-FileHash -LiteralPath $aapt2 -Algorithm SHA256).Hash.ToLowerInvariant()
    purpose='Army Attack repo-local runtime facade over AndroidBuild Core global SDK'
  }|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $packageSdk 'AIR50-SDK-MANIFEST.json') -Encoding UTF8

  Invoke-ArmyAttackBuildRetention -BuildRoot $build -ExpectedSha $ExpectedSha -Keep $RetentionGenerations
  Write-Host "ARMY_WORKSPACE_MIGRATION=PASS moved_build_generations=$movedBuilds moved_input_files=$movedInputs removed_external_scratch_entries=$scratchRemoved"
  Write-Host "ARMY_WORKSPACE_LAYOUT=PASS work=$work build=$build input_cache=$inputCache scratch=$scratch runtime=$runtime tools=global-junctions sdk_tools=global-hardlinks"
  return [pscustomobject]@{
    work_root=$work
    build_root=$build
    input_cache_root=$inputCache
    scratch_root=$scratch
    scratch_current=$scratchCurrent
    runtime_root=$runtime
    runtime_android_sdk=$runtimeSdk
  }
}
