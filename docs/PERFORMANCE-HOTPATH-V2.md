# Android performance hot-path v2

- Cache getTileUnderMouse() until pointer, camera or zoom changes.
- Throttle expensive hover/highlight searches to 200 ms, with immediate refresh when the cell changes or a touch/drag is active.
- Combat, enemy AI, movement, projectiles and static-object logic remain at their original cadence.
- FFDec wrapper now distinguishes native stderr diagnostics from process failure by evaluating LASTEXITCODE.
- CI preserves individual FFDec logs for all feature-patched classes.

This change builds on offscreen viewport culling already present in the parent source commit.
