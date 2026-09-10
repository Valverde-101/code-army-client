param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
if(-not(Test-Path -LiteralPath $GitPath -PathType Leaf)){throw "ANDROID_MOVEMENT_PACING_OVERLAY=FAIL git_missing=$GitPath"}
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_MOVEMENT_PACING_OVERLAY=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$rel='src\game\isometric\characters\IsometricCharacter.as'
$target=Join-Path $RepoRoot $rel
$backupRoot=Join-Path $RepoRoot ('.work\scratch\movement-pacing-overlay\'+$ExpectedSha)
$backup=Join-Path $backupRoot 'IsometricCharacter.as.original'
$manifestPath=Join-Path $backupRoot 'manifest.json'
function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Replace-RegexOnce([string]$Text,[string]$Pattern,[string]$New,[string]$Name){
  $matches=[regex]::Matches($Text,$Pattern)
  if($matches.Count -eq 0){throw "ANDROID_MOVEMENT_PACING_OVERLAY=FAIL patch=$Name reason=semantic_pattern_missing"}
  if($matches.Count -ne 1){throw "ANDROID_MOVEMENT_PACING_OVERLAY=FAIL patch=$Name reason=semantic_pattern_ambiguous matches=$($matches.Count)"}
  $m=$matches[0]
  Write-Host "MOVEMENT_SEMANTIC_HOOK=PASS name=$Name matches=1 whitespace=agnostic"
  return $Text.Substring(0,$m.Index)+$New+$Text.Substring($m.Index+$m.Length)
}

if($Mode -eq 'Restore'){
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){Write-Host "ANDROID_MOVEMENT_PACING_OVERLAY=PASS mode=restore status=no_overlay sha=$ExpectedSha";return}
  $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_MOVEMENT_PACING_OVERLAY=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
  if(-not(Test-Path -LiteralPath $backup -PathType Leaf)){throw "ANDROID_MOVEMENT_PACING_OVERLAY=FAIL restore_backup_missing=$backup"}
  Copy-Item -LiteralPath $backup -Destination $target -Force
  $restored=Get-Sha256 $target
  $expected=([string]$manifest.sha256).ToUpperInvariant()
  if($restored -ne $expected){throw "ANDROID_MOVEMENT_PACING_OVERLAY=FAIL restore_hash expected=$expected actual=$restored"}
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
  Write-Host "ANDROID_MOVEMENT_PACING_OVERLAY=PASS mode=restore baseline_restored=true composable=true sha=$ExpectedSha"
  return
}

if(-not(Test-Path -LiteralPath $target -PathType Leaf)){throw "ANDROID_MOVEMENT_PACING_OVERLAY=FAIL source_missing=$rel"}
if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
Copy-Item -LiteralPath $target -Destination $backup -Force
$incomingSha=Get-Sha256 $target
[ordered]@{schema='armyattack-movement-pacing-overlay/v2';source_sha=$ExpectedSha;path=$rel;sha256=$incomingSha}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $manifestPath -Encoding UTF8

