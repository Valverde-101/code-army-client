param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$buildScript=Join-Path $PSScriptRoot 'Build-Android.ps1'
if(-not (Test-Path -LiteralPath $buildScript)){throw "RENDER_AB=FAIL build_script_missing=$buildScript"}
$outRoot=Join-Path $AndroidBuildRoot "Builds\code-army-client\$ExpectedSha\android"
$abRoot=Join-Path $outRoot 'render-ab'
if(Test-Path -LiteralPath $abRoot){Remove-Item -LiteralPath $abRoot -Recurse -Force}
New-Item -ItemType Directory -Force -Path $abRoot|Out-Null

$rows=New-Object System.Collections.Generic.List[object]
foreach($mode in @('direct','gpu')){
  Write-Host "RENDER_AB_BUILD_START mode=$mode sha=$ExpectedSha"
  & $buildScript -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -AndroidBuildRoot $AndroidBuildRoot -RenderMode $mode
  if($LASTEXITCODE -and $LASTEXITCODE -ne 0){throw "RENDER_AB=FAIL mode=$mode build_exit=$LASTEXITCODE"}
  $apk=Get-ChildItem -LiteralPath $outRoot -File -Filter "*-$mode.apk" -ErrorAction Stop|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 1
  if(-not $apk){throw "RENDER_AB=FAIL mode=$mode apk_missing"}
  $apkSha=(Get-FileHash -LiteralPath $apk.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  $provPath=Join-Path $outRoot 'BUILD-PROVENANCE.json'
  if(-not (Test-Path -LiteralPath $provPath)){throw "RENDER_AB=FAIL mode=$mode provenance_missing"}
  $prov=Get-Content -LiteralPath $provPath -Raw|ConvertFrom-Json
  if([string]$prov.render_mode -ne $mode){throw "RENDER_AB=FAIL mode=$mode provenance_render_mode=$($prov.render_mode)"}
  $provCopy=Join-Path $abRoot "BUILD-PROVENANCE-$mode.json"
  Copy-Item -LiteralPath $provPath -Destination $provCopy -Force
  $rows.Add([pscustomobject]@{
    tested_sha=$ExpectedSha
    render_mode=$mode
    apk_path=$apk.FullName
    apk_size=$apk.Length
    apk_sha256=$apkSha
    swf_sha256=[string]$prov.swf_sha256
    profiler_mode=[string]$prov.native_performance_overlay_mode
  })
  Write-Host "RENDER_AB_BUILD=PASS mode=$mode apk=$($apk.FullName) apk_sha256=$apkSha swf_sha256=$($prov.swf_sha256)"
}
$manifest=Join-Path $abRoot 'render-ab.json'
$rows|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $manifest -Encoding UTF8
$swfHashes=@($rows|Select-Object -ExpandProperty swf_sha256 -Unique)
if($swfHashes.Count -ne 1){throw "RENDER_AB=FAIL swf_mismatch=$($swfHashes -join ',')"}
Write-Host "RENDER_AB=PASS tested_sha=$ExpectedSha modes=direct,gpu same_swf_sha256=$($swfHashes[0]) manifest=$manifest"
