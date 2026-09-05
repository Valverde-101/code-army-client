# Android physical evidence retention

AndroidBuild Core 3.0.9 is the single authority for physical-evidence publication and retention.

- RAW/heavy evidence is created first under `.work/evidence-staging`.
- `Publish-AndroidBuildEvidence` reduces, sanitizes, checks policy, writes `manifest.json`, and publishes only bounded evidence under `Logs/physical-adb/`.
- At most **3 physical runs total** are retained globally across `validations/` and `failures/`, ranked by run timestamp. PASS and FAIL do not have independent retention pools.
- Maximum payload per retained run: **200 files**, **25 MiB total**, **8 MiB per file**, and **8 screenshots** for Army Attack.
- APK/AAB/APKS/ZIP/7Z/IMG/ISO/SO/DEX/VDEX/ODEX/OAT/BIN payloads are not evidence and must not be committed.
- Evidence text is sanitized before commit; committed files are hashed in the evidence manifest.
- `TESTED_SHA` identifies the source that was physically tested. `EVIDENCE_COMMIT_SHA` is a later same-PR evidence-only commit and must remain distinct.
- Candidate workflows ignore `Logs/**`, so an evidence-only commit does not manufacture a new candidate/tested SHA.
- GitHub `paths: Logs/**` is only a wake-up filter: a commit that changes both source and `Logs/**` also triggers the verifier. The workflow therefore classifies commits as `EVIDENCE_ONLY` or `MIXED_SOURCE_AND_EVIDENCE`; mixed commits still validate the stored evidence policy but are not falsely required to contain only evidence paths.
- Legacy `schema_version: 1` manifests were produced on Windows before Git applied `* text=auto` LF normalization. For retained legacy text only, the verifier accepts the file if either the checked-out bytes or a deterministic LF→CRLF reconstruction reproduces the manifest's original byte count and SHA-256 exactly. New Core `androidbuild-evidence/v1` evidence remains byte-for-byte strict with no normalization fallback.
- APK-FINAL publication is allowed only after a real physical PASS and successful evidence publication/commit.

Historical evidence produced before the Core migration may retain the legacy `schema_version: 1` manifest until it ages out under the same global three-run policy. All newly published evidence must use the Core `androidbuild-evidence/v1` manifest.
