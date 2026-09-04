# ANDROIDBUILD_CORE_SHIM: FFDec binary ownership moved to AndroidBuild Core 3.0.9+
param(
  [Parameter(Mandatory=$true)][string]$RepositoryRoot,
  [string]$Version='26.2.1',
  [string]$DownloadUri,
  [string]$ExpectedSha256='0333b56998a55bd83f4e0deb678a811fcdc45607582b4f5dd438309c8c3ad5ce'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=@($env:ANDROIDBUILD_ROOT,'V:\AndroidBuild','D:\AndroidBuild','C:\AndroidBuild')|Where-Object{$_ -and (Test-Path -LiteralPath $_ -PathType Container)}|Select-Object -First 1
if(-not $root){throw 'FFDEC_CORE_SHIM=FAIL androidbuild_root_not_found'}
$root=(Resolve-Path -LiteralPath $root).Path
Import-Module (Join-Path $root 'Core\Current\AndroidBuild.psd1') -DisableNameChecking -Force
if([version](Get-AndroidBuildCoreVersion) -lt [version]'3.0.9'){throw 'FFDEC_CORE_SHIM=FAIL core_minimum=3.0.9'}
$args=@{AndroidBuildRoot=$root;Version=$Version;ExpectedSha256=$ExpectedSha256}
if($DownloadUri){$args.DownloadUri=$DownloadUri}
$r=Ensure-AndroidBuildFFDec @args
if([string]$r.status -ne 'PASS'){throw 'FFDEC_CORE_SHIM=FAIL resolver'}
# Existing Army patchers discover FFDec under .work/tools. Keep only a junction; no duplicated executable bytes.
$compatRoot=Join-Path $RepositoryRoot '.work\tools\ffdec'
$compat=Join-Path $compatRoot $Version
New-Item -ItemType Directory -Force -Path $compatRoot|Out-Null
if(Test-Path -LiteralPath $compat){
  $item=Get-Item -LiteralPath $compat -Force
  $same=$false
  if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){
    $target=$item.Target;if($target -is [array]){$target=$target|Select-Object -First 1}
    if($target){$same=([IO.Path]::GetFullPath([string]$target).TrimEnd('\') -ieq [IO.Path]::GetFullPath([string]$r.root).TrimEnd('\'))}
    if(-not $same){$cmd=(Get-Command cmd.exe -ErrorAction Stop).Source;& $cmd /d /c ('rmdir "{0}"' -f $compat)|Out-Null}
  }else{Remove-Item -LiteralPath $compat -Recurse -Force}
}
if(-not(Test-Path -LiteralPath $compat)){New-Item -ItemType Junction -Path $compat -Target ([string]$r.root)|Out-Null}
Write-Host "FFDEC_READY=PASS provider=androidbuild-core version=$Version path=$($r.path) compatibility_alias=$compat duplicated_bytes=false"
$r.path
