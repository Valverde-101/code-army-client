# Army Attack 23.2 editable workspace

This directory contains the **versioned, intentional editing layer** for Army Attack 23.2.

Generated or raw extraction output must never be committed here automatically. Raw SWF extraction lives under:

`.work/swf-extracted/23.2/`

## Promotion flow

`SWF base -> .work/swf-extracted/23.2 -> reviewed/normalized asset -> editable/armyattack-23.2 -> Git commit -> rebuild/validate`

## Logical areas

- `units/`: player units and their promoted assets/metadata.
- `enemies/`: enemy assets/metadata.
- `buildings/`: building assets/metadata.
- `effects/`: effects and animation resources.
- `terrain/`: terrain and map art.
- `ui/`: interface assets.
- `config/`: editable game/content configuration.
- `sounds/`: promoted sound assets.
- `manifest/`: asset mappings, hashes, pivots, frame/linkage metadata.

Only reviewed assets required to reproduce a modification belong in Git. Caches, previews, full RAW dumps, intermediate frames and build products stay in `.work/`.
