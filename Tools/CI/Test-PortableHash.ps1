param([string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$env:ARMY_TEST_PORTABLE_HASH='1'
try {
  . (Join-Path $PSScriptRoot 'Ensure-PortableFileHash.ps1')
  $file=Join-Path ([IO.Path]::GetTempPath()) ('army-hash-test-'+[Guid]::NewGuid().ToString('N')+'.txt')
  try {
    [IO.File]::WriteAllBytes($file,[Text.Encoding]::ASCII.GetBytes('abc'))
    $expected='BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD'
    $a=Get-FileHash -LiteralPath $file -Algorithm SHA256
    $b=Get-FileHash $file -Algorithm SHA256
    if($a.Hash -ne $expected -or $b.Hash -ne $expected){throw "PORTABLE_HASH_TEST=FAIL literal=$($a.Hash) positional=$($b.Hash) expected=$expected"}
    if(-not (Test-Path -LiteralPath $a.Path -PathType Leaf)){throw 'PORTABLE_HASH_TEST=FAIL output_path'}
    Write-Host "PORTABLE_HASH_TEST=PASS algorithm=$($a.Algorithm) literal=true positional=true"
  }finally{
    if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file -Force}
  }
}finally{
  Remove-Item Env:ARMY_TEST_PORTABLE_HASH -ErrorAction SilentlyContinue
}
