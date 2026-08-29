# Mobile engine performance v1

The physical GPU test showed that AIR render mode was not the dominant bottleneck. This patch keeps the original v23.2 SWF visual/audio library and replaces only two ActionScript classes inside that SWF.

## Optimizations

- **Padded tilemap camera cache:** TileMapGraphic allocates a 256 px border around the viewport. Camera movement translates this cached bitmap exactly and triggers a raster rebuild only near the cache boundary or when gameplay invalidates the map.
- **No visual quality reduction:** terrain, transitions, fog, borders, clouds, coast and wave features remain enabled.
- **Dead collision work removed:** sortAll previously calculated hitTestObject/isInsideVisibleArea results without using them in any visibility decision.
- **Sort correctness bug fixed:** armySortObjects compared each object's previous index with the array length instead of the current sorted index, forcing false-positive display-list rebuilds.
- **Typed hot-loop indexes:** character and static-object lists avoid scanning every unrelated map element on every logic tick.
- **Enemy behavior preserved:** IsometricCharacter.update(), updateActions() and updateMovement() still run every game logic tick. EnemyInstallationObject.updateActions() also retains its original cadence.

## Packaging

Tools/CI/Patch-AndroidPerformanceSwf.ps1 uses FFDec to replace:
- game.battlefield.TileMapGraphic
- game.isometric.IsometricScene

It starts from the canonical v23.2 SWF SHA-256:
99a7e8c219610eabbe97aee74228d52ded1532b4c2d4310432d15082b2ff11c4

All Animate library/linkage assets remain inherited from that source SWF. The patched SWF gets a new SHA-256 and is validated as performance_patch_version=mobile-engine-v1.
