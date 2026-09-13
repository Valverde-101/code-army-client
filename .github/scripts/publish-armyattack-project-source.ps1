param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot,
  [int]$PrNumber=0,
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
$role=if($MainPromotion){'main / stable'}else{"PR candidate #$PrNumber"}
$sourceRole=if($MainPromotion){'current'}else{'candidate'}
$scriptLines=(@(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'Tools\CI') -Filter '*.ps1' -File -ErrorAction SilentlyContinue|Sort-Object Name|ForEach-Object{'- '+$_.Name})) -join [Environment]::NewLine
$swfLines=(@(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'Tools\SWF') -Filter '*.ps1' -File -ErrorAction SilentlyContinue|Sort-Object Name|ForEach-Object{'- '+$_.Name})) -join [Environment]::NewLine
$workflowLines=(@(Get-ChildItem -LiteralPath (Join-Path $repoRoot '.github\workflows') -Filter '*.yml' -File -ErrorAction SilentlyContinue|Sort-Object Name|ForEach-Object{'- '+$_.Name})) -join [Environment]::NewLine

$projectRoot=Join-Path $root 'Project-Sources\ArmyAttack'
New-Item -ItemType Directory -Force -Path $projectRoot|Out-Null
$stage=Join-Path $projectRoot ('.publish.'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $stage|Out-Null
try{
  $sourcePath=Join-Path $stage 'armyattack-project-source-v1.md'
  $instructionsPath=Join-Path $stage 'armyattack-project-instructions-v1.txt'
  $metadataPath=Join-Path $stage 'metadata.json'
  $configCopy=Join-Path $stage '.androidbuild.json'

  $source=@"
# Army Attack Project Source v1

ARMYATTACK_PROJECT_SOURCE=1
ANDROIDBUILD_CORE_MINIMUM=3.0.9
ANDROIDBUILD_CONTEXT_MODE=PROJECT_SPECIFIC

## Exact identity

Repository: Valverde-101/code-army-client
Source SHA: $ExpectedSha
Branch role: $role
Project ID: army-attack
Package: air.army.attack
Game version: 23.2
Candidate APK: .work/artifacts/android/ArmyAttack.apk
Final owned APK name: ArmyAttack-23.2.apk

## Workspace ownership

All Army-specific runtime state is repository-owned under .work:
- builds: .work/build, newest 3 tested SHA generations maximum;
- reusable upstream inputs: .work/cache/inputs, reused by version + SHA256 rather than copied per build;
- scratch: .work/scratch, ephemeral and cleared per build;
- compatibility runtime: .work/runtime/AndroidBuild;
- candidate artifacts: .work/artifacts.

V:\AndroidBuild\Builds\code-army-client, V:\AndroidBuild\Inputs\code-army-client and Army-owned entries under V:\AndroidBuild\Scratch are legacy and must not be used by current builds. Global reusable tools remain outside .work: Core, FFDec, HARMAN AIR, JDK, pinned Android SDK, broker, Project-Sources and APK-FINAL.

## Operating contract

- All source/config changes use branch + PR; never commit directly to main.
- Resolve repository, PR/branch and exact expected/actual SHA before source-changing or evidence-publishing operations.
- Follow FAIL -> ROOT_CAUSE -> FIX -> REBUILD -> RETEST.
- GitHub Actions green does not imply physical validation.
- Keep TESTED_SHA separate from EVIDENCE_COMMIT_SHA.
- PC-LAUNCHER restart/replacement requires explicit user approval.
- APK-FINAL publication requires physical validation PASS.
- Physical ADB is manual-only and currently not activated unless explicitly requested.

## Global AndroidBuild/Core ownership

- exact-head repository synchronization and project build lease;
- build provenance and generic APK candidate validation;
- FFDec 26.2.1, HARMAN AIR 50.2.3.6, Temurin JDK 17;
- pinned Android SDK API 33 / Build Tools 33.0.2;
- broker/AutoRepo ownership;
- evidence reduction, sanitization, manifest/hash and retention;
- APK-FINAL gate.

## Army repository ownership

- Army Attack v23.2 published-source contract;
- SWF patch classes and FFDec preprocessing;
- PvP/runtime/gameplay regression gates and embedded visual fallbacks;
- diagnostics ANE and performance overlay;
- AIR descriptor/package semantics;
- Army-specific deep APK validation;
- manual gameplay/physical validation flows.

## Candidate pipeline

1. Classify latest HEAD delta and serialize by Army project lease.
2. Bootstrap exact source SHA and synchronize the persistent repository through Core.
3. Resolve the global Flash/AIR toolchain.
4. Initialize repo-local .work runtime facade and migrate/retire Army state outside .work.
5. Reuse verified upstream inputs from .work/cache/inputs.
6. Execute Army regression suite and SWF core audit.
7. Patch SWF through global FFDec; build diagnostics ANE; package arm64 APK through HARMAN AIR.
8. Validate package, ABI, target SDK, SWF provenance, signature and zipalign.
9. Retain only newest 3 build SHA generations under .work/build.
10. Publish candidate only to .work/artifacts and recheck remote exact HEAD.

## Physical/evidence policy

Physical workflow: .github/workflows/android-physical.yml
Activation: manual workflow_dispatch only
Current physical state: NOT_ACTIVATED unless explicitly requested
RAW evidence staging: .work/evidence-staging
Git evidence: Logs/physical-adb
Evidence retention: newest 3 physical runs total across PASS/FAIL
Limits: 200 payload files/run, 25 MiB/run, 8 MiB/file, 8 screenshots

## CI script inventory

$scriptLines

## SWF tool inventory

$swfLines

## Workflow inventory

$workflowLines

## Current validation truth

Candidate/Core success is separate from physical validation. Never infer PHYSICALLY_VALIDATED from candidate success.
"@
  [IO.File]::WriteAllText($sourcePath,$source,(New-Object Text.UTF8Encoding($false)))

  $instructions=@"
ARMY ATTACK PROJECT INSTRUCTIONS v1

Repository: Valverde-101/code-army-client
Exact source SHA: $ExpectedSha
AndroidBuild Core minimum: 3.0.9

1. Use AndroidBuild Core for reusable infrastructure; do not reintroduce repo-local copies of FFDec, HARMAN AIR, JDK17, Android SDK provisioning, broker management, evidence publication or APK-FINAL policy.
2. Keep Army-specific SWF/PvP/gameplay/ANE/APK validation logic in this repository.
3. All Army-specific runtime state belongs under .work. Canonical roots are .work/build, .work/cache/inputs, .work/scratch, .work/runtime/AndroidBuild and .work/artifacts.
4. Build outputs retain at most 3 tested SHA generations. Immutable upstream inputs are cached once by version and SHA256; do not duplicate them per generation. Scratch is ephemeral.
5. V:\AndroidBuild\Builds\code-army-client, V:\AndroidBuild\Inputs\code-army-client and Army-owned global Scratch entries are retired paths.
6. All source/config changes require branch + PR; never commit directly to main.
7. Resolve repo, PR/branch, expected SHA and actual SHA before source-changing or evidence-publishing operations.
8. Follow FAIL -> ROOT_CAUSE -> FIX -> REBUILD -> RETEST.
9. GitHub Actions green is candidate validation, not physical validation. Keep TESTED_SHA separate from EVIDENCE_COMMIT_SHA.
10. Do not restart or replace PC-LAUNCHER without explicit user approval.
11. Physical ADB is manual-only; when skipped report PHYSICAL_VALIDATION=NOT_ACTIVATED and keep APK-FINAL deferred.
12. APK-FINAL owned filename is ArmyAttack-23.2.apk and may only be published after physical validation PASS.
13. New physical evidence uses AndroidBuild Core reduction/sanitization/retention and keeps only the newest 3 physical runs total.
14. Use .androidbuild.json plus executable repo/Core state as the machine-readable source of truth.
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
    source_role=$sourceRole
    pr_number=$(if($PrNumber -gt 0){$PrNumber}else{$null})
    androidbuild_core=[string]$core
    workspace=[ordered]@{build='.work/build';input_cache='.work/cache/inputs';scratch='.work/scratch';runtime='.work/runtime/AndroidBuild';artifacts='.work/artifacts';build_retention_generations=3}
    generated_utc=[DateTime]::UtcNow.ToString('o')
    files=[ordered]@{
      'armyattack-project-source-v1.md'=$sourceHash
      'armyattack-project-instructions-v1.txt'=$instructionsHash
      '.androidbuild.json'=$configHash
    }
  }
  [IO.File]::WriteAllText($metadataPath,($metadata|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))

  if($MainPromotion){
    $target=Join-Path $projectRoot 'Current'
    $candidate=Join-Path $projectRoot ('.Current.candidate.'+[guid]::NewGuid().ToString('N'))
    Move-Item -LiteralPath $stage -Destination $candidate
    $stage=$null
    $backup=$null
    if(Test-Path -LiteralPath $target){$backup=Join-Path $projectRoot ('.Current.previous.'+[guid]::NewGuid().ToString('N'));Move-Item -LiteralPath $target -Destination $backup}
    Move-Item -LiteralPath $candidate -Destination $target
    if($backup -and (Test-Path -LiteralPath $backup)){Remove-Item -LiteralPath $backup -Recurse -Force}
    $published=$target
    Write-Host "ARMY_PROJECT_SOURCE_CURRENT=PASS path=$published sha=$ExpectedSha"
  }else{
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
  foreach($file in @($pubSource,$pubInstructions,$pubMetadata,$pubConfig)){if(-not(Test-Path -LiteralPath $file -PathType Leaf)){throw "ARMY_PROJECT_SOURCE_EXPORT=FAIL published_file_missing=$file"}}
  $m=Get-Content -LiteralPath $pubMetadata -Raw|ConvertFrom-Json
  if([string]$m.source_sha -ne $ExpectedSha){throw 'ARMY_PROJECT_SOURCE_EXPORT=FAIL metadata_sha'}
  if((Get-FileHash $pubSource -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$m.files.'armyattack-project-source-v1.md'){throw 'ARMY_PROJECT_SOURCE_EXPORT=FAIL source_hash'}
  if((Get-FileHash $pubInstructions -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$m.files.'armyattack-project-instructions-v1.txt'){throw 'ARMY_PROJECT_SOURCE_EXPORT=FAIL instructions_hash'}
  if((Get-FileHash $pubConfig -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$m.files.'.androidbuild.json'){throw 'ARMY_PROJECT_SOURCE_EXPORT=FAIL config_hash'}
  Write-Host "ARMY_PROJECT_SOURCE_IDENTITY=PASS repository=Valverde-101/code-army-client sha=$ExpectedSha core=$core"
  Write-Host "ARMY_PROJECT_SOURCE_FILE=PASS name=armyattack-project-source-v1.md sha256=$($m.files.'armyattack-project-source-v1.md')"
  Write-Host "ARMY_PROJECT_SOURCE_FILE=PASS name=armyattack-project-instructions-v1.txt sha256=$($m.files.'armyattack-project-instructions-v1.txt')"
  Write-Host 'ARMY_PROJECT_SOURCE_FILE=PASS name=metadata.json'
  Write-Host "ARMY_PROJECT_SOURCE_FILE=PASS name=.androidbuild.json sha256=$($m.files.'.androidbuild.json')"
  Write-Host "ARMY_PROJECT_SOURCE_EXPORT=PASS path=$published source_sha=$ExpectedSha role=$sourceRole"
}finally{
  if($stage -and (Test-Path -LiteralPath $stage)){Remove-Item -LiteralPath $stage -Recurse -Force}
}
