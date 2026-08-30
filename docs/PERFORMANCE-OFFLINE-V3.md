# Android mobile-engine-v3.1

## Root-cause correction

The canonical v23.2 SWF is still used as the asset/linkage source.

Large historical classes that contain legacy conditional-compilation syntax are deliberately preserved as their original compiled bytecode:
- GameHUD
- GameState
- MissionManager
- WorldMapWindow

They are not recompiled by FFDec.

## Recompiled classes

Only these FFDec-parseable classes are replaced:
- TileMapGraphic
- IsometricScene
- Config
- ArmyButton
- AnimationController
- EnvEffectManager

## Offline behavior

The existing GameHUD and WorldMapWindow bytecode already contains explicit offline paths for the map button and Home/Desert availability. No MissionManager replacement is required.

ArmyButton only supplies the PvP tutorial-gate fallback while preserving the original GameHUD handler.

Pinch zoom selects the existing GameState zoom levels directly, avoiding the old tutorial-dependent HUD zoom path.

## Performance

Retains:
- padded tilemap camera cache
- dirty-driven depth sorting
- offscreen display-list culling
- cached pointer-cell and throttled hover UI
- cached animation flip target
- corrected environment-cloud collection

Enemy AI, combat, pathfinding, projectile cadence, fog and visual effects are not intentionally reduced.
