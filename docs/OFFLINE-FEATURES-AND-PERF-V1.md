# Android offline features + performance v1

Source parent: 344dc1bec24f53c63715d8af173ef291c8e1eee7

## Performance
- Keeps the existing tilemap camera cache and dirty-sort work.
- Adds actual screen-space culling for non-ground renderables with a 384 px safety margin.
- Offscreen objects are removed from the display list while their game/AI logic continues to run.
- Viewport membership refreshes every 5 frames and whenever the camera or zoom changes.
- Uses a persistent Dictionary for visible membership to avoid allocating/rebuilding one on every scan.
- Sorting is triggered immediately when viewport membership changes.

## Offline features
- Android pinch zoom explicitly enables AIR gesture mode and no longer self-disables on short stages.
- PvP HUD button is restored.
- Offline PvP bootstraps local opponent/unit data and skips the dead original server call at debrief.
- World map is enabled.
- Home and Desert are selectable offline through the existing OfflineSave map persistence/switch path.
- Third world-map slot remains disabled.

## Validation status
Implementation is source-level only until CI builds the exact APK. Physical behavior remains pending manual phone validation.
