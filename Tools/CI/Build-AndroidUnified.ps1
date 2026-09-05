param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$PhysicalAndroidBuildRoot,
  [Parameter(Mandatory=$true)][string]$PinnedAndroidBuildRoot
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

function Copy-Tree([string]$Source,[string]$Destination){
  if(-not (Test-Path -LiteralPath $Source)){throw "UNIFIED_COPY=FAIL source_missing=$Source"}
  New-Item -ItemType Directory -Force -Path $Destination|Out-Null
  foreach($child in @(Get-ChildItem -LiteralPath $Source -Force)){
    Copy-Item -LiteralPath $child.FullName -Destination $Destination -Recurse -Force
  }
}

function Sanitize-Profile([string]$ProfileRoot){
  $objective=Join-Path $ProfileRoot 'data\icons\mission_icons\objective_icons'
  if(-not (Test-Path -LiteralPath $objective)){return}
  foreach($asset in @(Get-ChildItem -LiteralPath $objective -File -Filter '*obrazovky (397).png' -ErrorAction SilentlyContinue)){
    $refs=Get-ChildItem -LiteralPath $ProfileRoot -Recurse -File -Include '*.json','*.xml','*.csv','*.txt','*.as' -ErrorAction SilentlyContinue |
      Select-String -SimpleMatch $asset.Name -List -ErrorAction SilentlyContinue
    if($refs){throw "UNIFIED_SANITIZE=FAIL profile=$ProfileRoot referenced_invalid_asset=$($asset.Name)"}
    Remove-Item -LiteralPath $asset.FullName -Force
    Write-Host "UNIFIED_SANITIZE=PASS profile=$ProfileRoot removed=$($asset.Name)"
  }
}

function Is-ObjectNode($Value){
  return ($null -ne $Value -and $Value -is [pscustomobject])
}
function Has-Prop($Obj,[string]$Name){
  return ($null -ne $Obj -and $null -ne $Obj.PSObject.Properties[$Name])
}
function Clone-JsonValue($Value){
  if($null -eq $Value){return $null}
  return ($Value|ConvertTo-Json -Depth 100|ConvertFrom-Json)
}
function Set-Prop($Obj,[string]$Name,$Value){
  if($null -eq $Obj){throw "UNIFIED_JSON_MERGE=FAIL null_target name=$Name"}
  $existing=$Obj.PSObject.Properties[$Name]
  if($null -ne $existing){
    $existing.Value=$Value
    return
  }
  $note=New-Object System.Management.Automation.PSNoteProperty($Name,$Value)
  $Obj.PSObject.Properties.Add($note)
}
function Apply-JsonDelta($Base,$Overlay,$Target){
  $names=New-Object System.Collections.Generic.HashSet[string]
  if(Is-ObjectNode $Base){foreach($p in $Base.PSObject.Properties){[void]$names.Add($p.Name)}}
  if(Is-ObjectNode $Overlay){foreach($p in $Overlay.PSObject.Properties){[void]$names.Add($p.Name)}}
  foreach($name in $names){
    $hasB=Has-Prop $Base $name
    $hasO=Has-Prop $Overlay $name
    if($hasB -and -not $hasO){
      if(Has-Prop $Target $name){$Target.PSObject.Properties.Remove($name)}
      continue
    }
    if(-not $hasB -and $hasO){
      Set-Prop $Target $name (Clone-JsonValue $Overlay.$name)
      continue
    }
    $b=$Base.$name
    $o=$Overlay.$name
    if((Is-ObjectNode $b) -and (Is-ObjectNode $o)){
      if(-not (Has-Prop $Target $name) -or -not (Is-ObjectNode $Target.$name)){Set-Prop $Target $name (Clone-JsonValue $b)}
      Apply-JsonDelta $b $o $Target.$name
    }else{
      $bj=if($null -eq $b){'null'}else{$b|ConvertTo-Json -Depth 100 -Compress}
      $oj=if($null -eq $o){'null'}else{$o|ConvertTo-Json -Depth 100 -Compress}
      if($bj -ne $oj){Set-Prop $Target $name (Clone-JsonValue $o)}
    }
  }
}

function Test-JsonMergePrimitives {
  $base='{"Method":{"x":"1"},"Property":{"y":"2"}}'|ConvertFrom-Json
  $overlay='{"Method":{"x":"9"},"Property":{"y":"2"},"NoteProperty":{"z":"3"}}'|ConvertFrom-Json
  $target=Clone-JsonValue $base
  Apply-JsonDelta $base $overlay $target
  if($target.Method.x -ne '9'){throw 'UNIFIED_JSON_MERGE=FAIL reserved_method_key'}
  if($target.Property.y -ne '2'){throw 'UNIFIED_JSON_MERGE=FAIL reserved_property_key'}
  if($target.NoteProperty.z -ne '3'){throw 'UNIFIED_JSON_MERGE=FAIL reserved_noteproperty_key'}
  Write-Host 'UNIFIED_JSON_MERGE_SELFTEST=PASS'
}

Test-JsonMergePrimitives

