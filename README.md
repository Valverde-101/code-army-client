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
- La ronda enemiga **no comienza al descontar energía**. Primero debe terminar por completo la acción del jugador; después se respeta una ventana de asentamiento visual de hasta 1.2 s para que disparo, impacto/explosión y animación de cierre terminen antes de activar a los enemigos.
- **Barrera de turnos:** ninguna acción nueva del jugador que esté en la cola puede adelantarse a una respuesta enemiga pendiente. El despachador final (V46, después de V45) debe conservar la llamada de inicio de ronda y esperar a que finalice la respuesta de sus tres unidades principales antes de procesar la siguiente acción del jugador. El plazo de asentamiento del primer turno pendiente no se reinicia por pulsaciones posteriores. Nunca basta con registrar `PLAYER_TURN_ENEMY_RESPONSE_ARMED`: cada turno habilitado debe llegar a `ENEMY_RESPONSE_ROUND_BEGIN` y terminar en `ENEMY_RESPONSE_ROUND_END`, o registrar explícitamente la ausencia de enemigos elegibles.
- Las 3 unidades principales se eligen de forma distinta dentro de la misma ronda.
- **Prioridad de respuesta:** primero los enemigos que recibieron daño del jugador y siguen vivos; después los que pueden atacar de inmediato; luego los cercanos al frente y, sólo si quedan cupos, los lejanos. Un enemigo herido responde prioritariamente a su atacante real cuando continúe en alcance.
- Telemetría de selección: `ENEMY_RESPONSE_HIT_PRIORITY`, `ENEMY_RESPONSE_PRIORITY` (rango, distancia y daño reciente) y `ENEMY_RESPONSE_NO_CANDIDATE` si no hay candidatos.
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

- `PLAYER_TURN_ENEMY_RESPONSE_ARMED`
- `PLAYER_TURN_VISUALS_COMPLETE`
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

### Obstáculos, minas y transitabilidad

- La transitabilidad depende del objeto, su bando y su estado; la defensa contraria intacta bloquea el paso aunque parezca atravesable.
- Cada bando puede atravesar sus propias minas y barricadas. Una torreta defensiva intacta del rival bloquea el paso; hay que destruirla antes de cruzar.
- Minas y barricadas enemigas destruidas se retiran de la cuadrícula al finalizar su animación; si falta la etiqueta `end`, un watchdog de 2,5 s (7,5 s para otras instalaciones) libera su ocupación. El terreno naturalmente impasable sigue impasable.
- La destrucción de una mina propia o enemiga quita 1 punto de vida a cada unidad viva de cualquiera de los dos bandos en la casilla central o cualquiera de las ocho vecinas; cada unidad recibe daño sólo una vez por explosión. No se detona de nuevo al cargar una mina ya destruida.
- Telemetría: `CAMPAIGN_MINE_DETONATED`, `INSTALLATION_WRECKING_CLEANUP`, `ENEMY_MOVE_ABORT`.

### Torreta defensiva y fuego manual

- Una torreta aliada viva dispara automáticamente al entrar un enemigo en su alcance, evaluado respecto a la casilla de llegada real. Una acción de movimiento enemiga no da inmunidad ante este disparo.
- Para disparar manualmente, tocar una torreta y luego un enemigo dentro de su alcance. El tiro manual consume un turno del jugador al completarse y provoca su respuesta enemiga; el disparo automático no consume un turno del jugador.
- Telemetría: `TURRET_AUTO_SHOT_QUEUED`, `TURRET_MANUAL_SELECT`, `TURRET_MANUAL_SHOT_QUEUED`, `TURRET_MANUAL_TURN_CONSUMED`.

### Conquista territorial de campaña

Cuando un enemigo termina un movimiento sobre una casilla del jugador, **esa casilla debe convertirse en territorio enemigo inmediatamente en la misma llegada**.

La decisión se basa en la **casilla de destino recibida por `characterArrivedInCell()`**, no en la casilla anterior que todavía pudiera devolver `getCell()` durante el último frame del movimiento.

Ruta canónica:

`EnemyMovingAction -> IsometricScene.characterArrivedInCell(destino) -> changeCellOwner(destino)`

No se debe escribir manualmente `arrivalCell.mOwner = TILE_OWNER_ENEMY` desde `EnemyMovingAction`; la ruta canónica mantiene sincronizados misiones, estado del mapa, topología y actualización visual.

Si una ciudad o edificio propio cae a cero de salud en campaña, sus casillas amistosas pasan a ser terreno enemigo mediante la transición canónica. Se excluyen decoraciones como minas. Se conservan fronteras y titularidad en el guardado. Telemetría: `CITY_DESTROYED_TERRITORY`.

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
- **Partida nueva:** la primera recompensa sólo se habilita cuando se completa el tutorial y transcurren **3 minutos adicionales** desde esa finalización; ni el inicio de la partida ni una ventana pendiente permiten adelantarla. Se persiste la hora de finalización del tutorial para conservar la espera al cerrar y volver a entrar al juego.
- **Partida existente y días posteriores:** después de esa primera recompensa, las siguientes pueden abrirse al entrar al juego cuando corresponda un nuevo día, sin repetir ni el tutorial ni la espera de tres minutos. Las partidas antiguas con recompensa ya establecida mantienen su acceso inmediato.
- Ambos caminos de apertura de la ventana y la reclamación deben aplicar la misma validación de desbloqueo; no basta con ocultar visualmente el popup.
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
- `DAILY_REWARD_FIRST_UNLOCK_ARMED`
- `DAILY_REWARD_FIRST_UNLOCK_READY`
- `DAILY_REWARD_GAMESTATE`
- `DAILY_REWARD_OPEN_REQUEST`
- `DAILY_REWARD_OPEN_DEFERRED`
- `DAILY_REWARD_OPENED`
- `DAILY_REWARD_ADVANCE`
- `DAILY_REWARD_CARRY_PENDING`
- `DAILY_REWARD_CLAIMED`
- `DAILY_REWARD_CLAIM_REJECTED`

### Recurso agua del Desierto

- El agua, a diferencia de la energía, no se regenera pasivamente por tiempo; se consume con las acciones que requieren el recurso del mapa.
- En campaña offline se permite una planta `WaterPlant` en Home o Desert sin requerir amigos conectados, manteniendo el límite de una planta. Produce agua sin compras prémium y el agua pertenece al perfil compartido entre mapas.
- Producciones originales: 30 unidades por 75 de dinero en 240 s; 45 por 140 en 480 s; 60 por 195 en 960 s. Hay que iniciar y recoger la producción.
- La disponibilidad se ajusta en la configuración compuesta del build y necesita comprobación en el APK; la verificación estática `offline_desert_water_source` no equivale a una prueba física.

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


### Ajustes Fog of War y Animations

Los ajustes gráficos no pueden reconstruir la partida ni bloquear la interacción.

- `Animations` sólo pausa o reanuda las animaciones de personajes y guarda la preferencia. **No** exporta/importa el save, no llama `loadProgress()`, no cierra/reabre el menú y no mueve la cámara artificialmente.
- `Fog of War` no debe provocar una recarga completa del save ni reconstruir toda la escena desde Settings. El cambio queda registrado y se aplica en una inicialización segura de escena, evitando una nube masiva acompañada de bloqueo de input.
- Cambiar cualquiera de estos ajustes no puede iniciar una ronda enemiga ni alterar ownership territorial.
- Telemetría: `SETTINGS_ANIMATIONS_CHANGED` y `SETTINGS_FOG_CHANGED`.

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
