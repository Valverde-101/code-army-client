param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot,
  [int]$PrNumber = 0,
  [switch]$MainPromotion
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$repoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
$root=(Resolve-Path -LiteralPath $AndroidBuildRoot).Path
if($ExpectedSha -notmatch '^[a-f0-9]{40}$'){throw "ARMY_PROJECT_SOURCE_EXPORT=FAIL invalid_sha=$ExpectedSha"}

Import-Module (Join-Path $root 'Core\Current\AndroidBuild.psd1') -DisableNameChecking -Force
$core=[version](Get-AndroidBuildCoreVersion)
if($core -lt [version]'3.0.9'){throw "ARMY_PROJECT_SOURCE_EXPORT=FAIL core=$core minimum=3.0.9"}
$git=Get-AndroidBuildGitPath $root
$head=(& $git -C $repoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $head -ne $ExpectedSha){throw "ARMY_PROJECT_SOURCE_EXPORT=FAIL exact_head expected=$ExpectedSha actual=$head"}

$configPath=Join-Path $repoRoot '.androidbuild.json'
if(-not(Test-Path -LiteralPath $configPath -PathType Leaf)){throw 'ARMY_PROJECT_SOURCE_EXPORT=FAIL config_missing'}
$config=Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json
if([string]$config.project.id -ne 'army-attack'){throw 'ARMY_PROJECT_SOURCE_EXPORT=FAIL project_identity'}

$projectRoot=Join-Path $root 'Project-Sources\ArmyAttack'
New-Item -ItemType Directory -Force -Path $projectRoot|Out-Null
$stage=Join-Path $projectRoot ('.publish.'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $stage|Out-Null
try {
  $sourcePath=Join-Path $stage 'armyattack-project-source-v1.md'
  $instructionsPath=Join-Path $stage 'armyattack-project-instructions-v1.txt'
  $metadataPath=Join-Path $stage 'metadata.json'
  $configCopy=Join-Path $stage '.androidbuild.json'

  $scriptInventory=@(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'Tools\CI') -Filter '*.ps1' -File -ErrorAction SilentlyContinue|Sort-Object Name|ForEach-Object{$_.Name})
  $swfInventory=@(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'Tools\SWF') -Filter '*.ps1' -File -ErrorAction SilentlyContinue|Sort-Object Name|ForEach-Object{$_.Name})
  $workflowInventory=@(Get-ChildItem -LiteralPath (Join-Path $repoRoot '.github\workflows') -Filter '*.yml' -File -ErrorAction SilentlyContinue|Sort-Object Name|ForEach-Object{$_.Name})

  $source=@"
# Army Attack Project Source v1

ARMYATTACK_PROJECT_SOURCE=1
ANDROIDBUILD_CORE_MINIMUM=3.0.9
ANDROIDBUILD_CONTEXT_MODE=PROJECT_SPECIFIC

## Exact identity

- Repository: `Valverde-101/code-army-client`
- Source SHA: `$ExpectedSha`
- Branch role: $(if($MainPromotion){'main / stable'}else{"PR candidate #$PrNumber"})
- Project ID: `army-attack`
- Package: `air.army.attack`
- Game version: `23.2`
- Candidate APK: `.work/artifacts/android/ArmyAttack.apk`
- Final owned APK name: `ArmyAttack-23.2.apk`

## AndroidBuild operating contract

- All source/config changes use branch + PR; never commit directly to `main`.
- Resolve repository, PR/branch and exact expected/actual SHA before source-changing or evidence-publishing operations.
- Follow `FAIL -> ROOT_CAUSE -> FIX -> REBUILD -> RETEST`.
- GitHub Actions green does not imply physical validation.
- Keep `TESTED_SHA` separate from `EVIDENCE_COMMIT_SHA`.
- PC-LAUNCHER restart/replacement requires explicit user approval.
- APK-FINAL publication requires physical validation PASS.
- Physical ADB is currently manual-only and intentionally not activated unless explicitly requested.