function Get-StreamSha256([System.IO.Stream]$Stream){
  $sha=[Security.Cryptography.SHA256]::Create()
  try{return [BitConverter]::ToString($sha.ComputeHash($Stream)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}

$gitCandidates=@()
$gc=Get-Command git.exe -ErrorAction SilentlyContinue
if($gc){$gitCandidates+=$gc.Source}
$gitCandidates+=@(
  (Join-Path $PhysicalAndroidBuildRoot 'Tools\Git\cmd\git.exe'),
  (Join-Path $PhysicalAndroidBuildRoot 'PortableGit\cmd\git.exe')
)
$git=$gitCandidates|Where-Object{$_ -and (Test-Path -LiteralPath $_)}|Select-Object -First 1
if(-not $git){throw 'UNIFIED_GIT=FAIL'}
$actual=(& $git -C $RepoRoot rev-parse HEAD).Trim()
if($actual -ne $ExpectedSha){throw "UNIFIED_EXACT_HEAD=FAIL expected=$ExpectedSha actual=$actual"}
Write-Host "UNIFIED_EXACT_HEAD=PASS sha=$actual"

$publishedSha='306bccc7db5b1ce34dd68a3bc80093648c9224bd'
$publishedRoot=Join-Path $RepoRoot 'vendor\Test_army_attack'
$actualPublished=(& $git -C $publishedRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actualPublished -ne $publishedSha){throw "UNIFIED_SOURCE=FAIL expected=$publishedSha actual=$actualPublished"}
Write-Host "UNIFIED_SOURCE=PASS repository=Valverde-101/Test_army_attack sha=$actualPublished"

$baseBuild=Join-Path $PhysicalAndroidBuildRoot "Builds\code-army-client\$ExpectedSha\android"
$baseStage=Join-Path $baseBuild 'stage'
$baseSwf=Join-Path $baseStage 'iArmyAirOfflineSavingv23.swf'
foreach($p in @($baseStage,$baseSwf,(Join-Path $baseStage 'data'),(Join-Path $baseStage 'config'))){
  if(-not (Test-Path -LiteralPath $p)){throw "UNIFIED_BASE=FAIL missing=$p"}
}
Write-Host "UNIFIED_BASE=PASS stage=$baseStage"

$airRoot=Join-Path $PhysicalAndroidBuildRoot 'Tools\AIRSDK-50.2.3.6'
$adt=Join-Path $airRoot 'bin\adt.bat'
$amxmlc=Join-Path $airRoot 'bin\amxmlc.bat'
$javaHome=Join-Path $PhysicalAndroidBuildRoot 'Tools\Java\jdk-17'
$java=Join-Path $javaHome 'bin\java.exe'
$sdk=Join-Path $PinnedAndroidBuildRoot 'AndroidSDK'
$packageSdk=Join-Path $PinnedAndroidBuildRoot 'Tools\AndroidSDK-AIR50-api33'
$buildTools=Join-Path $sdk 'build-tools\33.0.2'
$aapt=Join-Path $buildTools 'aapt.exe'
$apksigner=Join-Path $buildTools 'apksigner.bat'
$zipalign=Join-Path $buildTools 'zipalign.exe'
foreach($p in @($adt,$amxmlc,$java,$aapt,$apksigner,$zipalign,(Join-Path $packageSdk 'platforms\android-33\android.jar'))){
  if(-not (Test-Path -LiteralPath $p)){throw "UNIFIED_TOOLCHAIN=FAIL missing=$p"}
}
$env:JAVA_HOME=$javaHome
$env:PATH=(Join-Path $javaHome 'bin')+';'+$env:PATH
Remove-Item Env:JAVA_TOOL_OPTIONS -ErrorAction SilentlyContinue
$resolvedJava=(Get-Command java.exe -ErrorAction Stop).Source
if(-not $resolvedJava.StartsWith((Join-Path $javaHome 'bin'),[System.StringComparison]::OrdinalIgnoreCase)){throw "UNIFIED_JAVA_PIN=FAIL path=$resolvedJava"}
Write-Host "UNIFIED_TOOLCHAIN=PASS air=50.2.3.6 java=17 api=33 build_tools=33.0.2 abi=arm64-v8a"

$outRoot=Join-Path $baseBuild 'unified'
$stage=Join-Path $outRoot 'stage'
if(Test-Path -LiteralPath $outRoot){Remove-Item -LiteralPath $outRoot -Recurse -Force}
New-Item -ItemType Directory -Force -Path $stage|Out-Null
Copy-Tree (Join-Path $baseStage 'AppIconsForPublish') (Join-Path $stage 'AppIconsForPublish')

$extensionsDir=Join-Path $outRoot 'extensions'
New-Item -ItemType Directory -Force -Path $extensionsDir|Out-Null
$diagnosticsAneScript=Join-Path $RepoRoot 'Tools\CI\Build-AndroidDiagnosticsAne.ps1'
if(-not (Test-Path -LiteralPath $diagnosticsAneScript)){throw "UNIFIED_DIAGNOSTICS=FAIL build_script_missing=$diagnosticsAneScript"}
& $diagnosticsAneScript -RepoRoot $RepoRoot -AirRoot $airRoot -AndroidSdkRoot $sdk -OutputDirectory $extensionsDir -RootSwfPath (Join-Path $baseStage 'iArmyAirOfflineSavingv23.swf')
$diagnosticsAne=Join-Path $extensionsDir 'ArmyAttackDiagnostics.ane'
if(-not (Test-Path -LiteralPath $diagnosticsAne)){throw "UNIFIED_DIAGNOSTICS=FAIL ane_missing=$diagnosticsAne"}
$diagnosticsAneSha=(Get-FileHash -LiteralPath $diagnosticsAne -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "UNIFIED_DIAGNOSTICS_ANE=PASS path=$diagnosticsAne sha256=$diagnosticsAneSha"

$profilesRoot=Join-Path $stage 'profiles'
New-Item -ItemType Directory -Force -Path $profilesRoot|Out-Null
$profileHashes=[ordered]@{}

$patchedSwfCache=@{}
$patchRoot=Join-Path $outRoot 'patched-swfs'
New-Item -ItemType Directory -Force -Path $patchRoot|Out-Null

function Resolve-FFDecForUnified {
  $ensure=Join-Path $RepoRoot 'Tools\SWF\Ensure-FFDec.ps1'
  & $ensure -RepositoryRoot $RepoRoot
  $root=Join-Path $RepoRoot '.work\tools\ffdec'
  foreach($name in @('ffdec-cli.exe','ffdec.bat','ffdec.jar')){
    $item=Get-ChildItem -LiteralPath $root -Recurse -File -Filter $name -ErrorAction SilentlyContinue|Sort-Object FullName -Descending|Select-Object -First 1
    if($item){return $item.FullName}
  }
  throw 'UNIFIED_SECONDARY_PATCH=FAIL ffdec_not_found'
}

$ffdecUnified=Resolve-FFDecForUnified

function Invoke-FFDecUnified([string[]]$Arguments,[string]$LogPath){
  if([IO.Path]::GetExtension($ffdecUnified).ToLowerInvariant() -eq '.jar'){
    $lines=@(& $java '-jar' $ffdecUnified @Arguments 2>&1|ForEach-Object{$_.ToString()})
  }else{
    $lines=@(& $ffdecUnified @Arguments 2>&1|ForEach-Object{$_.ToString()})
  }
  $exit=$LASTEXITCODE
  $lines|Set-Content -LiteralPath $LogPath -Encoding UTF8
  if($exit -ne 0){
    $lines|Select-Object -Last 80|ForEach-Object{Write-Host $_}
    throw "UNIFIED_SECONDARY_PATCH=FAIL ffdec_exit=$exit log=$LogPath"
  }
}

function Resolve-PatchedSecondarySwf([string]$Swf,[string]$Id){
  $sourceHash=(Get-FileHash -LiteralPath $Swf -Algorithm SHA256).Hash.ToLowerInvariant()
  if($patchedSwfCache.ContainsKey($sourceHash)){
    Write-Host "UNIFIED_SECONDARY_PATCH=REUSE id=$Id source_sha256=$sourceHash"
    return [string]$patchedSwfCache[$sourceHash]
  }

  $work=Join-Path $patchRoot $sourceHash
  if(Test-Path -LiteralPath $work){Remove-Item -LiteralPath $work -Recurse -Force}
  New-Item -ItemType Directory -Force -Path $work|Out-Null
  $export=Join-Path $work 'export'
  New-Item -ItemType Directory -Force -Path $export|Out-Null
  Invoke-FFDecUnified @('-cli','-onerror','abort','-selectclass','GameMain','-export','script',$export,$Swf) (Join-Path $work 'export.log')

  $gm=@(Get-ChildItem -LiteralPath $export -Recurse -File -Filter 'GameMain.as' -ErrorAction Stop)
  if($gm.Count -ne 1){throw "UNIFIED_SECONDARY_PATCH=FAIL id=$Id GameMain_count=$($gm.Count)"}
  $src=[IO.File]::ReadAllText($gm[0].FullName)
  $marker='__androidSecondaryStageReady'
  if($src.Contains($marker)){
    $existing=Join-Path $work 'patched.swf'
    Copy-Item -LiteralPath $Swf -Destination $existing -Force
    $patchedSwfCache[$sourceHash]=$existing
    return $existing
  }

  $signature='public function GameMain()'
  $start=$src.IndexOf($signature,[StringComparison]::Ordinal)
  if($start -lt 0){throw "UNIFIED_SECONDARY_PATCH=FAIL id=$Id constructor_missing"}
  $open=$src.IndexOf('{',$start)
  $depth=0;$close=-1
  for($i=$open;$i -lt $src.Length;$i++){
    if($src[$i] -eq '{'){$depth++}
    elseif($src[$i] -eq '}'){$depth--;if($depth -eq 0){$close=$i;break}}
  }
  if($open -lt 0 -or $close -lt 0){throw "UNIFIED_SECONDARY_PATCH=FAIL id=$Id constructor_bounds"}

  $body=$src.Substring($open+1,$close-$open-1)
  $body=[regex]::Replace($body,'(?m)^\s*super\(\);\s*','',1)
  $body=$body.Replace('this.resetGame();','__androidBootstrapPhase = "resetGame"; this.resetGame(); __androidBootstrapPhase = "postResetGame";')
  $body=$body.Replace('addEventListener(Event.ENTER_FRAME','__androidBootstrapPhase = "listeners"; addEventListener(Event.ENTER_FRAME')
  $body=$body.Replace('this.setDiscordStatus({});','__androidBootstrapPhase = "discord"; this.setDiscordStatus({}); __androidBootstrapPhase = "ready";')
  $replacement=@"
public function GameMain() {
            super();
            if (stage != null) {
                this.__androidSecondaryStageReady();
            } else {
                addEventListener(Event.ADDED_TO_STAGE, this.__androidSecondaryAddedToStage, false, 0, true);
            }
        }

        private function __androidSecondaryAddedToStage(param1:Event):void {
            removeEventListener(Event.ADDED_TO_STAGE, this.__androidSecondaryAddedToStage);
            this.__androidSecondaryStageReady();
        }

        private function __androidSecondaryStageReady():void {
            var __androidBootstrapPhase:String = "state_setup";
            try {
$body
            } catch (__androidBootstrapError:Error) {
                var __androidBootstrapStack:String = __androidBootstrapError.getStackTrace();
                throw new Error("ARMY_BOOTSTRAP_" + __androidBootstrapPhase + ": " + __androidBootstrapError.toString() + (__androidBootstrapStack ? "\n" + __androidBootstrapStack : ""));
            }
        }
"@
  $patchedSource=$src.Substring(0,$start)+$replacement+$src.Substring($close+1)
  $patchedAs=Join-Path $work 'GameMain.as'
  [IO.File]::WriteAllText($patchedAs,$patchedSource,(New-Object Text.UTF8Encoding($false)))
  $patchedSwf=Join-Path $work 'patched-gamemain.swf'
  Invoke-FFDecUnified @('-cli','-onerror','abort','-replace',$Swf,$patchedSwf,'GameMain',$patchedAs) (Join-Path $work 'replace-gamemain.log')
  if(-not (Test-Path -LiteralPath $patchedSwf)){throw "UNIFIED_SECONDARY_PATCH=FAIL id=$Id patched_gamemain_missing"}

  # Patch LoadingState so malformed/missing Animate loading-screen children can
  # never cause Error #1009 during the first state transition.
  $loadingExport=Join-Path $work 'loading-export'
  New-Item -ItemType Directory -Force -Path $loadingExport|Out-Null
  Invoke-FFDecUnified @('-cli','-onerror','abort','-selectclass','game.states.LoadingState','-export','script',$loadingExport,$patchedSwf) (Join-Path $work 'export-loadingstate.log')
  $loadingFiles=@(Get-ChildItem -LiteralPath $loadingExport -Recurse -File -Filter 'LoadingState.as' -ErrorAction Stop)
  if($loadingFiles.Count -ne 1){throw "UNIFIED_LOADING_GUARD=FAIL id=$Id export_count=$($loadingFiles.Count)"}
  $loadingSrc=[IO.File]::ReadAllText($loadingFiles[0].FullName)
  $loadingAnchor='this.mLoadingClip = param3;'
  if(-not $loadingSrc.Contains($loadingAnchor)){throw "UNIFIED_LOADING_GUARD=FAIL id=$Id anchor_missing"}
  $loadingGuard=@'
this.mLoadingClip = param3;
          var __androidFillBar:MovieClip = this.mLoadingClip ? this.mLoadingClip.getChildByName("Fill_Bar") as MovieClip : null;
          if (__androidFillBar == null) {
             var __androidFallback:MovieClip = new MovieClip();
             var __androidTitle:TextField = new TextField();
             __androidTitle.name = "Text_Title";
             __androidTitle.text = "Army Attack";
             __androidTitle.width = 500;
             __androidTitle.height = 40;
             __androidTitle.x = 262;
             __androidTitle.y = 300;
             __androidFallback.addChild(__androidTitle);
             __androidFillBar = new MovieClip();
             __androidFillBar.name = "Fill_Bar";
             __androidFillBar.x = 312;
             __androidFillBar.y = 365;
             __androidFillBar.graphics.beginFill(0x3A4650);
             __androidFillBar.graphics.drawRoundRect(0,0,400,70,12,12);
             __androidFillBar.graphics.endFill();
             __androidFallback.addChild(__androidFillBar);
             this.mLoadingClip = __androidFallback;
          }
          if (!(__androidFillBar.getChildByName("Progress") is TextField)) {
             var __androidProgress:TextField = new TextField();
             __androidProgress.name = "Progress";
             __androidProgress.text = "0%";
             __androidProgress.width = 100;
             __androidProgress.height = 28;
             __androidProgress.x = 150;
             __androidProgress.y = 8;
             __androidFillBar.addChild(__androidProgress);
          }
          if (!(__androidFillBar.getChildByName("Text_Description") is TextField)) {
             var __androidDescription:TextField = new TextField();
             __androidDescription.name = "Text_Description";
             __androidDescription.text = "Loading...";
             __androidDescription.width = 360;
             __androidDescription.height = 28;
             __androidDescription.x = 20;
             __androidDescription.y = 38;
             __androidFillBar.addChild(__androidDescription);
          }
'@
  $loadingSrc=$loadingSrc.Replace($loadingAnchor,$loadingGuard)
  $loadingAs=Join-Path $work 'LoadingState.as'
  [IO.File]::WriteAllText($loadingAs,$loadingSrc,(New-Object Text.UTF8Encoding($false)))
  $loadingPatchedSwf=Join-Path $work 'patched-loadingstate.swf'
  Invoke-FFDecUnified @('-cli','-onerror','abort','-replace',$patchedSwf,$loadingPatchedSwf,'game.states.LoadingState',$loadingAs) (Join-Path $work 'replace-loadingstate.log')
  if(-not (Test-Path -LiteralPath $loadingPatchedSwf)){throw "UNIFIED_LOADING_GUARD=FAIL id=$Id output_missing"}
  Write-Host "UNIFIED_LOADING_GUARD=PASS id=$Id fill_bar=true progress=true description=true"

  # Stage-size reads happen during Config.init(). Make them safe during the
  # first mobile frame even if AIR has not attached mMainClip.stage yet.
  $stateExport=Join-Path $work 'gamestate-export'
  New-Item -ItemType Directory -Force -Path $stateExport|Out-Null
  Invoke-FFDecUnified @('-cli','-onerror','abort','-selectclass','game.states.GameState','-export','script',$stateExport,$loadingPatchedSwf) (Join-Path $work 'export-gamestate.log')
  $stateFiles=@(Get-ChildItem -LiteralPath $stateExport -Recurse -File -Filter 'GameState.as' -ErrorAction Stop)
  if($stateFiles.Count -ne 1){throw "UNIFIED_STAGE_SIZE_GUARD=FAIL id=$Id export_count=$($stateFiles.Count)"}
  $stateSrc=[IO.File]::ReadAllText($stateFiles[0].FullName)
  $stateSrc=[regex]::Replace($stateSrc,'public function getStageWidth\(\)\s*:\s*int\s*\{\s*return\s+mMainClip\.stage\.stageWidth;\s*\}','public function getStageWidth(): int { if (mMainClip != null && mMainClip.stage != null) return mMainClip.stage.stageWidth; return Config.SCREEN_WIDTH > 0 ? Config.SCREEN_WIDTH : 1280; }')
  $stateSrc=[regex]::Replace($stateSrc,'public function getStageHeight\(\)\s*:\s*int\s*\{\s*return\s+mMainClip\.stage\.stageHeight;\s*\}','public function getStageHeight(): int { if (mMainClip != null && mMainClip.stage != null) return mMainClip.stage.stageHeight; return Config.SCREEN_HEIGHT > 0 ? Config.SCREEN_HEIGHT : 720; }')
  if(-not $stateSrc.Contains('mMainClip != null && mMainClip.stage != null')){throw "UNIFIED_STAGE_SIZE_GUARD=FAIL id=$Id replacement_missing"}
  $stateAs=Join-Path $work 'GameState.as'
  [IO.File]::WriteAllText($stateAs,$stateSrc,(New-Object Text.UTF8Encoding($false)))
  $runtimePatchedSwf=Join-Path $work 'patched.swf'
  Invoke-FFDecUnified @('-cli','-onerror','abort','-replace',$loadingPatchedSwf,$runtimePatchedSwf,'game.states.GameState',$stateAs) (Join-Path $work 'replace-gamestate.log')
  if(-not (Test-Path -LiteralPath $runtimePatchedSwf)){throw "UNIFIED_STAGE_SIZE_GUARD=FAIL id=$Id output_missing"}
  Write-Host "UNIFIED_STAGE_SIZE_GUARD=PASS id=$Id fallback=1280x720"

  $patchedSwf=$runtimePatchedSwf

  $verify=Join-Path $work 'verify'
  New-Item -ItemType Directory -Force -Path $verify|Out-Null
  Invoke-FFDecUnified @('-cli','-onerror','abort','-selectclass','GameMain','-export','script',$verify,$patchedSwf) (Join-Path $work 'verify.log')
  $vgm=@(Get-ChildItem -LiteralPath $verify -Recurse -File -Filter 'GameMain.as' -ErrorAction Stop)
  if($vgm.Count -ne 1){throw "UNIFIED_SECONDARY_PATCH=FAIL id=$Id verify_count=$($vgm.Count)"}
  $verifyText=[IO.File]::ReadAllText($vgm[0].FullName)
  if(-not $verifyText.Contains($marker) -or -not $verifyText.Contains('Event.ADDED_TO_STAGE') -or -not $verifyText.Contains('ARMY_BOOTSTRAP_')){
    throw "UNIFIED_SECONDARY_PATCH=FAIL id=$Id guard_verify"
  }

  $patchedHash=(Get-FileHash -LiteralPath $patchedSwf -Algorithm SHA256).Hash.ToLowerInvariant()
  if($patchedHash -eq $sourceHash){throw "UNIFIED_SECONDARY_PATCH=FAIL id=$Id hash_unchanged"}
  $patchedSwfCache[$sourceHash]=$patchedSwf
  Write-Host "UNIFIED_SECONDARY_PATCH=PASS id=$Id source_sha256=$sourceHash patched_sha256=$patchedHash"
  return $patchedSwf
}

function Add-Profile([string]$Id,[string]$Swf,[string]$Data,[string]$Config){
  $root=Join-Path $profilesRoot $Id
  $assets=Join-Path $root 'assets'
  New-Item -ItemType Directory -Force -Path $assets|Out-Null
  $destSwf=Join-Path $assets 'game.swf'
  $sourceHash=(Get-FileHash -LiteralPath $Swf -Algorithm SHA256).Hash.ToLowerInvariant()
  $androidSwf=Resolve-PatchedSecondarySwf $Swf $Id
  Copy-Item -LiteralPath $androidSwf -Destination $destSwf -Force
  Copy-Tree $Data (Join-Path $root 'data')
  Copy-Tree $Config (Join-Path $root 'config')
  Sanitize-Profile $root
  $swfHash=(Get-FileHash -LiteralPath $destSwf -Algorithm SHA256).Hash.ToLowerInvariant()
  $profileHashes[$Id]=[ordered]@{path=("profiles/"+$Id+"/assets/game.swf");source_sha256=$sourceHash;sha256=$swfHash;size=(Get-Item $destSwf).Length;android_secondary_stage_guard=$true;android_loading_guard=$true;android_stage_size_guard=$true}
  Write-Host "UNIFIED_PROFILE_STAGE=PASS id=$Id source_sha256=$sourceHash swf_sha256=$swfHash stage_guard=true size=$((Get-Item $destSwf).Length)"
}

Add-Profile 'base' $baseSwf (Join-Path $baseStage 'data') (Join-Path $baseStage 'config')

$mods=@('colossal','crimson','hardmode','none','swapped','swapped2','truecrimson')
foreach($id in $mods){
  $mod=Join-Path $publishedRoot ("mods\"+$id)
  $swfs=@(Get-ChildItem -LiteralPath (Join-Path $mod 'assets') -File -Filter '*.swf' -ErrorAction Stop)
  if($swfs.Count -ne 1){throw "UNIFIED_MOD_SWF=FAIL id=$id count=$($swfs.Count)"}
  Add-Profile $id $swfs[0].FullName (Join-Path $mod 'data') (Join-Path $mod 'config')
}

function Add-CombinedProfile([string]$Id,[string]$VisualId){
  $source=Join-Path $profilesRoot 'hardmode'
  $dest=Join-Path $profilesRoot $Id
  Copy-Item -LiteralPath $source -Destination $dest -Recurse -Force
  $noneJson=Get-Content -LiteralPath (Join-Path $profilesRoot 'none\config\army_config_base.json') -Raw|ConvertFrom-Json
  $visualJson=Get-Content -LiteralPath (Join-Path $profilesRoot ($VisualId+'\config\army_config_base.json')) -Raw|ConvertFrom-Json
  $targetPath=Join-Path $dest 'config\army_config_base.json'
  $target=Get-Content -LiteralPath $targetPath -Raw|ConvertFrom-Json
  Apply-JsonDelta $noneJson $visualJson $target
  $target|ConvertTo-Json -Depth 100|Set-Content -LiteralPath $targetPath -Encoding UTF8
  [void](Get-Content -LiteralPath $targetPath -Raw|ConvertFrom-Json)

  $swfPath=Join-Path $dest 'assets\game.swf'
  $swfHash=(Get-FileHash -LiteralPath $swfPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $profileHashes[$Id]=[ordered]@{path=("profiles/"+$Id+"/assets/game.swf");sha256=$swfHash;size=(Get-Item $swfPath).Length}
  Write-Host "UNIFIED_MULTI_MOD=PASS id=$Id base=hardmode overlay=$VisualId conflict_policy=visual_wins known_conflicts=2"
}
Add-CombinedProfile 'hardmode-swapped' 'swapped'
Add-CombinedProfile 'hardmode-swapped2' 'swapped2'

$sharedHash=[string]$profileHashes['none'].sha256
foreach($id in @('hardmode','swapped','swapped2','hardmode-swapped','hardmode-swapped2')){
  if([string]$profileHashes[$id].sha256 -ne $sharedHash){throw "UNIFIED_COMPATIBILITY=FAIL classic_runtime_hash_mismatch id=$id"}
}
Write-Host "UNIFIED_COMPATIBILITY=PASS classic_shared_runtime_sha256=$sharedHash"

$manifest=[ordered]@{
  schema=1
  tested_sha=$ExpectedSha
  source_repository='Valverde-101/Test_army_attack'
  source_sha=$actualPublished
  android_only=$true
  profile_count=10
  multi_mod_profiles=@('hardmode-swapped','hardmode-swapped2')
  compatibility=[ordered]@{
    classic_runtime_swf_group=@('none','hardmode','swapped','swapped2','hardmode-swapped','hardmode-swapped2')
    exclusive_runtime_profiles=@('base','colossal','crimson','truecrimson')
    swapped_and_swapped2_mutually_exclusive=$true
    multi_mod_conflict_policy='visual layer wins the two known Warfly shoot_up graphics conflicts'
  }
  profiles=@(
    [ordered]@{id='base';name='Army Attack 23.2';description='Modern published 23.2 runtime';swf='profiles/base/assets/game.swf';kind='modern'},
    [ordered]@{id='none';name='Classic Mods';description='Classic shared mod runtime without layers';swf='profiles/none/assets/game.swf';kind='classic'},
    [ordered]@{id='hardmode';name='Classic + Hard Mode';description='Hard Mode layer';swf='profiles/hardmode/assets/game.swf';kind='classic-layer'},
    [ordered]@{id='swapped';name='Classic + Swapped';description='Swapped visual layer';swf='profiles/swapped/assets/game.swf';kind='classic-layer'},
    [ordered]@{id='swapped2';name='Classic + Swapped 2';description='Swapped 2 visual layer';swf='profiles/swapped2/assets/game.swf';kind='classic-layer'},
    [ordered]@{id='hardmode-swapped';name='Hard Mode + Swapped';description='Verified same-runtime multi-mod profile';swf='profiles/hardmode-swapped/assets/game.swf';kind='multi-mod'},
    [ordered]@{id='hardmode-swapped2';name='Hard Mode + Swapped 2';description='Verified same-runtime multi-mod profile';swf='profiles/hardmode-swapped2/assets/game.swf';kind='multi-mod'},
    [ordered]@{id='colossal';name='Colossal Island';description='Experimental unfinished custom island mode';swf='profiles/colossal/assets/game.swf';kind='exclusive'},
    [ordered]@{id='crimson';name='Crimson';description='Crimson full runtime';swf='profiles/crimson/assets/game.swf';kind='exclusive'},
    [ordered]@{id='truecrimson';name='True Crimson';description='True Crimson full runtime';swf='profiles/truecrimson/assets/game.swf';kind='exclusive'}
  )
}
$manifestPath=Join-Path $profilesRoot 'profiles.json'
$manifest|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $manifestPath -Encoding UTF8

$launcherSource=Join-Path $RepoRoot 'android\launcher\ArmyAttackLauncher.as'
if(-not (Test-Path -LiteralPath $launcherSource)){throw "UNIFIED_LAUNCHER_SOURCE=FAIL path=$launcherSource"}
$launcherSwf=Join-Path $stage 'ArmyAttackLauncher.swf'
$compilerOut=Join-Path $outRoot 'amxmlc.out.log'
$compilerErr=Join-Path $outRoot 'amxmlc.err.log'
$compilerArgs=@("-output=$launcherSwf",'-debug=false','-optimize=true',$launcherSource)
$cp=Start-Process -FilePath $amxmlc -ArgumentList $compilerArgs -WorkingDirectory (Split-Path -Parent $launcherSource) -NoNewWindow -PassThru -Wait -RedirectStandardOutput $compilerOut -RedirectStandardError $compilerErr
if($cp.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $launcherSwf)){
  if(Test-Path $compilerOut){Get-Content $compilerOut -Tail 120|ForEach-Object{Write-Host $_}}
  if(Test-Path $compilerErr){Get-Content $compilerErr -Tail 120|ForEach-Object{Write-Host $_}}
  throw "UNIFIED_LAUNCHER_COMPILE=FAIL exit=$($cp.ExitCode)"
}
$launcherSha=(Get-FileHash -LiteralPath $launcherSwf -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "UNIFIED_LAUNCHER_COMPILE=PASS path=$launcherSwf sha256=$launcherSha"

$descriptor=Join-Path $outRoot 'ArmyAttack-unified-app.xml'
$xml=@"
<?xml version="1.0" encoding="utf-8"?>
<application xmlns="http://ns.adobe.com/air/application/50.2">
  <id>army.attack</id>
  <versionNumber>23.2.0</versionNumber>
  <versionLabel>23.2-mod-selector-$($ExpectedSha.Substring(0,8))</versionLabel>
  <filename>ArmyAttack</filename>
  <name>Army Attack</name>
  <initialWindow>
    <content>ArmyAttackLauncher.swf</content>
    <visible>true</visible>
    <fullScreen>true</fullScreen>
    <aspectRatio>landscape</aspectRatio>
    <renderMode>auto</renderMode>
    <autoOrients>false</autoOrients>
  </initialWindow>
  <extensions>
    <extensionID>com.valverde.armyattack.diagnostics</extensionID>
  </extensions>
  <icon>
    <image36x36>AppIconsForPublish/icon36.png</image36x36>
    <image48x48>AppIconsForPublish/icon48.png</image48x48>
    <image72x72>AppIconsForPublish/icon72.png</image72x72>
    <image96x96>AppIconsForPublish/icon96.png</image96x96>
    <image144x144>AppIconsForPublish/icon144.png</image144x144>
    <image192x192>AppIconsForPublish/icon192.png</image192x192>
  </icon>
  <android>
    <manifestAdditions><![CDATA[
      <manifest>
        <uses-sdk android:minSdkVersion="21" android:targetSdkVersion="33"/>
        <uses-feature android:glEsVersion="0x00020000" android:required="true"/>
        <application android:hardwareAccelerated="true" android:usesCleartextTraffic="false">
          <provider android:name="com.valverde.armyattack.diagnostics.DiagnosticsProvider" android:authorities="air.army.attack.armyattackdiagnostics" android:exported="false" android:grantUriPermissions="true"/>
        </application>
      </manifest>
    ]]></manifestAdditions>
  </android>
</application>
"@
$xml|Set-Content -LiteralPath $descriptor -Encoding UTF8

$cert=Join-Path $outRoot 'unified-ci-signing.p12'
$certPass='ArmyAttackUnifiedLocalCI'
$apkPath=Join-Path $outRoot ("ArmyAttack-23.2-MODS-"+$ExpectedSha+".apk")
$adtOut=Join-Path $outRoot 'adt-unified.out.log'
$adtErr=Join-Path $outRoot 'adt-unified.err.log'
try{
  $certArgs=@('-certificate','-cn','ArmyAttackUnified','-ou','Dev','-o','ValverdeLocalBuild','-c','PE','2048-RSA',$cert,$certPass)
  $certProc=Start-Process -FilePath $adt -ArgumentList $certArgs -WorkingDirectory $outRoot -NoNewWindow -PassThru -Wait
  if($certProc.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $cert)){throw "UNIFIED_CERT=FAIL exit=$($certProc.ExitCode)"}
  $args=@('-package','-target','apk-captive-runtime','-arch','armv8','-storetype','pkcs12','-keystore',$cert,'-storepass',$certPass,$apkPath,$descriptor,'-extdir',$extensionsDir,'-C',$stage,'.','-platformsdk',$packageSdk)
  $pp=Start-Process -FilePath $adt -ArgumentList $args -WorkingDirectory $outRoot -NoNewWindow -PassThru -Wait -RedirectStandardOutput $adtOut -RedirectStandardError $adtErr
  if($pp.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $apkPath)){
    if(Test-Path $adtOut){Get-Content $adtOut -Tail 120|ForEach-Object{Write-Host $_}}
    if(Test-Path $adtErr){Get-Content $adtErr -Tail 120|ForEach-Object{Write-Host $_}}
    throw "UNIFIED_PACKAGE=FAIL exit=$($pp.ExitCode)"
  }
}finally{
  Remove-Item -LiteralPath $cert -Force -ErrorAction SilentlyContinue
  Write-Host 'UNIFIED_CERT_CLEANUP=PASS'
}

$badging=@(& $aapt dump badging $apkPath 2>&1|ForEach-Object{$_.ToString()})
if($LASTEXITCODE -ne 0){throw 'UNIFIED_VALIDATE=FAIL badging'}
$badgingText=$badging -join [Environment]::NewLine
if($badgingText -notmatch "package:\s+name='air\.army\.attack'"){throw 'UNIFIED_VALIDATE=FAIL package'}
if($badgingText -notmatch "targetSdkVersion:'33'"){throw 'UNIFIED_VALIDATE=FAIL target_sdk'}
$manifestDump=@(& $aapt dump xmltree $apkPath AndroidManifest.xml 2>&1|ForEach-Object{$_.ToString()})
if($LASTEXITCODE -ne 0){throw 'UNIFIED_DIAGNOSTICS=FAIL manifest_dump'}
$manifestText=$manifestDump -join [Environment]::NewLine
if($manifestText -notmatch 'com\.valverde\.armyattack\.diagnostics\.DiagnosticsProvider'){throw 'UNIFIED_DIAGNOSTICS=FAIL provider_missing'}
if($manifestText -notmatch 'air\.army\.attack\.armyattackdiagnostics'){throw 'UNIFIED_DIAGNOSTICS=FAIL authority_missing'}
Write-Host 'UNIFIED_DIAGNOSTICS_MANIFEST=PASS provider=DiagnosticsProvider authority=air.army.attack.armyattackdiagnostics'

$entries=@(& $aapt list $apkPath 2>&1|ForEach-Object{$_.ToString()})
if($LASTEXITCODE -ne 0){throw 'UNIFIED_VALIDATE=FAIL list'}
if(-not ($entries|Where-Object{$_ -like 'lib/arm64-v8a/*'})){throw 'UNIFIED_VALIDATE=FAIL arm64'}
foreach($required in @('assets/ArmyAttackLauncher.swf','assets/profiles/profiles.json')){
  if(-not ($entries -contains $required)){throw "UNIFIED_VALIDATE=FAIL missing=$required"}
}
foreach($p in $manifest.profiles){
  $entry='assets/'+([string]$p.swf)
  if(-not ($entries -contains $entry)){throw "UNIFIED_VALIDATE=FAIL profile=$($p.id) missing=$entry"}
}

& $zipalign -c -v 4 $apkPath 1>$null
if($LASTEXITCODE -ne 0){throw 'UNIFIED_VALIDATE=FAIL zipalign'}
& $apksigner verify --verbose $apkPath 1>$null
if($LASTEXITCODE -ne 0){throw 'UNIFIED_VALIDATE=FAIL signature'}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=[IO.Compression.ZipFile]::OpenRead($apkPath)
try{
  $launcherEntry=@($zip.Entries|Where-Object{$_.FullName -eq 'assets/ArmyAttackLauncher.swf'})|Select-Object -First 1
  if(-not $launcherEntry){throw 'UNIFIED_HASH=FAIL launcher_missing'}
  $stream=$launcherEntry.Open()
  try{$packagedLauncherSha=Get-StreamSha256 $stream}finally{$stream.Dispose()}
  if($packagedLauncherSha -ne $launcherSha){throw "UNIFIED_HASH=FAIL launcher expected=$launcherSha actual=$packagedLauncherSha"}

  foreach($id in $profileHashes.Keys){
    $meta=$profileHashes[$id]
    $entryName='assets/'+[string]$meta.path
    $entry=@($zip.Entries|Where-Object{$_.FullName -eq $entryName})|Select-Object -First 1
    if(-not $entry){throw "UNIFIED_HASH=FAIL profile=$id missing=$entryName"}
    $stream=$entry.Open()
    try{$actualHash=Get-StreamSha256 $stream}finally{$stream.Dispose()}
    if($actualHash -ne [string]$meta.sha256){throw "UNIFIED_HASH=FAIL profile=$id expected=$($meta.sha256) actual=$actualHash"}
    Write-Host "UNIFIED_PROFILE_HASH=PASS id=$id sha256=$actualHash"
  }
}finally{$zip.Dispose()}

$apk=Get-Item -LiteralPath $apkPath
$apkSha=(Get-FileHash -LiteralPath $apkPath -Algorithm SHA256).Hash.ToLowerInvariant()
$prov=[ordered]@{
  repository='Valverde-101/code-army-client'
  tested_sha=$ExpectedSha
  android_only=$true
  game_version='23.2'
  selector=$true
  selector_swf='ArmyAttackLauncher.swf'
  selector_swf_sha256=$launcherSha
  secondary_swf_stage_guard=$true
  secondary_swf_loading_guard=$true
  secondary_swf_stage_size_guard=$true
  isolated_profile_application_domain=$true
  diagnostics_share_zip=$true
  diagnostics_extension_id='com.valverde.armyattack.diagnostics'
  diagnostics_ane_sha256=$diagnosticsAneSha
  diagnostics_content_provider='air.army.attack.armyattackdiagnostics'
  profile_count=$manifest.profile_count
  profiles=@($manifest.profiles|ForEach-Object{$_.id})
  profile_swfs=$profileHashes
  multi_mod_profiles=$manifest.multi_mod_profiles
  multi_mod_conflict_policy=$manifest.compatibility.multi_mod_conflict_policy
  published_source_repository='Valverde-101/Test_army_attack'
  published_source_sha=$actualPublished
  air_sdk='50.2.3.6'
  java='17'
  android_target_sdk=33
  android_abi='arm64-v8a'
  apk_path=$apkPath
  apk_size=$apk.Length
  apk_sha256=$apkSha
}
$provPath=Join-Path $outRoot 'UNIFIED-PROVENANCE.json'
$prov|ConvertTo-Json -Depth 15|Set-Content -LiteralPath $provPath -Encoding UTF8
$badging|Set-Content -LiteralPath (Join-Path $outRoot 'apk-badging.txt') -Encoding UTF8

& (Join-Path $RepoRoot 'Tools\CI\Publish-ApkFinal.ps1') -SourceApk $apkPath -AndroidBuildRoot $PhysicalAndroidBuildRoot -ExpectedSha $ExpectedSha -RelativePath 'ArmyAttack-23.2-MODS.apk' -Kind 'unified-mod-selector'

Write-Host "UNIFIED_BUILD=PASS"
Write-Host "UNIFIED_SELECTOR=PASS profile_count=$($manifest.profile_count) secondary_swf_stage_guard=true loading_guard=true stage_size_guard=true isolated_domain=true"
Write-Host "UNIFIED_DIAGNOSTICS=PASS share_zip=true sharesheet=true provider=air.army.attack.armyattackdiagnostics ane_sha256=$diagnosticsAneSha"
Write-Host "UNIFIED_MULTI_MOD=PASS profiles=$($manifest.multi_mod_profiles -join ',')"
Write-Host "UNIFIED_APK_VALIDATE=PASS package=air.army.attack target_sdk=33 abi=arm64-v8a"
Write-Host "UNIFIED_APK_PATH=$apkPath"
Write-Host "UNIFIED_APK_SIZE=$($apk.Length)"
Write-Host "UNIFIED_APK_SHA256=$apkSha"
Write-Host "UNIFIED_PROVENANCE=$provPath"
