# Army Attack — Manual Android physical validation

This project intentionally does **not** use ADB for physical validation.

## Exact build identity

Before testing, record:

- Repository: `Valverde-101/code-army-client`
- PR: `#1`
- Branch: `chore/local-army-bootstrap-20260827`
- TESTED_SHA: use the SHA embedded in the APK build metadata / validation report.
- APK SHA-256: use the value from `apk-info.json` or `REPORT.md`.
- Render mode: `gpu`
- SWF must remain the canonical v23.2 SWF.

Do not reuse evidence from an older APK or SHA.

## Physical test procedure

1. Copy the exact generated APK to the Android phone and install it manually.
2. Launch Army Attack normally from Android.
3. Confirm the game reaches the playable main scene.
4. Open the **PERF** overlay.
5. Press **INICIAR**.
6. Play normally for at least one representative session, including movement, UI interaction and gameplay activity.
7. Whenever lag is clearly visible, press **MARCAR LAG**.
8. Continue playing after the marker so the profiler captures before/after behavior.
9. Press **DETENER**.
10. Press **ZIP** and share the generated diagnostic ZIP.
11. Record whether there was a crash, freeze, ANR-like hang, graphical corruption, input failure, audio problem or severe lag.

## Required result classification

Until the exact APK has been tested manually:

- INSTALL = `SKIPPED_WITH_REASON user_manual_install`
- START = `SKIPPED_WITH_REASON user_manual_launch`
- HEALTH = `SKIPPED_WITH_REASON user_manual_validation`
- SMOKE = `SKIPPED_WITH_REASON user_manual_validation`
- PHYSICAL_EVIDENCE = `SKIPPED_WITH_REASON awaiting_user_manual_zip`
- MANUAL_PHYSICAL_VALIDATION = `PENDING_USER_VALIDATION`

After the diagnostic ZIP and the user's physical observations are analyzed, the result can be upgraded to PASS/FAIL for that exact TESTED_SHA and APK SHA-256.

## Performance comparison

The previous direct-render baseline was approximately 5 FPS with frequent 200–500 ms frames. The next physical run must use the GPU-render APK and the low-overhead v2 profiler so the comparison remains attributable to the renderer change.
