param(
  [Parameter(Mandatory=$true)][string]$RepositoryRoot
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$scenePath=Join-Path $RepositoryRoot 'src\game\isometric\IsometricScene.as'
$testPath=Join-Path $RepositoryRoot 'Tools\CI\Test-AndroidRuntimePatch.ps1'
foreach($path in @($scenePath,$testPath)){
  if(-not(Test-Path -LiteralPath $path)){throw "TOOLTIP_TIMER_FIX=FAIL missing=$path"}
}

$scene=Get-Content -LiteralPath $scenePath -Raw
$originalScene=$scene

if($scene -notmatch 'TOOLTIP_TIMEOUT_MS'){
  $declarationPattern='(?m)^\s*private const mAppearDelayMs: int = Math\.ceil\(1000 / GameState\.mInstance\.getMainClip\(\)\.stage\.frameRate\);\s*$'
  if($scene -notmatch $declarationPattern){throw 'TOOLTIP_TIMER_FIX=FAIL declaration_pattern_missing'}
  $scene=[regex]::Replace($scene,$declarationPattern,"`t`tprivate static const TOOLTIP_TIMEOUT_MS: int = 1000;")
}

if($scene -notmatch 'private function stopToolTipTimer\(\): void'){
  $timerBlockPattern='(?s)\t\tpublic function startToolTipTimer\(\): void \{.*?\n\t\t\}\s*\n\s*\t\tpublic function appearTimerTick\(param1: TimerEvent\): void \{.*?\n\t\t\}\s*\n\s*\t\tpublic function initTileMap\(\): void \{'
  if($scene -notmatch $timerBlockPattern){throw 'TOOLTIP_TIMER_FIX=FAIL timer_block_pattern_missing'}
  $replacement=@'
		private function stopToolTipTimer(): void {
			if (this.mAppearTimer) {
				this.mAppearTimer.removeEventListener(TimerEvent.TIMER_COMPLETE, this.appearTimerComplete);
				this.mAppearTimer.stop();
				this.mAppearTimer = null;
			}
		}

		public function startToolTipTimer(): void {
			this.stopToolTipTimer();
			this.mAppearTimer = new Timer(TOOLTIP_TIMEOUT_MS, 1);
			this.mAppearTimer.addEventListener(TimerEvent.TIMER_COMPLETE, this.appearTimerComplete, false, 0, true);
			this.mAppearTimer.start();
		}

		private function appearTimerComplete(param1: TimerEvent): void {
			this.stopToolTipTimer();
			this.hideObjectTooltip();
		}

		public function initTileMap(): void {
'@
  $scene=[regex]::Replace($scene,$timerBlockPattern,[System.Text.RegularExpressions.MatchEvaluator]{param($m)$replacement},1)
}

if($scene -notmatch '(?s)public function destroy\(\): void \{\s*this\.stopToolTipTimer\(\);'){
  $destroyPattern='public function destroy\(\): void \{'
  if($scene -notmatch $destroyPattern){throw 'TOOLTIP_TIMER_FIX=FAIL destroy_pattern_missing'}
  $scene=[regex]::Replace($scene,$destroyPattern,"public function destroy(): void {`r`n`t`t`tthis.stopToolTipTimer();",1)
}

foreach($forbidden in @('mAppearDelayMs','currentCount > this.mAppearDelayMs','TimerEvent.TIMER, this.appearTimerTick')){
  if($scene.Contains($forbidden)){throw "TOOLTIP_TIMER_FIX=FAIL stale_pattern=$forbidden"}
}
foreach($required in @('private static const TOOLTIP_TIMEOUT_MS: int = 1000;','new Timer(TOOLTIP_TIMEOUT_MS, 1)','TimerEvent.TIMER_COMPLETE, this.appearTimerComplete','private function stopToolTipTimer(): void','this.stopToolTipTimer();')){
  if(-not $scene.Contains($required)){throw "TOOLTIP_TIMER_FIX=FAIL required_pattern=$required"}
}
if($scene -ne $originalScene){Set-Content -LiteralPath $scenePath -Value $scene -Encoding UTF8}

$test=Get-Content -LiteralPath $testPath -Raw
$originalTest=$test
if($test -notmatch "tooltip_timer_one_shot"){
  $anchor="$audit=Join-Path `$RepoRoot 'Tools\\CI\\Audit-SwfCore.ps1'"
  if(-not $test.Contains($anchor)){throw 'TOOLTIP_TIMER_FIX=FAIL regression_anchor_missing'}
  $checks=@'
Require-Contains $scene 'private static const TOOLTIP_TIMEOUT_MS: int = 1000;' 'tooltip_timer_fixed_wall_clock_timeout'
Require-Contains $scene 'new Timer(TOOLTIP_TIMEOUT_MS, 1)' 'tooltip_timer_one_shot'
Require-Contains $scene 'TimerEvent.TIMER_COMPLETE, this.appearTimerComplete' 'tooltip_timer_uses_completion_event'
Require-Contains $scene 'private function stopToolTipTimer(): void' 'tooltip_timer_has_idempotent_cleanup'
Require-Contains $scene 'public function destroy(): void {' 'scene_destroy_exists_for_timer_cleanup'
Require-NotContains $scene 'mAppearDelayMs' 'tooltip_timer_no_frame_rate_derived_delay'
Require-NotContains $scene 'currentCount > this.mAppearDelayMs' 'tooltip_timer_no_ms_as_tick_count'
'@
  $test=$test.Replace($anchor,$checks+"`r`n"+$anchor)
}
$test=$test.Replace("REGRESSION=PASS suite=android-runtime-v3.11-pvp-ai-progress","REGRESSION=PASS suite=android-runtime-v3.12-tooltip-timer-lifecycle")
if($test -ne $originalTest){Set-Content -LiteralPath $testPath -Value $test -Encoding UTF8}

Write-Host 'TOOLTIP_TIMER_FIX=PASS timeout_ms=1000 repeat_count=1 lifecycle_cleanup=true'
