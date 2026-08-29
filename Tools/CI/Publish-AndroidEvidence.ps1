param(
  [Parameter(Mandatory=$true)][string]$RepoCheckoutRoot,
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$RunId,
  [Parameter(Mandatory=$true)][string]$SourceBranch
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$repoName='Valverde-101/code-army-client'
$buildRoot=Join-Path $AndroidBuildRoot "Builds\code-army-client\$ExpectedSha"
$androidRoot=Join-Path $buildRoot 'android'
$referenceRoot=Join-Path $buildRoot 'android-upstream-v21.1'
if(-not (Test-Path -LiteralPath $RepoCheckoutRoot)){throw "LOG_PUBLISH=FAIL checkout_missing=$RepoCheckoutRoot"}
if(-not (Test-Path -LiteralPath $buildRoot)){throw "LOG_PUBLISH=FAIL build_root_missing=$buildRoot"}

$gitCandidates=@()
$gitCommand=Get-Command git.exe -ErrorAction SilentlyContinue
if($gitCommand){$gitCandidates+=$gitCommand.Source}
$gitCandidates+=@(
  (Join-Path $AndroidBuildRoot 'Tools\Git\cmd\git.exe'),
  (Join-Path $AndroidBuildRoot 'PortableGit\cmd\git.exe')
)
$git=$gitCandidates|Where-Object{$_ -and (Test-Path -LiteralPath $_)}|Select-Object -First 1
if(-not $git){throw 'LOG_PUBLISH=FAIL git_not_found'}
Write-Host "EVIDENCE_GIT=PASS path=$git"
$gitDir=Join-Path $RepoCheckoutRoot '.git'
if(-not (Test-Path -LiteralPath $gitDir)){
  throw "EVIDENCE_GIT_REPO=FAIL checkout_has_no_dotgit root=$RepoCheckoutRoot"
}
$checkoutHeadLines=@(& $git -C $RepoCheckoutRoot rev-parse HEAD 2>&1|ForEach-Object{$_.ToString()})
$checkoutHeadExit=$LASTEXITCODE
if($checkoutHeadExit -ne 0){
  $checkoutHeadLines|ForEach-Object{Write-Host $_}
  throw "EVIDENCE_GIT_REPO=FAIL rev_parse_exit=$checkoutHeadExit"
}
$checkoutHead=($checkoutHeadLines|Select-Object -Last 1).Trim()
if($checkoutHead -ne $ExpectedSha){
  throw "LOG_PUBLISH=FAIL checkout_sha expected=$ExpectedSha actual=$checkoutHead"
}
Write-Host "EVIDENCE_GIT_REPO=PASS sha=$checkoutHead"

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

# Publish only diagnostic evidence. Never recurse the whole Android build tree:
# stage/, v23/, candidate/, performance exports and game assets are build inputs/outputs,
# not validation evidence and must not be committed under Logs/**.
$androidRootEvidence=@(
  'adt-android.out.log',
  'adt-android.err.log',
  'ArmyAttack-android-app.xml',
  'BUILD-PROVENANCE.json',
  'TOOLCHAIN.json',
  'PERFORMANCE-PATCH.json',
  'apk-badging.txt',
  'apk-permissions.txt',
  'apk-signature.txt',
  'apk-info.json',
  'summary.json',
  'REPORT.md'
)
foreach($name in $androidRootEvidence){
  Copy-EvidenceFile (Join-Path $androidRoot $name) (Join-Path 'android' $name)
}

foreach($dirName in @('diagnostics','physical')){
  $dir=Join-Path $androidRoot $dirName
  if(Test-Path -LiteralPath $dir){
    foreach($file in @(Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue)){
      $relative=$file.FullName.Substring($dir.Length).TrimStart('\','/')
      Copy-EvidenceFile $file.FullName (Join-Path (Join-Path 'android' $dirName) $relative)
    }
  }
}

# FFDec patch logs are valuable on failures, but exported/decompiled payloads are not.
$perfLogRoot=Join-Path $androidRoot 'performance\performance-patch-work'
if(Test-Path -LiteralPath $perfLogRoot){
  foreach($file in @(Get-ChildItem -LiteralPath $perfLogRoot -Recurse -File -Filter '*.log' -ErrorAction SilentlyContinue)){
    $relative=$file.FullName.Substring($perfLogRoot.Length).TrimStart('\','/')
    Copy-EvidenceFile $file.FullName (Join-Path 'android\performance-patch-work' $relative)
  }
}

foreach($name in @('aapt-badging.txt','reference.json')){
  Copy-EvidenceFile (Join-Path $referenceRoot $name) (Join-Path 'reference-v21.1' $name)
}

$forbiddenEvidencePrefixes=@(
  'android/stage/',
  'android/v23/',
  'android/candidate/',
  'android/performance/'
)
foreach($entry in @($published.ToArray())){
  $normalized=[string]$entry.path
  foreach($prefix in $forbiddenEvidencePrefixes){
    if($normalized.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){
      throw "LOG_PUBLISH=FAIL build_payload_staged path=$normalized"
    }
  }
}
$maxPublishedFiles=250
if($published.Count -gt $maxPublishedFiles){throw "LOG_PUBLISH=FAIL evidence_file_count count=$($published.Count) max=$maxPublishedFiles"}
$totalEvidenceBytes=[int64](($published|Measure-Object -Property bytes -Sum).Sum)
$maxEvidenceBytes=25MB
if($totalEvidenceBytes -gt $maxEvidenceBytes){throw "LOG_PUBLISH=FAIL evidence_bytes bytes=$totalEvidenceBytes max=$maxEvidenceBytes"}
Write-Host "EVIDENCE_SCOPE=PASS files=$($published.Count) bytes=$totalEvidenceBytes max_files=$maxPublishedFiles max_bytes=$maxEvidenceBytes"

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
  evidence_branch=$SourceBranch
  published_files=@($published.ToArray())
  skipped_files=@($skipped.ToArray())
}
$manifestPath=Join-Path $stage 'manifest.json'
try{
  $manifestJson=$manifest|ConvertTo-Json -Depth 8
  [void]($manifestJson|ConvertFrom-Json)
  $manifestJson|Set-Content -LiteralPath $manifestPath -Encoding UTF8
  Write-Host "LOG_MANIFEST=PASS published=$($published.Count) skipped=$($skipped.Count)"
}catch{
  throw "LOG_PUBLISH=FAIL manifest_serialization $($_.Exception.GetType().FullName): $($_.Exception.Message)"
}

# Final secret/forbidden scan of staged text.
foreach($file in @(Get-ChildItem -LiteralPath $stage -Recurse -File | Where-Object {$allowedText -contains $_.Extension.ToLowerInvariant()})){
  $text=Get-Content -LiteralPath $file.FullName -Raw
  if($text -match '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'){throw "LOG_PUBLISH=FAIL private_key_marker=$($file.FullName)"}
  if($text -match '\bgh[pousr]_[A-Za-z0-9_]{20,}\b'){throw "LOG_PUBLISH=FAIL github_token_marker=$($file.FullName)"}
}
Write-Host "SANITIZATION=PASS files=$($published.Count)"

try{
  # Evidence MUST belong to the exact source HEAD tested.
  & $git -C $RepoCheckoutRoot fetch origin $SourceBranch
  if($LASTEXITCODE -ne 0){throw "EVIDENCE_UPLOAD=FAIL fetch_source_branch exit=$LASTEXITCODE"}
  $remoteSourceSha=(& $git -C $RepoCheckoutRoot rev-parse "origin/$SourceBranch").Trim()
  if($remoteSourceSha -ne $ExpectedSha){
    throw "STALE_TEST_RESULT expected=$ExpectedSha remote_head=$remoteSourceSha branch=$SourceBranch"
  }
  Write-Host "EVIDENCE_REMOTE_HEAD=PASS sha=$remoteSourceSha branch=$SourceBranch"

  & $git -C $RepoCheckoutRoot checkout -B $SourceBranch $ExpectedSha
  if($LASTEXITCODE -ne 0){throw "EVIDENCE_UPLOAD=FAIL checkout_source_branch exit=$LASTEXITCODE"}

  $timestamp=(Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
  $relativeDest="Logs/physical-adb/validations/$ExpectedSha/$timestamp"
  $dest=Join-Path $RepoCheckoutRoot ($relativeDest.Replace('/','\'))
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  foreach($child in @(Get-ChildItem -LiteralPath $stage -Force)){
    Copy-Item -LiteralPath $child.FullName -Destination $dest -Recurse -Force -ErrorAction Stop
  }

  & $git -C $RepoCheckoutRoot config user.name 'Army Attack CI'
  & $git -C $RepoCheckoutRoot config user.email 'actions@users.noreply.github.com'
  & $git -C $RepoCheckoutRoot add -- $relativeDest
  if($LASTEXITCODE -ne 0){throw "EVIDENCE_UPLOAD=FAIL git_add exit=$LASTEXITCODE"}

  & $git -C $RepoCheckoutRoot diff --cached --quiet
  if($LASTEXITCODE -eq 0){
    Write-Host "EVIDENCE_UPLOAD=PASS no_changes path=$relativeDest"
    Write-Host "LOG_PUBLISH=PASS no_changes branch=$SourceBranch path=$relativeDest"
    exit 0
  }

  & $git -C $RepoCheckoutRoot commit -m "logs(android): $($ExpectedSha.Substring(0,12)) run $RunId"
  if($LASTEXITCODE -ne 0){throw "EVIDENCE_UPLOAD=FAIL git_commit exit=$LASTEXITCODE"}
  $evidenceCommit=(& $git -C $RepoCheckoutRoot rev-parse HEAD).Trim()

  # Never rebase or force-push evidence. If branch moved, fail stale.
  $remoteBeforePush=(& $git -C $RepoCheckoutRoot ls-remote origin "refs/heads/$SourceBranch" | Out-String).Trim()
  $remoteBeforePushSha=''
  if($remoteBeforePush){$remoteBeforePushSha=($remoteBeforePush -split '\s+')[0]}
  if($remoteBeforePushSha -ne $ExpectedSha){
    throw "STALE_TEST_RESULT expected=$ExpectedSha remote_head=$remoteBeforePushSha before_evidence_push=true"
  }

  & $git -C $RepoCheckoutRoot push origin "HEAD:refs/heads/$SourceBranch"
  if($LASTEXITCODE -ne 0){throw "EVIDENCE_PUSH_CONFLICT branch=$SourceBranch commit=$evidenceCommit"}

  Write-Host "EVIDENCE_UPLOAD=PASS branch=$SourceBranch commit=$evidenceCommit path=$relativeDest files=$($published.Count)"
  Write-Host "LOG_PUBLISH=PASS branch=$SourceBranch commit=$evidenceCommit path=$relativeDest files=$($published.Count) stale=false"
  Write-Host "EVIDENCE_COMMIT_SHA=$evidenceCommit"
  Write-Host "EVIDENCE_PATH=$relativeDest"
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
