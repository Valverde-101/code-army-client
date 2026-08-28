param(
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot,
  [int]$Slots=4
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$module=Join-Path $AndroidBuildRoot 'PC-LAUNCHER\Launcher\Core\AndroidBuild.AutoRepo.psm1'
if(-not (Test-Path -LiteralPath $module)){throw "AUTOREPO_POOL=FAIL module_missing=$module"}
$psExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Test-Broker([int]$Slot){
  foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue)){
    $cmd=[string]$p.CommandLine
    if($cmd -and $cmd -match [regex]::Escape($module) -and $cmd -match '(?i)Run-AutoRepoBroker' -and $cmd -match ('(?i)-Slot\s+'+$Slot+'(?:\s|$)')){return $true}
  }
  return $false
}

for($slot=1;$slot -le $Slots;$slot++){
  if(Test-Broker $slot){Write-Host "AUTOREPO_BROKER_SLOT=ALREADY_RUNNING slot=$slot";continue}
  $moduleEsc=$module.Replace("'","''")
  $rootEsc=$AndroidBuildRoot.Replace("'","''")
  $command="Import-Module '$moduleEsc' -Force; Run-AutoRepoBroker -AndroidBuildRoot '$rootEsc' -Owner 'Valverde-101' -Slot $slot -PollSeconds 5 -ReservationSeconds 90"
  $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
  $proc=Start-Process -FilePath $psExe -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-EncodedCommand',$encoded) -WindowStyle Hidden -PassThru
  Write-Host "AUTOREPO_BROKER_SLOT=STARTED slot=$slot pid=$($proc.Id)"
}

$deadline=(Get-Date).AddSeconds(90)
do{
  Start-Sleep -Seconds 5
  $brokers=0
  foreach($slot in 1..$Slots){if(Test-Broker $slot){$brokers++}}
  $listeners=@(Get-CimInstance Win32_Process -Filter "Name='Runner.Listener.exe'" -ErrorAction SilentlyContinue | Where-Object { [string]$_.ExecutablePath -like "$AndroidBuildRoot\Runners\AutoRepos\slot-*\bin\Runner.Listener.exe" })
  Write-Host "AUTOREPO_POOL_STATUS brokers=$brokers listeners=$($listeners.Count)"
  if($brokers -ge $Slots -and $listeners.Count -ge 1){break}
}while((Get-Date) -lt $deadline)

for($slot=1;$slot -le $Slots;$slot++){
  if(Test-Broker $slot){Write-Host "AUTOREPO_SLOT=PASS slot=$slot"}else{throw "AUTOREPO_SLOT=FAIL slot=$slot"}
}
Write-Host "AUTOREPO_POOL=PASS slots=$Slots"
