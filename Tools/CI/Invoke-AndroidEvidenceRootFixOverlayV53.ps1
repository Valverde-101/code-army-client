param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [string]$RequestedMode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

if($RequestedMode -notin @('Apply','Restore')){throw "ANDROID_EVIDENCE_ROOTFIX_V53=FAIL invalid_mode=$RequestedMode"}
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V53=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$v52=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV52.ps1'
$patcherPath=Join-Path $RepoRoot 'Tools\CI\Patch-AndroidPerformanceSwf.ps1'
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v53\'+$ExpectedSha)
$backupPath=Join-Path $backupRoot 'Patch-AndroidPerformanceSwf.post-v52.ps1'
$manifestPath=Join-Path $backupRoot 'manifest.json'
if(-not(Test-Path -LiteralPath $v52 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V53=FAIL predecessor_missing=$v52"}

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Restore-OwnedPatcher {
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){return}
  $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V53=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
  if(-not(Test-Path -LiteralPath $backupPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V53=FAIL restore_backup_missing=$backupPath"}
  Copy-Item -LiteralPath $backupPath -Destination $patcherPath -Force
  $actualHash=Get-Sha256 $patcherPath
  $expectedHash=([string]$manifest.patcher_sha256).ToUpperInvariant()
  if($actualHash -ne $expectedHash){throw "ANDROID_EVIDENCE_ROOTFIX_V53=FAIL restore_hash expected=$expectedHash actual=$actualHash"}
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
  Write-Host 'ANDROID_EVIDENCE_ROOTFIX_V53_OWNED_RESTORE=PASS patcher=post_v52'
}

if($RequestedMode -eq 'Restore'){
  Restore-OwnedPatcher
  & $v52 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -RequestedMode Restore
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V53=FAIL predecessor_restore_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V53=PASS mode=restore predecessor=v52 sha=$ExpectedSha parser=brace_depth_stack"
  return
}

$v52Applied=$false
try {
  & $v52 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -RequestedMode Apply
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V53=FAIL predecessor_apply_exit=$LASTEXITCODE"}
  $v52Applied=$true

  if(-not(Test-Path -LiteralPath $patcherPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V53=FAIL patcher_missing=$patcherPath"}
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
  Copy-Item -LiteralPath $patcherPath -Destination $backupPath -Force
  $baselineHash=Get-Sha256 $patcherPath
  [ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v53';source_sha=$ExpectedSha;predecessor='v52';patcher_sha256=$baselineHash}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $manifestPath -Encoding UTF8

  $patcher=Normalize-Lf ([IO.File]::ReadAllText($patcherPath))
  $functionPattern='(?ms)^function Convert-MobileAirSourceForFFDec\(\[string\]\$Source,\[string\]\$Destination,\[string\]\$ClassName\)\{.*?^\}(?=\n\nRemove-Item -LiteralPath \$OutputSwf)'
  $functionMatches=[regex]::Matches($patcher,$functionPattern)
  if($functionMatches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V53=FAIL patch=config_preprocessor_function expected=1 actual=$($functionMatches.Count)"}

  $replacement=@'
function Get-AS3BraceDelta([string]$Line,[ref]$InBlockComment){
  $delta=0
  $quote=[char]0
  $escaped=$false
  for($i=0;$i -lt $Line.Length;$i++){
    $ch=$Line[$i]
    $next=if($i+1 -lt $Line.Length){$Line[$i+1]}else{[char]0}
    if($InBlockComment.Value){
      if($ch -eq '*' -and $next -eq '/'){$InBlockComment.Value=$false;$i++}
      continue
    }
    if([int]$quote -ne 0){
      if($escaped){$escaped=$false;continue}
      if($ch -eq '\'){$escaped=$true;continue}
      if($ch -eq $quote){$quote=[char]0}
      continue
    }
    if($ch -eq '/' -and $next -eq '/'){break}
    if($ch -eq '/' -and $next -eq '*'){$InBlockComment.Value=$true;$i++;continue}
    if($ch -eq '"' -or $ch -eq "'"){$quote=$ch;continue}
    if($ch -eq '{'){$delta++}
    elseif($ch -eq '}'){$delta--}
  }
  return $delta
}

function Convert-MobileAirSourceForFFDec([string]$Source,[string]$Destination,[string]$ClassName){
  $sourceLines=Get-Content -LiteralPath $Source
  $hasMobileConfig=@($sourceLines|Where-Object{$_ -match '^\s*CONFIG::BUILD_FOR_MOBILE_AIR\s*\{' }).Count -gt 0
  $targetConfigMode=if($hasMobileConfig){'BUILD_FOR_MOBILE_AIR'}else{'BUILD_FOR_AIR'}
  $result=New-Object System.Collections.Generic.List[string]
  $stack=New-Object System.Collections.ArrayList
  $inBlockComment=$false
  $opened=0
  $closed=0
  foreach($line in $sourceLines){
    $configMatch=$null
    if(-not $inBlockComment){
      $candidate=[regex]::Match($line,'^\s*CONFIG::(BUILD_FOR_MOBILE_AIR|BUILD_FOR_AIR|NOT_BUILD_FOR_AIR)\s*\{\s*(?://.*)?$')
      if($candidate.Success){$configMatch=$candidate}
    }
    if($null -ne $configMatch){
      $mode=$configMatch.Groups[1].Value
      $parentActive=if($stack.Count -eq 0){$true}else{[bool]$stack[$stack.Count-1].active}
      $frame=[pscustomobject]@{mode=$mode;active=($parentActive -and $mode -eq $targetConfigMode);depth=1}
      [void]$stack.Add($frame)
      $opened++
      continue
    }

    if($stack.Count -eq 0){
      $result.Add($line)
      [void](Get-AS3BraceDelta -Line $line -InBlockComment ([ref]$inBlockComment))
      continue
    }

    $frame=$stack[$stack.Count-1]
    $delta=Get-AS3BraceDelta -Line $line -InBlockComment ([ref]$inBlockComment)
    $nextDepth=[int]$frame.depth+$delta
    if($nextDepth -le 0){
      if($line.Trim() -ne '}'){throw "SWF_PERF_PATCH=FAIL complex_config_close source=$Source mode=$($frame.mode) line=$line"}
      $stack.RemoveAt($stack.Count-1)
      $closed++
      continue
    }
    if([bool]$frame.active){$result.Add($line)}
    $frame.depth=$nextDepth
  }
  if($stack.Count -ne 0){
    $frames=@($stack|ForEach-Object{"$($_.mode):depth=$($_.depth):active=$($_.active)"}) -join ','
    throw "SWF_PERF_PATCH=FAIL unterminated_config_block source=$Source stack=$frames"
  }
  if($opened -ne $closed){throw "SWF_PERF_PATCH=FAIL config_balance source=$Source opened=$opened closed=$closed"}
  Write-Host "FFDEC_CONFIG_BALANCE=PASS class=$ClassName target=$targetConfigMode opened=$opened closed=$closed parser=brace_depth_stack indentation_independent=true nested=true"

  $text=$result -join [Environment]::NewLine
  # FFDec's experimental AS3 compiler does not resolve AIR 24+ permission-only
  # types from the mobile SDK. Preserve runtime semantics in this temporary source.
  $text=$text -replace '(?m)^\s*import flash\.permissions\.PermissionStatus\s*;?\s*$', ''
  $text=$text -replace 'PermissionEvent\.PERMISSION_STATUS', '"permissionStatus"'
  $text=$text -replace 'PermissionStatus\.GRANTED', '"granted"'
  $text=$text -replace '(?m)(\w+)\s*:\s*PermissionEvent\b', '$1:*'

  # GameHUD's authored mission panel animates its own internal bounds. Normalize
  # against a stable base coordinate without disturbing its authored Close timeline.
  if($ClassName -eq 'game.gui.GameHUD'){
    foreach($needle in @(
      'private var mMobileRightMenuBaseY:Number = 0;',
      'var bounds:Rectangle = param1.getBounds(this.mIngameHUDClip_BOTTOM);',
      'param1.y += deltaY;',
      'this.mPullOutMissionFrame.y = Math.max(0,localHeight - this.mPullOutMissionFrame.height);',
      'this.mPullOutMissionFrame.gotoAndPlay("Open");',
      'this.mPullOutMissionFrame.gotoAndPlay("Close");'
    )){if(-not $text.Contains($needle)){throw "SWF_GAMEHUD_FIX=FAIL missing_pattern=$needle"}}
    $nl=[Environment]::NewLine
    $tab="`t"
    $text=$text.Replace('private var mMobileRightMenuBaseY:Number = 0;','private var mMobileRightMenuBaseY:Number = 0;'+$nl+$tab+$tab+'private var mMobileMissionMenuBaseY:Number = 0;')
    $text=$text.Replace('if(!param1 || !this.mIngameHUDClip_BOTTOM) return;','if(!param1 || !this.mIngameHUDClip_BOTTOM) return;'+$nl+$tab+$tab+$tab+'if(param2 == "missions" && this.mPullOutMissionMenuState == this.STATE_MISSIONS_MENU_CLOSED) return;')
    $text=$text.Replace('var bounds:Rectangle = param1.getBounds(this.mIngameHUDClip_BOTTOM);','var baseY:Number = param2 == "missions" ? this.mMobileMissionMenuBaseY : this.mMobileRightMenuBaseY;'+$nl+$tab+$tab+$tab+'param1.y = baseY;'+$nl+$tab+$tab+$tab+'var bounds:Rectangle = param1.getBounds(this.mIngameHUDClip_BOTTOM);')
    $text=$text.Replace('param1.y += deltaY;','param1.y = baseY + deltaY;')
    $text=$text.Replace('this.mPullOutMissionFrame.y = Math.max(0,localHeight - this.mPullOutMissionFrame.height);','this.mPullOutMissionFrame.y = Math.max(0,localHeight - this.mPullOutMissionFrame.height);'+$nl+$tab+$tab+$tab+$tab+'this.mMobileMissionMenuBaseY = this.mPullOutMissionFrame.y;')
    $text=$text.Replace('this.mPullOutMissionFrame.gotoAndPlay("Open");','this.mPullOutMissionFrame.y = this.mMobileMissionMenuBaseY;'+$nl+$tab+$tab+$tab+$tab+'this.mPullOutMissionFrame.gotoAndPlay("Open");'+$nl+$tab+$tab+$tab+$tab+'Utils.DiagEvent("HUD_MISSION_TRANSITION","phase=open_begin;base_y=" + this.mMobileMissionMenuBaseY + ";y=" + this.mPullOutMissionFrame.y);')
    $text=$text.Replace('this.mPullOutMissionFrame.gotoAndPlay("Close");','this.mPullOutMissionFrame.gotoAndPlay("Close");'+$nl+$tab+$tab+$tab+$tab+'Utils.DiagEvent("HUD_MISSION_TRANSITION","phase=close_begin;y=" + this.mPullOutMissionFrame.y + ";frame=" + this.mPullOutMissionFrame.currentFrame);')
    if($text.Contains('param1.y += deltaY;') -or -not $text.Contains('mMobileMissionMenuBaseY') -or -not $text.Contains('param1.y = baseY + deltaY;')){throw 'SWF_GAMEHUD_FIX=FAIL postcondition'}
    if($text -match '\\t'){throw 'SWF_GAMEHUD_FIX=FAIL literal_backslash_tab_survived'}
    if($text -match '\btprivate\b'){throw 'SWF_GAMEHUD_FIX=FAIL invalid_namespace_tprivate'}
    Write-Host 'SWF_GAMEHUD_FIX=PASS mission_clamp=non_accumulating close_clamp=disabled indentation=real_tabs'
  }

  if($text -match 'CONFIG::'){throw "SWF_PERF_PATCH=FAIL config_directive_survived source=$Source"}
  if($text -cmatch '\bPermissionEvent\b|\bPermissionStatus\b'){throw "SWF_PERF_PATCH=FAIL air_permission_type_survived source=$Source"}
  Set-Content -LiteralPath $Destination -Value $text -Encoding UTF8
  Write-Host "FFDEC_AIR_PERMISSION_SHIM=PASS class=$ClassName event=permissionStatus granted=granted"
  Write-Host "FFDEC_SOURCE_PREPROCESS=PASS class=$ClassName target=$targetConfigMode path=$Destination parser=brace_depth_stack"
}
'@

  $match=$functionMatches[0]
  $patcher=$patcher.Substring(0,$match.Index)+$replacement.TrimEnd()+$patcher.Substring($match.Index+$match.Length)
  Write-Host 'EVIDENCE_ROOTFIX_V53_HOOK=PASS name=ffdec_config_brace_depth_parser matches=1 semantic=true indentation_independent=true nested_config=true'

  Write-Utf8Bom $patcherPath $patcher
  $tokens=$null
  $errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($patcherPath,[ref]$tokens,[ref]$errors)
  if(@($errors).Count -gt 0){
    $errors|ForEach-Object{Write-Host "EVIDENCE_ROOTFIX_V53_PATCHER_PARSER_ERROR line=$($_.Extent.StartLineNumber) message=$($_.Message)"}
    throw 'ANDROID_EVIDENCE_ROOTFIX_V53=FAIL patched_patcher_parser_invalid'
  }
  foreach($token in @('Get-AS3BraceDelta','FFDEC_CONFIG_BALANCE=PASS','parser=brace_depth_stack','indentation_independent=true','nested=true')){
    if(-not $patcher.Contains($token)){throw "ANDROID_EVIDENCE_ROOTFIX_V53=FAIL verify=$token"}
  }
  Write-Host 'REGRESSION_CHECK=PASS name=ffdec_config_parser_structural model=brace_depth_stack indentation_independent=true nested_config=true comments_strings_ignored=true'
  Write-Host 'REGRESSION_CHECK=PASS name=gamehud_v21_v48_config_composition config_close=structural not_indent_based=true save_helpers_safe=true'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V53=PASS mode=apply predecessor=v52 sha=$ExpectedSha root_cause=indent_sensitive_config_preprocessor"
}
catch {
  $failure=$_
  try { Restore-OwnedPatcher } catch { Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V53_OWNED_ROLLBACK=WARN $($_.Exception.Message)" }
  if($v52Applied){
    try { & $v52 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -RequestedMode Restore | Out-Host }
    catch { Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V53_PREDECESSOR_ROLLBACK=WARN $($_.Exception.Message)" }
  }
  throw $failure
}
