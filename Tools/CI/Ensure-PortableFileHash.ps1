# Portable SHA-256 compatibility for isolated PowerShell 5.1 self-hosted runners.
# Native Get-FileHash is preferred; this fallback returns compatible Hash/Path/Algorithm.
if (-not (Get-Command Get-FileHash -ErrorAction SilentlyContinue) -or $env:ARMY_TEST_PORTABLE_HASH -eq '1') {
    function global:Get-FileHash {
        [CmdletBinding(DefaultParameterSetName='Path')]
        param(
            [Parameter(Position=0,ParameterSetName='Path',ValueFromPipelineByPropertyName=$true)]
            [string[]]$Path,
            [Parameter(Mandatory=$true,ParameterSetName='LiteralPath',ValueFromPipelineByPropertyName=$true)]
            [string[]]$LiteralPath,
            [ValidateSet('SHA256','SHA384','SHA512','SHA1','MD5')]
            [string]$Algorithm='SHA256'
        )
        process {
            $inputPaths=if($PSCmdlet.ParameterSetName -eq 'LiteralPath'){@($LiteralPath)}else{@($Path)}
            foreach($inputPath in $inputPaths) {
                if([string]::IsNullOrWhiteSpace($inputPath)){throw 'PORTABLE_HASH=FAIL empty_path'}
                $resolved=if($PSCmdlet.ParameterSetName -eq 'LiteralPath'){
                    (Resolve-Path -LiteralPath $inputPath -ErrorAction Stop).ProviderPath
                }else{
                    (Resolve-Path -Path $inputPath -ErrorAction Stop).ProviderPath
                }
                $stream=[IO.File]::OpenRead($resolved)
                try {
                    $hasher=[Security.Cryptography.HashAlgorithm]::Create($Algorithm)
                    if($null -eq $hasher){throw "PORTABLE_HASH=FAIL algorithm=$Algorithm"}
                    try {
                        $hash=([BitConverter]::ToString($hasher.ComputeHash($stream))).Replace('-','')
                        [pscustomobject]@{Algorithm=$Algorithm;Hash=$hash;Path=$resolved}
                    }finally{$hasher.Dispose()}
                }finally{$stream.Dispose()}
            }
        }
    }
    Write-Host 'PORTABLE_HASH_PROVIDER=PASS source=dotnet_compatibility'
}
