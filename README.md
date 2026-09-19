# Army Attack: Surge of the Crimson Empire

Reactivación del juego de Facebook de 2011 de Digital Chocolate. Este proyecto parte de la versión Android del juego y la adapta para funcionar offline.

## Contrato de comportamiento del juego

Esta sección es el contrato funcional de Army Attack offline/móvil. Una modificación del código no debe cambiar estas reglas accidentalmente. Si una regla cambia intencionalmente, deben actualizarse en el mismo cambio el código, este README y las pruebas de regresión.

### IA enemiga y rondas por turnos

Cada acción válida del jugador que consume su turno —por ejemplo mover una unidad o atacar— abre **una ronda enemiga de 3 unidades principales distintas**.

Reglas fijas:

- Antes de moverse, cada unidad principal comprueba si tiene a rango una unidad, instalación o estructura atacable del jugador.
- Si ya tiene un objetivo a rango, **ataca primero y no se mueve en ese turno**.
- Si no tiene objetivo a rango, realiza **un movimiento**.
- Si después de ese movimiento entra a rango de un objetivo, **el movimiento y el ataque posterior pertenecen al mismo turno enemigo**.
- Si termina el movimiento sin objetivo a rango, termina su turno.
- No hay activaciones enemigas autónomas entre acciones del jugador: la campaña offline avanza por las rondas provocadas por las acciones del jugador.
- Las 3 unidades principales se eligen de forma distinta dentro de la misma ronda.
- Una unidad que ya participó como apoyo no puede volver a consumir uno de los 3 cupos principales de esa ronda.

### Ataques múltiples y ataques grupales

Cada enemigo que participa en un ataque tiene este presupuesto de disparos dentro de su mismo turno:

- **55%: 1 ataque**
- **40%: 2 ataques**
- **5%: 3 ataques**

El segundo o tercer ataque probabilístico **no consume otro turno**.

Si una unidad principal ataca un objetivo y existen otros enemigos que también tienen **ese mismo objetivo** dentro de su alcance, todos esos enemigos pueden sumarse como apoyo al ataque grupal.

- **Los ataques grupales no consumen un turno principal adicional.**
- Una unidad que participó como apoyo queda marcada como participante de la ronda y no puede ser elegida después como una unidad principal de esa misma ronda.
- Cada apoyo conserva su propio presupuesto 55/40/5.
- Si el objetivo muere o sale de alcance, no se siguen generando ataques.
- Nunca se debe reactivar un atacante indefinidamente por el simple hecho de tener un objetivo cerca.

Telemetría principal:

- `ENEMY_RESPONSE_ROUND_BEGIN`
- `ENEMY_RESPONSE_PRIMARY`
- `ENEMY_RESPONSE_TURN_BEGIN`
- `ENEMY_RESPONSE_MOVE`
- `ENEMY_RESPONSE_ATTACK`
- `ENEMY_RESPONSE_ATTACK_REPEAT`
- `ENEMY_GROUP_ATTACK`
- `ENEMY_GROUP_ATTACK_ASSIST`
- `ENEMY_RESPONSE_TURN_COMPLETE`
- `ENEMY_RESPONSE_ROUND_END`
- `ENEMY_ATTACK_TURN`

### Movimiento y presión territorial enemiga

Los enemigos de campaña deben progresar hacia unidades, instalaciones, edificios y territorio controlado por el jugador.

- Un destino debe mejorar el avance hacia un objetivo cuando exista una ruta útil.
- Debe evitarse la oscilación inmediata A -> B -> A cuando exista un paso de progreso.
- Si no existe una ruta directa, se usa el fallback hacia el área del jugador.
- Las reservas de casillas se liberan en éxito, aborto, ruta vacía y watchdog.
- Un fallo de pathfinding no debe dejar una casilla bloqueada permanentemente.

Telemetría:

- `ENEMY_MOVE_ABORT`
- `ENEMY_MOVE_PATH_FAIL`
- `ENEMY_MOVE_WATCHDOG`
- `ENEMY_MOVE_SYNC_SKIP`

### Conquista territorial de campaña

Cuando un enemigo termina un movimiento sobre una casilla del jugador, **esa casilla debe convertirse en territorio enemigo inmediatamente en la misma llegada**.

La decisión se basa en la **casilla de destino recibida por `characterArrivedInCell()`**, no en la casilla anterior que todavía pudiera devolver `getCell()` durante el último frame del movimiento.

Ruta canónica:

`EnemyMovingAction -> IsometricScene.characterArrivedInCell(destino) -> changeCellOwner(destino)`

No se debe escribir manualmente `arrivalCell.mOwner = TILE_OWNER_ENEMY` desde `EnemyMovingAction`; la ruta canónica mantiene sincronizados misiones, estado del mapa, topología y actualización visual.

Los saves antiguos pueden contener enemigos ya parados sobre casillas todavía aliadas. `turn_reconcile` se conserva sólo como reparación histórica; **las capturas nuevas deben aparecer como `reason=arrival`**.

Telemetría:

- `CAMPAIGN_ARRIVAL_OWNERSHIP`
- `CAMPAIGN_TERRITORY_CAPTURE`
- `reason=arrival`
- `reason=turn_reconcile`

### Invariante territorial de PvP

**PvP no permite conquista territorial durante el movimiento.**