## Current architecture

Army Attack is fully migrated to AndroidBuild Core orchestration. Core owns reusable infrastructure; Army owns only game-specific behavior.

### Global AndroidBuild/Core ownership

- exact-head repository synchronization and persistent repository workspace;
- project build lease and cross-branch candidate serialization;
- build provenance and candidate validation;
- FFDec 26.2.1 provisioning;
- HARMAN AIR 50.2.3.6 provisioning;
- Temurin JDK 17 provisioning;
- pinned Android SDK API 33 / Build Tools 33.0.2;
- global evidence reduction, sanitization, manifest/hash and retention;
- broker/AutoRepo ownership;
- APK-FINAL gate.

### Army repository ownership

- published Army Attack v23.2 source/content contract;
- SWF patch classes and FFDec preprocessing;
- PvP/runtime/gameplay behavior and regression gates;
- embedded visual fallbacks and asset checks;
- diagnostics ANE and performance overlay;
- Army AIR descriptor/package semantics;
- Army-specific APK deep validation;
- manual gameplay/physical validation flows.

## Toolchain

- AndroidBuild Core: `3.0.9+`
- Java: `17`
- HARMAN AIR: `50.2.3.6`
- FFDec: `26.2.1`
- Android API: `33`
- Build Tools: `33.0.2`
- ABI: `arm64-v8a`
- Toolchain ownership: `androidbuild-global`

## Candidate pipeline

1. Classify latest candidate delta.
2. Serialize candidate build using project-wide concurrency/lease.
3. Bootstrap exact source SHA.
4. Parse/validate Army Core hooks.
5. Run Army project contract precheck.
6. Resolve global Flash/AIR toolchain from Core.
7. Validate published v23.2 source and upstream Android reference.
8. Execute Army regression suite and SWF core audit.
9. Patch SWF classes through global FFDec.
10. Build diagnostics ANE.
11. Package arm64 Android APK through HARMAN AIR.
12. Run Army deep APK validation: package, ABI, target SDK, SWF provenance, signature and zipalign.
13. Publish candidate only to repository `.work` ownership.
14. Recheck remote branch SHA.
15. Report `CANDIDATE_VALIDATION=PASS` only for exact SHA.

## Physical/evidence policy

- Physical workflow: `.github/workflows/android-physical.yml`.
- Activation: manual `workflow_dispatch` only.
- Current physical state: `NOT_ACTIVATED` unless explicitly requested.
- RAW evidence staging: `.work/evidence-staging`.
- Git evidence: `Logs/physical-adb`.
- Retention: newest 3 physical runs total across PASS/FAIL.
- Maximum 200 payload files/run, 25 MiB/run, 8 MiB/file, 8 screenshots.
- New evidence is published by AndroidBuild Core, not by a repository-owned publisher.

## Important repository hooks

- `.github/scripts/armyattack-project-precheck.ps1`
- `.github/scripts/armyattack-build.ps1`
- `Tools/CI/Build-Android.ps1`
- `Tools/CI/Validate-AndroidApk.ps1`
- `Tools/CI/Patch-AndroidPerformanceSwf.ps1`
- `Tools/CI/Build-AndroidDiagnosticsAne.ps1`
- `Tools/CI/Test-AndroidRuntimePatch.ps1`

## CI script inventory

$(($scriptInventory|ForEach-Object{"- `$_`"}) -join "`n")

## SWF tool inventory

$(($swfInventory|ForEach-Object{"- `$_`"}) -join "`n")

## Workflow inventory

$(($workflowInventory|ForEach-Object{"- `$_`"}) -join "`n")

## Current validation truth

The candidate/Core migration is expected to be validated on the exact SHA recorded above. Physical validation is deliberately separate. Never infer `PHYSICALLY_VALIDATED` from candidate success.
"@
  [IO.File]::WriteAllText($sourcePath,$source,(New-Object Text.UTF8Encoding($false)))

  $instructions=@"
