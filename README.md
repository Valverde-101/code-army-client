
# Army Attack: Surge of the Crimson Empire

Revival of a 2011 Facebook game by Digital Chocolate. This project is based on the Android version of the game, which was heavily modified in order to make it run offline.



## Gameplay behavior contract

This section is the functional contract for the current offline/mobile game. Changes to the systems below must preserve these invariants unless the contract is intentionally changed together with regression tests.

### Enemy AI and attack turns

Campaign enemies must react to nearby player combat targets without entering an unlimited attack loop.

For every enemy attack turn:

- **55%: 1 attack**
- **40%: 2 attacks**
- **5%: 3 attacks**

An enemy therefore always performs at least one attack when a valid player target is already in its attack range, but it must stop when its current attack budget is exhausted and return to the normal reaction timer. A nearby target must not bypass the turn timer repeatedly.

Valid priority targets include player units, player installations, and attackable player buildings. Enemy attacks are campaign logic and must not depend on the camera being pointed at the target.

Primary implementation:
- `src/game/characters/EnemyUnit.as`
- `src/game/actions/EnemyAttackingAction.as`
- `src/game/actions/RecapturePlayerBuildingAction.as`

Relevant telemetry:
- `ENEMY_ATTACK_TURN`
- `ENEMY_ATTACK_PRIORITY`

### Enemy movement and territorial pressure

Campaign enemies should tend to make progress toward player-controlled units, buildings, installations, and player territory. A movement candidate must improve distance to a valid target instead of repeatedly choosing an immediate A -> B -> A oscillation when a better forward step exists.

Movement uses a fallback path toward the player area when a direct target path cannot be found. Movement reservations must be released on success, abort, empty-path failure, and watchdog timeout so blocked destinations do not remain reserved forever.

Relevant telemetry includes:
- `ENEMY_MOVE_ABORT`
- `ENEMY_MOVE_PATH_FAIL`
- `ENEMY_MOVE_WATCHDOG`
- `ENEMY_MOVE_SYNC_SKIP`

### Campaign territorial capture

When a campaign enemy reaches a player-owned tile, ownership transfer is delegated to the native scene path:

`EnemyMovingAction -> IsometricScene.characterArrivedInCell() -> changeCellOwner()`

The movement source must **not** force `arrivalCell.mOwner = TILE_OWNER_ENEMY` directly. This keeps mission counters, map dirty state, ownership topology, and visual overlays synchronized through the canonical ownership path.

Old saves can contain an enemy standing on a tile that is still recorded as player-owned. Campaign enemies reconcile that stale state when their turn is processed.

Telemetry:
- `CAMPAIGN_TERRITORY_CAPTURE`
- reason `arrival`
- reason `turn_reconcile`

### PvP territorial invariant

**PvP territory is immutable during unit movement.**

Campaign capture behavior must not leak into `PvPEnemyMovingAction`. PvP movement must not call the campaign ownership-transfer path and must not force a tile owner change. PvP combat, map selection, powerups, and debrief behavior are independent from campaign territorial capture.

### Player unit repair lives and permanent loss

Offline campaign player units use:

`MAX_OFFLINE_REPAIRS = 3`

A destroyed unit can consume one repair life when it is revived. The counter is persisted as `repairs_used`. After all three repair lives have been consumed, a later destruction marks the unit for permanent removal instead of allowing unlimited revive cycles.

This rule applies to premium and non-premium campaign units. PvP is excluded.

Telemetry:
- `PLAYER_UNIT_REPAIR_LIFE`
- `PLAYER_UNIT_REPAIR_BLOCKED`
- `PLAYER_UNIT_PERMADEATH`

### Save compatibility

Current portable/offline save schema:

`armyattack-offline-save/v10`

Important persisted state includes:
- campaign maps and ownership
- player/enemy unit state
- `repairs_used`
- missions
- inventory/profile state
- daily reward state

Older saves are migrated forward instead of being discarded. Saves created before repair lives existed initialize missing `repairs_used` to zero because previous repair history cannot be reconstructed safely.

### Daily rewards

Offline daily rewards support a 360-day streak.

Rules:
- one claim per calendar day
- missing more than one day resets the streak
- after day 360 the sequence wraps to day 1
- claim state is persisted immediately
- original five-day reward definitions remain usable as the fallback reward cycle when an explicit day entry does not exist

### Campaign maps

The authored campaign map set is:
- `Home`
- `Desert`
- `Snow`

Map changes wait for required resources and tilemaps before committing the scene transition. Snow is a real campaign map and must not silently fall back to Home.

### PvP map contract

The currently authenticated/native PvP terrain is `pvp_map_1_4valleys_11x11`. Synthetic PvP terrain generation remains disabled unless a real authored map is recovered and integrated.

### Performance and enemy spatial budget

The offline campaign AI uses a **target active set: 24 enemies** for normal spatial activity. Enemies actively threatening the player or otherwise required for combat can remain active outside that ordinary budget.

Viewport activity is determined by the actual render viewport through `isRenderableActuallyInViewport()`; `isInsideVisibleArea()` represents unlocked-map area and must not be used as a camera-visibility predicate.

This distinction exists to prevent cases where a nominal target of 24 turns into every enemy on the map being fully active.

### Rendering and combat-effect lifetime

Gameplay completion must not wait indefinitely for animation labels. Missiles, artillery, explosions, hit effects, wrecking effects, and supply-airdrop visuals use bounded cleanup/watchdog paths so visual effects cannot remain permanently on screen.

Logical attack completion and visual cleanup are separate concerns.

### Mobile placement

Buying/placing a unit on mobile requires explicit placement confirmation. Releasing a map touch must not silently commit the unit before the confirmation/check action.

### Portable save sharing

The game can create a portable save/diagnostic payload and share it through the platform sharing flow. Imported external saves are validated before replacing internal state, and the previous internal save is backed up before mutation.

### Validation levels

Project status must distinguish:

- `IMPLEMENTED`
- `COMPILED`
- `APK_GENERATED`
- `INSTALLED`
- `LAUNCHED`
- `AUTOMATED_TESTED`
- `PHYSICALLY_VALIDATED`

`PHYSICALLY_VALIDATED` requires the exact APK for the exact TESTED_SHA to be installed and tested through ADB on a physical device with retained evidence. A green candidate build or a skipped physical workflow is not physical validation.


## Legal issues
This repository is made for educational purposes only, and will not be monetized in any way. Contact me for any legal problems, and I'll take appropriate action.

## How to play
This page is mostly meant for developers. As a player, you probably want to download the latest version on [our website](https://armyattack.me).

## How to build
Use Adobe Animate and the AIR SDK from HARMAN. Feel free to ask for help in our [Discord server](https://discord.gg/fySy92ChyY).
## License [![GPL v3](https://img.shields.io/badge/GPL%20v3-blue)](http://www.gnu.org/licenses/gpl-3.0)

```
Army Attack: Surge of the Crimson Empire.
Copyright (C) 2024 | Army Attack Development Team
See the GNU General Public License <https://www.gnu.org/licenses/>.
```