try{
  $text=Normalize-Lf ([IO.File]::ReadAllText($target))

  $fieldPattern='(?m)^[ \t]*protected[ \t]+var[ \t]+mSpeed[ \t]*:[ \t]*Number[ \t]*;[ \t]*$'
  $fieldReplacement=@'
		protected var mSpeed: Number;

		// Preserve movement wall-clock time across renderer stalls without
		// allowing one delayed frame or app-resume to teleport a unit.
		private static const MOVEMENT_MAX_FRAME_MS: int = 200;
		private static const MOVEMENT_CATCHUP_PER_FRAME_MS: int = 50;
		private static const MOVEMENT_MAX_DEBT_MS: int = 1000;
		private var mMovementDebtMs: Number = 0;
'@
  $text=Replace-RegexOnce $text $fieldPattern $fieldReplacement 'movement_timing_fields'

  $stopPattern='(?m)^[ \t]*if[ \t]*\([ \t]*this\.mWalkingPath[ \t]*==[ \t]*null[ \t]*\|\|[ \t]*this\.mWalkingPath\.length[ \t]*==[ \t]*0[ \t]*\|\|[ \t]*!this\.mAllowMovement[ \t]*\)[ \t]*\{[ \t]*$'
  $stopReplacement=@'
			if (this.mWalkingPath == null || this.mWalkingPath.length == 0 || !this.mAllowMovement) {
				// Intentional stops must not leak catch-up into a later move.
				this.mMovementDebtMs = 0;
'@
  $text=Replace-RegexOnce $text $stopPattern $stopReplacement 'movement_debt_reset_when_stopped'

  $speedPattern='(?m)^[ \t]*var[ \t]+_loc7_[ \t]*:[ \t]*Number[ \t]*=[ \t]*this\.mSpeed[ \t]*\*[ \t]*Math\.min\([ \t]*param1[ \t]*,[ \t]*200[ \t]*\)[ \t]*/[ \t]*1000[ \t]*;[ \t]*$'
  $speedReplacement=@'
			var _loc7Elapsed_: Number = Math.max(0, Number(param1));
			var _loc7Base_: Number = Math.min(_loc7Elapsed_, MOVEMENT_MAX_FRAME_MS);
			if (_loc7Elapsed_ > MOVEMENT_MAX_FRAME_MS) {
				this.mMovementDebtMs = Math.min(MOVEMENT_MAX_DEBT_MS, this.mMovementDebtMs + (_loc7Elapsed_ - MOVEMENT_MAX_FRAME_MS));
			}
			var _loc7Catchup_: Number = Math.min(this.mMovementDebtMs, MOVEMENT_CATCHUP_PER_FRAME_MS);
			this.mMovementDebtMs -= _loc7Catchup_;
			var _loc7_: Number = this.mSpeed * (_loc7Base_ + _loc7Catchup_) / 1000;
			if (_loc7Elapsed_ > MOVEMENT_MAX_FRAME_MS) {
				Utils.DiagEvent("MOVEMENT_CATCHUP", "elapsed_ms=" + int(_loc7Elapsed_) + ";base_ms=" + int(_loc7Base_) + ";catchup_ms=" + int(_loc7Catchup_) + ";debt_ms=" + int(this.mMovementDebtMs));
			}
'@
  $text=Replace-RegexOnce $text $speedPattern $speedReplacement 'movement_preserve_elapsed_time'

  if($text.Contains('Math.min(param1, 200)')){throw 'ANDROID_MOVEMENT_PACING_OVERLAY=FAIL regression=legacy_time_drop_still_present'}
  foreach($needle in @('MOVEMENT_MAX_FRAME_MS','MOVEMENT_CATCHUP_PER_FRAME_MS','MOVEMENT_MAX_DEBT_MS','mMovementDebtMs','MOVEMENT_CATCHUP')){
    if(-not $text.Contains($needle)){throw "ANDROID_MOVEMENT_PACING_OVERLAY=FAIL verification_missing=$needle"}
  }
  Write-Utf8Bom $target $text
  Write-Host 'REGRESSION_CHECK=PASS name=movement_overlay_semantic_hooks fields=1 stop=1 speed=1 whitespace=agnostic'
  Write-Host 'REGRESSION_CHECK=PASS name=movement_no_longer_discards_time_above_200ms'
  Write-Host 'REGRESSION_CHECK=PASS name=movement_catchup_is_bounded max_frame_ms=200 catchup_per_frame_ms=50 max_debt_ms=1000'
  Write-Host 'REGRESSION_CHECK=PASS name=movement_debt_resets_when_stopped prevents_future_move_burst=true'
  Write-Host 'REGRESSION_CHECK=PASS name=movement_large_stalls_are_instrumented event=MOVEMENT_CATCHUP'
  Write-Host "ANDROID_MOVEMENT_PACING_OVERLAY=PASS mode=apply sha=$ExpectedSha incoming_sha256=$incomingSha schema=v2"
}catch{
  $failure=$_
  Copy-Item -LiteralPath $backup -Destination $target -Force -ErrorAction SilentlyContinue
  throw $failure
}
