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
    $desktopPatcher=[IO.File]::ReadAllText((Join-Path $RepoRoot 'Tools\CI\Patch-WindowsSharedSwf.ps1'))
    $basePatcher=[IO.File]::ReadAllText((Join-Path $RepoRoot 'Tools\CI\Patch-AndroidPerformanceSwf.ps1'))
    $originalDirective=". (Join-Path `$PSScriptRoot 'Ensure-PortableFileHash.ps1')"
    $generatedDirective=". (Join-Path `$RepoRoot 'Tools\CI\Ensure-PortableFileHash.ps1')"
    # Source contains PowerShell's literal backtick before `$RepoRoot; the generated
    # script contains the unescaped variable. Verify both roles independently.
    if(-not $basePatcher.Contains($originalDirective) -or -not $desktopPatcher.Contains('$desktopText=$desktopText.Replace($hashDirective,') -or -not $desktopPatcher.Contains('Tools\CI\Ensure-PortableFileHash.ps1') -or -not $generatedDirective.Contains('Tools\CI\Ensure-PortableFileHash.ps1')){
      throw 'WINDOWS_GENERATED_HASH_ROOT=FAIL relative_path_or_rewrite_missing'
    }
    Write-Host 'WINDOWS_GENERATED_HASH_ROOT=PASS source=repo_root generated_path=scratch_safe'
  }finally{
    if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file -Force}
  }
}finally{
  Remove-Item Env:ARMY_TEST_PORTABLE_HASH -ErrorAction SilentlyContinue
}
