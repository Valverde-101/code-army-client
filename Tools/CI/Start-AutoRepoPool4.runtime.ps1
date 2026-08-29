param(
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot,
  [int]$Slots=4
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$module=Join-Path $AndroidBuildRoot 'PC-LAUNCHER\Launcher\Core\AndroidBuild.AutoRepo.psm1'
if(-not (Test-Path -LiteralPath $module)){throw "AUTOREPO_POOL=FAIL module_missing=$module"}
$psExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$logDir=Join-Path $AndroidBuildRoot 'PC-LAUNCHER\Logs\AutoRepoPool4'
New-Item -ItemType Directory -Force -Path $logDir|Out-Null

function Get-BrokerCommandText($Process){
  $cmd=[string]$Process.CommandLine
  if(-not $cmd){return ''}
  $decoded=''
  if($cmd -match '(?i)-EncodedCommand\s+["'']?([A-Za-z0-9+/=]+)'){
    try{$decoded=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($matches[1]))}catch{}
  }
  return ($cmd+' '+$decoded)
}

function Test-Broker([int]$Slot){
  foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue)){
    $text=Get-BrokerCommandText $p
    if($text -and $text -match [regex]::Escape($module) -and $text -match '(?i)Run-AutoRepoBroker' -and $text -match ('(?i)-Slot\s+'+$Slot+'(?:\s|$)')){return $true}
  }
  return $false
}

for($slot=1;$slot -le $Slots;$slot++){
  if(Test-Broker $slot){Write-Host "AUTOREPO_BROKER_SLOT=ALREADY_RUNNING slot=$slot";continue}
  $moduleEsc=$module.Replace("'","''")
  $rootEsc=$AndroidBuildRoot.Replace("'","''")
  $command="Import-Module '$moduleEsc' -Force; Run-AutoRepoBroker -AndroidBuildRoot '$rootEsc' -Owner 'Valverde-101' -Slot $slot -PollSeconds 5 -ReservationSeconds 90"
  $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
  $stdout=Join-Path $logDir ("slot-"+$slot+".out.log")
  $stderr=Join-Path $logDir ("slot-"+$slot+".err.log")
  $tracking=$env:RUNNER_TRACKING_ID
  try{
    Remove-Item Env:RUNNER_TRACKING_ID -ErrorAction SilentlyContinue
    $proc=Start-Process -FilePath $psExe -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-EncodedCommand',$encoded) -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
  }finally{
    if($null -ne $tracking){$env:RUNNER_TRACKING_ID=$tracking}
  }
  Write-Host "AUTOREPO_BROKER_SLOT=STARTED slot=$slot pid=$($proc.Id) stdout=$stdout stderr=$stderr"
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
  if(Test-Broker $slot){
    Write-Host "AUTOREPO_SLOT=PASS slot=$slot"
  }else{
    $outLog=Join-Path $logDir ("slot-"+$slot+".out.log")
    $errLog=Join-Path $logDir ("slot-"+$slot+".err.log")
    if(Test-Path -LiteralPath $outLog){Get-Content -LiteralPath $outLog -Tail 30|ForEach-Object{Write-Host "AUTOREPO_SLOT_STDOUT slot=$slot $_"}}
    if(Test-Path -LiteralPath $errLog){Get-Content -LiteralPath $errLog -Tail 30|ForEach-Object{Write-Host "AUTOREPO_SLOT_STDERR slot=$slot $_"}}
    throw "AUTOREPO_SLOT=FAIL slot=$slot"
  }
}
Write-Host "AUTOREPO_POOL=PASS slots=$Slots log_dir=$logDir"
