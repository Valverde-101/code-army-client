# Android mobile-engine-v3

## Root-cause correction
FFDec cannot parse the historical conditional-compile blocks in GameHUD/GameState directly. The Android binary patch therefore preserves those original compiled classes instead of recompiling them.

## Binary-patched classes
- TileMapGraphic
- IsometricScene
- Config
- MissionManager
- ArmyButton
- AnimationController
- EnvEffectManager

## Offline features
- The existing PvP HUD button cannot be hidden in offline mode.
- Offline PvP can be entered even while the old tutorial gate is active.
- The world-map button is enabled offline.
- Home and Desert are unlocked offline through the existing OfflineSave map-switch path.
- Pinch zoom selects GameState zoom levels directly and no longer depends on the HUD tutorial check.

## Performance
- Retains the padded tilemap camera cache, dirty sorting, offscreen display-list culling, persistent visible lookup and cached pointer cell.
- Caches the nested MovieClip used for left/right unit direction changes, removing repeated deep display-tree scans.
- Fixes cloud effects being inserted into the river/tile effect collection instead of their own collection.

Enemy AI cadence, combat cadence, pathfinding, projectiles and visible effect quality are intentionally unchanged.

Physical Android validation remains pending until the exact generated APK is manually tested.
