# CI Logs

This branch stores sanitized diagnostics produced by the self-hosted runners.

Layout:

- `logs/android/<TESTED_SHA>/`
- `logs/windows/<TESTED_SHA>/` (when enabled)

Rules:
- Every directory is tied to one exact source SHA and run ID.
- APKs, certificates, private keys, tokens, credentials, build stages and large binary assets are not committed here.
- Text logs are sanitized and size-capped before push.
- This branch is intentionally separate from the development PR branch so log publication never changes the tested source SHA.