La lógica de captura de campaña no debe filtrarse a `PvPEnemyMovingAction`. En PvP mover una unidad no cambia el dueño de una casilla.

### Reparaciones y pérdida permanente de unidades

La campaña offline usa:

`MAX_OFFLINE_REPAIRS = 3`

Una unidad destruida puede consumir una vida de reparación al recuperarse. El contador se guarda como `repairs_used`. Después de consumir las tres reparaciones, una destrucción posterior provoca pérdida permanente en lugar de permitir ciclos infinitos de reparación.

La regla se aplica a unidades normales y premium de campaña. PvP queda excluido.

### Compatibilidad de saves

Esquema actual:

`armyattack-offline-save/v10`

Se conservan mapas, ownership territorial, unidades, `repairs_used`, misiones, inventario, perfil y recompensa diaria. Los saves anteriores se migran hacia delante; si fueron creados antes de existir `repairs_used`, ese contador comienza en cero porque no existe historial fiable para reconstruir reparaciones anteriores.

### Recompensa diaria

La campaña offline admite una racha de **360 días**.

Reglas:

- Una recompensa puede reclamarse una sola vez por día calendario.
- La ventana debe intentar abrirse al entrar al juego siempre que la recompensa del día siga pendiente.
- Si otro recurso o popup está cargándose, la recompensa **no se pierde**: queda pendiente y **se reintenta hasta que la ventana se abra realmente**.
- Cerrar o fallar al abrir la ventana no equivale a reclamar la recompensa.
- Después de reclamarla, no vuelve a abrirse ese mismo día.
- Al siguiente día se presenta el día siguiente **sólo si la recompensa anterior fue reclamada**.
- Si se entró el día anterior pero no se reclamó, el mismo día de recompensa continúa pendiente y vuelve a mostrarse al entrar.
- Si el jugador deja pasar un día completo sin entrar, la racha se reinicia.
- Después del día 360, la secuencia vuelve al día 1.
- Las definiciones originales de cinco días pueden reutilizarse cíclicamente cuando no exista una definición explícita para un día superior.

Telemetría:

- `DAILY_REWARD_STATE`
- `DAILY_REWARD_GAMESTATE`
- `DAILY_REWARD_OPEN_REQUEST`
- `DAILY_REWARD_OPEN_DEFERRED`
- `DAILY_REWARD_OPENED`
- `DAILY_REWARD_ADVANCE`
- `DAILY_REWARD_CARRY_PENDING`
- `DAILY_REWARD_CLAIMED`
- `DAILY_REWARD_CLAIM_REJECTED`

### Mapas de campaña

Los mapas de campaña autorados son:

- `Home`
- `Desert`
- `Snow`

Un cambio de mapa espera sus recursos y tilemap antes de confirmar la transición. Snow no puede degradarse silenciosamente a Home.

### PvP

El terreno PvP nativo actualmente autenticado es `pvp_map_1_4valleys_11x11`. Los terrenos PvP sintéticos continúan deshabilitados hasta recuperar e integrar mapas autorados reales.

### Rendimiento y presupuesto espacial de IA

La campaña offline usa un **conjunto activo objetivo: 24 enemigos** para actividad espacial normal. Los enemigos comprometidos en combate o necesarios por una amenaza inmediata pueden superar temporalmente ese número.

La visibilidad de viewport se determina con `isRenderableActuallyInViewport()`. `isInsideVisibleArea()` representa área desbloqueada y no debe utilizarse como sustituto de “está en cámara”.

### Animaciones y efectos de combate

La finalización lógica de una acción no puede depender indefinidamente de una etiqueta de animación. Misiles, artillería, explosiones, impactos, wrecking y suministros usan cleanup/watchdogs acotados para evitar residuos visuales permanentes.

La lógica del ataque y la limpieza visual son responsabilidades separadas.

### Colocación móvil

Comprar o colocar una unidad en móvil requiere confirmación explícita. Soltar un toque sobre el mapa no debe confirmar silenciosamente la compra antes del check.

### Exportación e importación

El juego puede generar y compartir un save/diagnóstico portable. Un save externo se valida antes de reemplazar el estado interno y se conserva respaldo del save anterior antes de modificarlo.

### Niveles de validación

El proyecto diferencia:

- `IMPLEMENTED`
- `COMPILED`
- `APK_GENERATED`
- `INSTALLED`
- `LAUNCHED`
- `AUTOMATED_TESTED`
- `PHYSICALLY_VALIDATED`

`PHYSICALLY_VALIDATED` exige instalar mediante ADB físico el APK exacto correspondiente al `TESTED_SHA` y conservar evidencia. Un build verde o un workflow físico omitido no equivale a validación física.

## Aspectos legales

Este repositorio se mantiene con fines educativos y no pretende monetizarse. Para cualquier asunto legal, contactar con los responsables del proyecto.

## Cómo jugar

Esta página está orientada principalmente a desarrolladores. Para jugar, puede utilizarse la versión publicada por el proyecto.

## Cómo compilar

Se utiliza Adobe Animate y AIR SDK de HARMAN. El pipeline versionado del repositorio define las comprobaciones adicionales utilizadas para los candidatos Windows y Android.

## Licencia

GPL v3.

```
Army Attack: Surge of the Crimson Empire.
Copyright (C) 2024 | Army Attack Development Team
See the GNU General Public License <https://www.gnu.org/licenses/>.
```
