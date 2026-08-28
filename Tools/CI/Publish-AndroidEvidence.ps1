param(
  [Parameter(Mandatory=$true)][string]$RepoCheckoutRoot,
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$RunId,
  [Parameter(Mandatory=$true)][string]$SourceBranch,
  [string]$EvidenceBranch='evidence/army-attack-logs'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$repoName='Valverde-101/code-army-client'
$buildRoot=Join-Path $AndroidBuildRoot "Builds\code-army-client\$ExpectedSha"
$androidRoot=Join-Path $buildRoot 'android'
$referenceRoot=Join-Path $buildRoot 'android-upstream-v21.1'
if(-not (Test-Path -LiteralPath $RepoCheckoutRoot)){throw "LOG_PUBLISH=FAIL checkout_missing=$RepoCheckoutRoot"}
if(-not (Test-Path -LiteralPath $buildRoot)){throw "LOG_PUBLISH=FAIL build_root_missing=$buildRoot"}

$git=(Get-Command git.exe -ErrorAction Stop).Source
$checkoutHead=(& $git -C $RepoCheckoutRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $checkoutHead -ne $ExpectedSha){
  throw "LOG_PUBLISH=FAIL checkout_sha expected=$ExpectedSha actual=$checkoutHead"
}

$remoteHead=(& $git -C $RepoCheckoutRoot ls-remote origin "refs/heads/$SourceBranch" | Out-String).Trim()
$remoteSourceSha=''
if($remoteHead){$remoteSourceSha=($remoteHead -split '\s+')[0]}
$stale=($remoteSourceSha -and $remoteSourceSha -ne $ExpectedSha)

$tempRoot=Join-Path $env:RUNNER_TEMP ("army-attack-evidence-"+$RunId+"-"+[Guid]::NewGuid().ToString('N'))
$stage=Join-Path $tempRoot 'stage'
$worktree=Join-Path $tempRoot 'repo'
New-Item -ItemType Directory -Force -Path $stage | Out-Null

$allowedText=@('.log','.txt','.json','.md','.xml','.csv')
$allowedImage=@('.png')
$maxTextBytes=5MB
$maxImageBytes=10MB
$published=New-Object System.Collections.Generic.List[object]
$skipped=New-Object System.Collections.Generic.List[object]

function Sanitize-Text([string]$Text){
  $v=$Text
  $v=[regex]::Replace($v,'(?im)(Authorization:\s*(?:Bearer|Basic)\s+)[^\r\n]+','$1[REDACTED]')
  $v=[regex]::Replace($v,'(?im)(Cookie:\s*)[^\r\n]+','$1[REDACTED]')
  $v=[regex]::Replace($v,'(?i)\bgh[pousr]_[A-Za-z0-9_]{20,}\b','[REDACTED_GITHUB_TOKEN]')
  $v=[regex]::Replace($v,'(?im)((?:token|password|passwd|secret|api[_-]?key|client[_-]?secret)\s*[:=]\s*)[^\s\r\n]+','$1[REDACTED]')
  $v=[regex]::Replace($v,'(?s)-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----.*?-----END (?:RSA |EC |OPENSSH )?PRIVATE KEY-----','[REDACTED_PRIVATE_KEY]')
  return $v
}

function Copy-EvidenceFile([string]$Source,[string]$Relative){
  if(-not (Test-Path -LiteralPath $Source)){return}
  $item=Get-Item -LiteralPath $Source
  if($item.PSIsContainer){return}
  $ext=$item.Extension.ToLowerInvariant()
  $dest=Join-Path $stage $Relative
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null

  if($allowedText -contains $ext){
    if($item.Length -gt $maxTextBytes){
      $content=(Get-Content -LiteralPath $Source -Tail 20000 -ErrorAction Stop) -join [Environment]::NewLine
      $content="[TRUNCATED_TO_LAST_20000_LINES original_bytes=$($item.Length)]"+[Environment]::NewLine+$content
    } else {
      $content=Get-Content -LiteralPath $Source -Raw -ErrorAction Stop
    }
    $sanitized=Sanitize-Text $content
    $sanitized | Set-Content -LiteralPath $dest -Encoding UTF8
  } elseif($allowedImage -contains $ext){
    if($item.Length -gt $maxImageBytes){
      $skipped.Add([ordered]@{source=$Source;reason='image_too_large';bytes=$item.Length})
      return
    }
    Copy-Item -LiteralPath $Source -Destination $dest -Force
  } else {
    $skipped.Add([ordered]@{source=$Source;reason='extension_not_allowed';extension=$ext;bytes=$item.Length})
    return
  }

  $out=Get-Item -LiteralPath $dest
  $hash=(Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLowerInvariant()
  $published.Add([ordered]@{path=$Relative.Replace('\','/');bytes=$out.Length;sha256=$hash})
}

if(Test-Path -LiteralPath $androidRoot){
  foreach($file in @(Get-ChildItem -LiteralPath $androidRoot -Recurse -File -ErrorAction SilentlyContinue)){
    $relative=$file.FullName.Substring($androidRoot.Length).TrimStart('\','/')
    Copy-EvidenceFile $file.FullName (Join-Path 'android' $relative)
  }
}
if(Test-Path -LiteralPath $referenceRoot){
  foreach($file in @(Get-ChildItem -LiteralPath $referenceRoot -Recurse -File -ErrorAction SilentlyContinue)){
    $relative=$file.FullName.Substring($referenceRoot.Length).TrimStart('\','/')
    Copy-EvidenceFile $file.FullName (Join-Path 'reference-v21.1' $relative)
  }
}

# Explicitly prove forbidden local payloads are not staged.
$forbidden=@('.apk','.aab','.p12','.pfx','.keystore','.jks','.zip','.7z','.exe','.dll','.so','.swf')
$badStage=@(Get-ChildItem -LiteralPath $stage -Recurse -File -ErrorAction SilentlyContinue | Where-Object {$forbidden -contains $_.Extension.ToLowerInvariant()})
if($badStage.Count -gt 0){throw "LOG_PUBLISH=FAIL forbidden_staged=$($badStage.FullName -join ',')"}

$manifest=[ordered]@{
  schema_version=1
  repository=$repoName
  tested_sha=$ExpectedSha
  source_branch=$SourceBranch
  remote_source_sha=$remoteSourceSha
  stale_test_result=[bool]$stale
  run_id=$RunId
  runner_name=$env:RUNNER_NAME
  local_build_root=$buildRoot
  apk_uploaded=$false
  github_artifacts_used=$false
  evidence_branch=$EvidenceBranch
  published_files=@($published)
  skipped_files=@($skipped)
}
$manifestPath=Join-Path $stage 'manifest.json'
$manifest|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $manifestPath -Encoding UTF8

# Final secret/forbidden scan of staged text.
foreach($file in @(Get-ChildItem -LiteralPath $stage -Recurse -File | Where-Object {$allowedText -contains $_.Extension.ToLowerInvariant()})){
  $text=Get-Content -LiteralPath $file.FullName -Raw
  if($text -match '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'){throw "LOG_PUBLISH=FAIL private_key_marker=$($file.FullName)"}
  if($text -match '\bgh[pousr]_[A-Za-z0-9_]{20,}\b'){throw "LOG_PUBLISH=FAIL github_token_marker=$($file.FullName)"}
}

try{
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $worktree) | Out-Null

  $previousEap=$ErrorActionPreference
  try{
    $ErrorActionPreference='Continue'
    & $git -C $RepoCheckoutRoot fetch origin $EvidenceBranch *> $null
    $fetchExit=$LASTEXITCODE
  } finally {
    $ErrorActionPreference=$previousEap
  }
  $hasRemote=($fetchExit -eq 0)
  if($hasRemote){
    & $git -C $RepoCheckoutRoot worktree add -B $EvidenceBranch $worktree "origin/$EvidenceBranch"
  } else {
    & $git -C $RepoCheckoutRoot worktree add -B $EvidenceBranch $worktree $ExpectedSha
  }
  if($LASTEXITCODE -ne 0){throw "LOG_PUBLISH=FAIL worktree_add exit=$LASTEXITCODE"}

  $dest=Join-Path $worktree "Logs\android\$ExpectedSha\$RunId"
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  foreach($child in @(Get-ChildItem -LiteralPath $stage -Force)){
    Copy-Item -LiteralPath $child.FullName -Destination $dest -Recurse -Force -ErrorAction Stop
  }

  & $git -C $worktree config user.name 'Army Attack CI'
  & $git -C $worktree config user.email 'actions@users.noreply.github.com'
  & $git -C $worktree add -- "Logs/android/$ExpectedSha/$RunId"
  if($LASTEXITCODE -ne 0){throw "LOG_PUBLISH=FAIL git_add exit=$LASTEXITCODE"}

  & $git -C $worktree diff --cached --quiet
  if($LASTEXITCODE -eq 0){
    Write-Host "LOG_PUBLISH=PASS no_changes branch=$EvidenceBranch path=Logs/android/$ExpectedSha/$RunId"
    exit 0
  }

  & $git -C $worktree commit -m "logs(android): $($ExpectedSha.Substring(0,12)) run $RunId [skip ci]"
  if($LASTEXITCODE -ne 0){throw "LOG_PUBLISH=FAIL git_commit exit=$LASTEXITCODE"}
  $evidenceCommit=(& $git -C $worktree rev-parse HEAD).Trim()

  $pushOk=$false
  for($attempt=1;$attempt -le 3;$attempt++){
    & $git -C $worktree push origin "HEAD:refs/heads/$EvidenceBranch"
    if($LASTEXITCODE -eq 0){$pushOk=$true;break}
    Start-Sleep -Seconds (2*$attempt)
    & $git -C $worktree fetch origin $EvidenceBranch
    if($LASTEXITCODE -eq 0){
      & $git -C $worktree rebase "origin/$EvidenceBranch"
      if($LASTEXITCODE -ne 0){& $git -C $worktree rebase --abort | Out-Null}
    }
  }
  if(-not $pushOk){throw 'LOG_PUBLISH=FAIL git_push retries_exhausted'}

  Write-Host "LOG_PUBLISH=PASS branch=$EvidenceBranch commit=$evidenceCommit path=Logs/android/$ExpectedSha/$RunId files=$($published.Count) stale=$stale"
  Write-Host "EVIDENCE_COMMIT_SHA=$evidenceCommit"
  Write-Host "EVIDENCE_PATH=Logs/android/$ExpectedSha/$RunId"
} finally {
  try{& $git -C $RepoCheckoutRoot worktree remove --force $worktree | Out-Null}catch{}
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
