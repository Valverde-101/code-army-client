# Army Attack → Godot: extracción inicial del terreno Home

## Alcance

Esta tarea conserva el juego AIR intacto. El workflow `godot-home-terrain.yml` ejecuta JPEXS FFDec 26.2.1 en nuestro runner Windows y parte del **SWF exacto** `vendor/Test_army_attack/armyattack/assets/iArmyAirOfflineSavingv23.swf` (SHA-256 `99a7e8c219610eabbe97aee74228d52ded1532b4c2d4310432d15082b2ff11c4`; submódulo `306bccc7db5b1ce34dd68a3bc80093648c9224bd`).

El workflow comprueba el SHA del checkout y del SWF antes de trabajar, no cambia ni resetea el checkout canónico compartido y no instala ni ejecuta APK. Reutiliza la extracción completa previa solo si su manifiesto corresponde al SWF exacto y comprueba tamaño y SHA-256 de cada PNG elegido frente al inventario; si la caché no existe o no es válida, vuelve a exportar sprites con FFDec.

## Dónde queda la extracción

Ruta reproducible y portátil:

`<ANDROIDBUILD_ROOT>\Repositories\code-army-client\.work\godot-home-terrain\<EXPECTED_SOURCE_SHA>\<RUN_ID>\`

`original/`: PNG originales con transparencia y lienzo intactos. `trimmed/`: variantes recortadas de los que tienen márgenes transparentes, **sin ampliar el dibujo**. En `manifest.json`, cada imagen registra fuente relativa, tamaño, SHA-256, dimensiones del lienzo, dimensiones visibles, offset `crop_left/crop_top`, archivo recortado y duplicados idénticos. Para posicionar en Godot un recorte, conservar el offset del lienzo original. Se incluye `tile_map_home.csv` y `reports/summary.json`.

No se presupone que el código numérico de `tile_map_home.csv` corresponda directamente al identificador de cada sprite. La reconstrucción de Home en Godot y la verificación de sus transformaciones son trabajo posterior. El workflow marca PASS **solo** la extracción, no la importación Godot, compilación APK ni validación física.

No subir volcados de miles de PNG, SDK, cachés ni binarios al PR ni a GitHub Actions Artifacts. Los resultados permanecen en `.work` del SSD. Esta rama es independiente del PR #5 (mejoras del juego AIR). Confirmar derechos sobre los recursos antes de distribuir una reconstrucción públicamente.
