# Army Attack Project Source Publisher

This publisher generates the project-specific ChatGPT context bundle for Army Attack under the AndroidBuild host:

- PR candidates: `V:\AndroidBuild\Project-Sources\ArmyAttack\Candidates\PR-<n>\<sha>`
- Stable main: `V:\AndroidBuild\Project-Sources\ArmyAttack\Current`

Published files:

- `armyattack-project-source-v1.md`
- `armyattack-project-instructions-v1.txt`
- `metadata.json`
- `.androidbuild.json`

Candidate retention is limited to the newest three SHA directories per PR. Stable `Current` is promoted transactionally from a staged directory.