ARMY ATTACK PROJECT INSTRUCTIONS v1

Repository: Valverde-101/code-army-client
Exact source SHA: $ExpectedSha
AndroidBuild Core minimum: 3.0.9

1. Use AndroidBuild Core for reusable infrastructure. Do not reintroduce repo-local ownership of FFDec, HARMAN AIR, JDK17, Android SDK provisioning, AutoRepo/broker management, evidence publication or APK-FINAL policy.
2. Keep Army-specific SWF/PvP/gameplay/ANE/APK deep-validation logic inside this repository.
3. All source/config changes require branch + PR; never commit directly to main.
4. Resolve repository, PR/branch, expected SHA and actual SHA before source-changing or evidence-publishing actions.
5. Follow FAIL -> ROOT_CAUSE -> FIX -> REBUILD -> RETEST.
6. GitHub Actions green is candidate validation, not physical validation.
7. Keep TESTED_SHA separate from EVIDENCE_COMMIT_SHA.
8. Do not restart or replace PC-LAUNCHER without explicit user approval.
9. Physical ADB is manual-only. If it is skipped, report PHYSICAL_VALIDATION=NOT_ACTIVATED and keep APK-FINAL deferred.
10. APK-FINAL owned filename is ArmyAttack-23.2.apk and may only be published after physical validation PASS.
11. Preserve the Army v23.2 published-source contract, FFDec SWF patch set, diagnostics ANE, PvP/runtime regressions and deep APK validation.
12. New physical evidence must use AndroidBuild Core reduction/sanitization/retention and keep only the newest 3 physical runs total in the current tree.
13. Use `.androidbuild.json` as the machine-readable project contract and the executable repository/Core state as the source of truth for current implementation.
"@
  [IO.File]::WriteAllText($instructionsPath,$instructions,(New-Object Text.UTF8Encoding($false)))

  Copy-Item -LiteralPath $configPath -Destination $configCopy -Force
  $sourceHash=(Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
  $instructionsHash=(Get-FileHash -LiteralPath $instructionsPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $configHash=(Get-FileHash -LiteralPath $configCopy -Algorithm SHA256).Hash.ToLowerInvariant()
  $metadata=[ordered]@{
    schema='armyattack-project-source/v1'
    repository='Valverde-101/code-army-client'
    project='ArmyAttack'
    project_id='army-attack'
    source_sha=$ExpectedSha
    source_role=$(if($MainPromotion){'current'}else{'candidate'})
    pr_number=$(if($PrNumber -gt 0){$PrNumber}else{$null})
    androidbuild_core=[string]$core
    generated_utc=[DateTime]::UtcNow.ToString('o')
    files=[ordered]@{
      'armyattack-project-source-v1.md'=$sourceHash
      'armyattack-project-instructions-v1.txt'=$instructionsHash
      '.androidbuild.json'=$configHash
    }
  }
  [IO.File]::WriteAllText($metadataPath,($metadata|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))

  foreach($f in @($sourcePath,$instructionsPath,$metadataPath,$configCopy)){
    if(-not(Test-Path -LiteralPath $f -PathType Leaf)){throw "ARMY_PROJECT_SOURCE_EXPORT=FAIL staged_file_missing=$f"}
  }

  if($MainPromotion){
    $target=Join-Path $projectRoot 'Current'
    $candidate=Join-Path $projectRoot ('.Current.candidate.'+[guid]::NewGuid().ToString('N'))
    Move-Item -LiteralPath $stage -Destination $candidate
    $stage=$null
    $backup=$null
    if(Test-Path -LiteralPath $target){
      $backup=Join-Path $projectRoot ('.Current.previous.'+[guid]::NewGuid().ToString('N'))
      Move-Item -LiteralPath $target -Destination $backup
    }
    Move-Item -LiteralPath $candidate -Destination $target
    if($backup -and (Test-Path -LiteralPath $backup)){Remove-Item -LiteralPath $backup -Recurse -Force}
    $published=$target
    Write-Host "ARMY_PROJECT_SOURCE_CURRENT=PASS path=$published sha=$ExpectedSha"
  } else {
    if($PrNumber -le 0){throw 'ARMY_PROJECT_SOURCE_EXPORT=FAIL pr_number_required_for_candidate'}
    $prRoot=Join-Path $projectRoot ("Candidates\PR-$PrNumber")
    New-Item -ItemType Directory -Force -Path $prRoot|Out-Null
    $target=Join-Path $prRoot $ExpectedSha
    if(Test-Path -LiteralPath $target){Remove-Item -LiteralPath $target -Recurse -Force}
    Move-Item -LiteralPath $stage -Destination $target
    $stage=$null
    $published=$target
    $candidates=@(Get-ChildItem -LiteralPath $prRoot -Directory -ErrorAction SilentlyContinue|Where-Object{$_.Name -match '^[a-f0-9]{40}$'}|Sort-Object LastWriteTimeUtc -Descending)
    foreach($old in @($candidates|Select-Object -Skip 3)){Remove-Item -LiteralPath $old.FullName -Recurse -Force}
    $remaining=@(Get-ChildItem -LiteralPath $prRoot -Directory -ErrorAction SilentlyContinue|Where-Object{$_.Name -match '^[a-f0-9]{40}$'}).Count
    if($remaining -gt 3){throw "ARMY_PROJECT_SOURCE_RETENTION=FAIL count=$remaining maximum=3"}
    Write-Host "ARMY_PROJECT_SOURCE_RETENTION=PASS count=$remaining maximum=3"
    Write-Host "ARMY_PROJECT_SOURCE_CANDIDATE=PASS path=$published pr=$PrNumber sha=$ExpectedSha"
  }

  $pubSource=Join-Path $published 'armyattack-project-source-v1.md'
  $pubInstructions=Join-Path $published 'armyattack-project-instructions-v1.txt'
  $pubMetadata=Join-Path $published 'metadata.json'
  $pubConfig=Join-Path $published '.androidbuild.json'
  $m=Get-Content -LiteralPath $pubMetadata -Raw|ConvertFrom-Json
  if([string]$m.source_sha -ne $ExpectedSha){throw 'ARMY_PROJECT_SOURCE_EXPORT=FAIL metadata_sha'}
  if((Get-FileHash $pubSource -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$m.files.'armyattack-project-source-v1.md'){throw 'ARMY_PROJECT_SOURCE_EXPORT=FAIL source_hash'}
  if((Get-FileHash $pubInstructions -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$m.files.'armyattack-project-instructions-v1.txt'){throw 'ARMY_PROJECT_SOURCE_EXPORT=FAIL instructions_hash'}
  if((Get-FileHash $pubConfig -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$m.files.'.androidbuild.json'){throw 'ARMY_PROJECT_SOURCE_EXPORT=FAIL config_hash'}
  Write-Host "ARMY_PROJECT_SOURCE_IDENTITY=PASS repository=Valverde-101/code-army-client sha=$ExpectedSha core=$core"
  Write-Host "ARMY_PROJECT_SOURCE_FILE=PASS name=armyattack-project-source-v1.md sha256=$($m.files.'armyattack-project-source-v1.md')"
  Write-Host "ARMY_PROJECT_SOURCE_FILE=PASS name=armyattack-project-instructions-v1.txt sha256=$($m.files.'armyattack-project-instructions-v1.txt')"
  Write-Host "ARMY_PROJECT_SOURCE_FILE=PASS name=metadata.json"
  Write-Host "ARMY_PROJECT_SOURCE_FILE=PASS name=.androidbuild.json sha256=$($m.files.'.androidbuild.json')"
  Write-Host "ARMY_PROJECT_SOURCE_EXPORT=PASS path=$published source_sha=$ExpectedSha role=$($m.source_role)"
} finally {
  if($stage -and (Test-Path -LiteralPath $stage)){Remove-Item -LiteralPath $stage -Recurse -Force}
}
