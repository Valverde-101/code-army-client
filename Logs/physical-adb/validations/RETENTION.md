# Android physical validation retention

Policy for `Logs/physical-adb/validations/`:

- Keep the validation directory for the current `TESTED_SHA`.
- Keep the three most recent previous validation SHA directories.
- Maximum retained SHA directories: 4.
- Rank previous SHAs by the newest UTC timestamp directory they contain.
- Never prune `Logs/physical-adb/failures/` with this policy.
- `Tools/CI/Publish-AndroidEvidence.ps1` enforces the policy before committing evidence and stages both additions and deletions.
