# Android mobile-engine-v3.2-safe

## Incident addressed

Physical performance captures for TESTED_SHA `6b443375613279ac77edef087e65c552be74c7ad` showed severe runtime regression on a moto g06 / Android 15: roughly 1.2-1.6 vsync FPS, repeated 600-900 ms frames, rapid GC activity and user-observed menu re-entry / overlapping background music after pressing Play.

The v3/v3.1 patch had expanded FFDec class replacement beyond the rendering hot paths and recompiled global classes used across UI, configuration, animation and environment. A green build cannot prove those replacements are behaviorally equivalent to the canonical v23.2 bytecode.

## Safe patch boundary

v3.2-safe recompiles only:
- `game.battlefield.TileMapGraphic`
- `game.isometric.IsometricScene`

The following remain canonical v23.2 bytecode:
- `Config`
- `game.gui.button.ArmyButton`
- `game.characters.AnimationController`
- `game.environment.EnvEffectManager`
- GameHUD / GameState / MissionManager / WorldMapWindow and all other lifecycle classes

CI now rejects unexpected performance-patch classes and rejects a class-count mismatch.

## Performance retained

The safe set keeps the rendering/input optimizations already located in TileMapGraphic / IsometricScene:
- padded tilemap camera cache
- reduced tilemap rebuild churn
- dirty-driven sorting and membership checks
- cached pointer cell / throttled hover work
- offscreen viewport culling
- pinch zoom through the existing GameState zoom levels

Enemy AI, movement, combat, projectiles, visible assets and audio assets remain at their original cadence/content.

## Feature trade-off

The previous offline PvP visibility workaround depended on replacing ArmyButton globally. That replacement is intentionally removed from this recovery build because ArmyButton is shared by menu and in-game buttons. PvP must be reintroduced later through a narrower, lifecycle-safe hook after the core Play/menu/audio regression is physically cleared.

World-map behavior already present in canonical bytecode is preserved.

## Validation rule

COMPILED/APK_VALIDATED does not close this incident. The exact v3.2-safe APK must be installed and physically exercised. Required manual regression checks: cold launch, press Play once, verify no return-to-menu loop, verify only one music stream is perceived, pan/zoom, combat, background/foreground, restart, PERF capture, crash/ANR check.
