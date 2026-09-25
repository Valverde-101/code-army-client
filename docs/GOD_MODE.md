# Modo Dios — Army Attack AIR clásico

**Repositorio:** `Valverde-101/code-army-client`. Este cambio NO forma parte de Godot.

### Activación

El HUD muestra el botón flotante `DIOS: OFF` durante el juego de campaña. Al pulsar cambia a `DIOS: ON`, y al pulsar otra vez restaura las restricciones. Su identificador es `army_offline_god_mode`; la API de instrumentación es `GameState.setOfflineGodMode(Boolean)` y su consulta es `getOfflineGodModeStatus()`. Cada cambio registra `GOD_MODE` en diagnósticos.

Está disponible exclusivamente cuando `OFFLINE_MODE && DEBUG_MODE && !USE_LIVE_BUILD`, nunca al visitar amigos ni en PvP. No se guardan los desbloqueos como compras reales ni se conceden recursos, dinero o monedas premium.

### Nubes y áreas

Mientras está activo, todas las celdas de la campaña actual se consideran accesibles/visibles aunque la zona esté cubierta por nubes. Se recalculan `mCloudBits`, niebla de guerra y el mapa visible. La configuración temporal sigue activa al entrar en otros mapas de campaña y **no** se aplica a PvP. Al desactivar se vuelve a calcular la visibilidad desde las áreas compradas realmente y la visión de las unidades. No borra ni altera el progreso del jugador.

### Tienda y catálogo completo

La pestaña **Units** utiliza el catálogo runtime `GameState.mConfig.PlayerUnit` completo. Se conservan los productos existentes de `ShopUnit`, se añaden los faltantes por ID y se eliminan duplicados. En el catálogo fuente actual hay **15 tropas**, mientras que la tabla habitual de tienda contiene **14**: `BlackFox` faltaba en esa tabla. Cada unidad es visible y desbloqueada temporalmente, sin requisitos de nivel, misión, edificio, aliados ni límite de tropas. La compra usa el circuito existente y **conserva sus precios** de recursos y premium; no se inventan animaciones ni iconos si faltan en los recursos originales.

### Validación requerida

Ejecutar `Tools/SWF/Test-GodModeContract.ps1` (gate estático), compilar SHA exacto con AIR/FFDec/AndroidBuild Core y probar el APK exacto en ADB físico con capturas de modo OFF, modo ON, mapa Home/Desert/Snow y tienda mostrando todas las 15 tropas. Registrar FAIL/CORRECT/PASS en el mismo PR, incluyendo crash/ANR. No afirmar `PHYSICALLY_VALIDATED` sin APK+ADB+capturas/logs del mismo SHA.
