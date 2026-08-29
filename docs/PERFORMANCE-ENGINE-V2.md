# Mobile engine performance v2

This is the second behavior-preserving Android performance pass. It extends mobile-engine-v1 without reducing visual quality, enemy AI frequency, movement frequency, pathfinding semantics, combat timing, fog logic, audio, or effects.

## Rendering

- GPU render mode remains enabled.
- TileMapGraphic keeps a 256 px padded cache around the viewport.
- Camera movement translates the cached terrain/fog bitmap exactly.
- Full terrain rasterization happens only when the cache approaches its boundary or gameplay explicitly invalidates the map.
- Terrain, fog, transitions, borders, clouds, coast, waves, sprites and audio remain enabled.

## Scene update hot paths

- Characters and static objects have separate indexed arrays, avoiding repeated type filtering over every map element.
- Enemy and player characters still execute update(), updateActions(), and updateMovement() every logic tick.
- Enemy and player installations retain their original updateActions() cadence.

## Sorting

- The unused per-object hitTestObject/isInsideVisibleArea work is removed from sortAll.
- The old mSortIdx comparison bug is fixed.
- Camera panning no longer forces a global membership scan because panning does not alter object membership.
- armySortObjects now records each renderable's last X/Y and skips Array.sort entirely when no position or structural change occurred.
- New/removed/moved objects mark sorting dirty, so real order changes still sort normally.

## Input

- The tile already calculated under the pointer is reused when updating activated-unit direction instead of recalculating local/global transforms a second time.

## SWF packaging

Only game.battlefield.TileMapGraphic and game.isometric.IsometricScene are recompiled into the canonical v23.2 SWF with FFDec. Animate library symbols, graphics, sounds and linkage remain inherited from the original SWF.

Patch contract: performance_patch_version=mobile-engine-v2.
