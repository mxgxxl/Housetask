# TD-066 — Runbook de activación de la economía P1

> Estado: escrito en B11 (2026-08-27), **no ejecutado todavía contra ningún
> hogar**. El flag está apagado en producción para todos.

Este documento se sigue **hogar por hogar**. No existe un «activar para todos»
a propósito: cada activación exige una decisión humana que ninguna consulta
puede tomar por ti (§2).

---

## 1. Qué hace la activación, y qué no

**Hace** tres cosas, en una transacción:

1. Escribe una fila en `HouseholdEconomyMigration` con `phase: 'active'`, el
   saldo de Fase A del hogar, el watermark de su ledger y el
   `legacyWalletUserId` que decidiste.
2. Acredita ese saldo, una sola vez, a la wallet personal de esa persona.
3. A partir de ese momento `isP1Enabled` devuelve `true` para ese hogar, así
   que sus completaciones empiezan a pagar por el plan semanal en vez de por
   el tope diario de Fase A.

**No hace nada destructivo.** `EconomyLedger`, `GET /economy`, la mascota y sus
cosméticos siguen exactamente igual. Las dos economías conviven; ese es el
diseño (§6.5), no una fase temporal que haya que cerrar con prisa.

---

## 2. La decisión que tienes que tomar antes de ejecutar nada

El ledger de Fase A guarda `householdId` y **nunca** `userId`: el saldo es del
HOGAR. Las wallets de P1 son personales. Así que trasladar ese saldo obliga a
nombrar a una persona, y **ninguna consulta puede nombrarla**:

- Repartirlo a partes iguales inventaría una distribución que nadie acordó.
- Acreditárselo entero a cada miembro multiplicaría el dinero del hogar por su
  tamaño.

Por eso `--legacy-wallet` es obligatorio y el script se niega a funcionar sin
él. Queda registrado en la fila de migración, así que la decisión es auditable
después.

### Si el hogar tiene varios miembros

Tres opciones, en orden de preferencia:

1. **Gastar el saldo antes de migrar.** Lo más limpio: que el hogar compre lo
   que quiera en la tienda de mascota hasta dejar el saldo cerca de cero, y
   entonces la decisión deja de importar. Comprueba el saldo con el paso 3.
2. **Acordar un destinatario.** Habitual en pareja: uno recibe el saldo y lo
   aporta a la hucha conjunta si quieren repartirlo. Anota el acuerdo.
3. **Repartir a mano antes de migrar.** No hay herramienta para esto; habría
   que escribir asientos en `PersonalCoinLedger` manualmente. **No recomendado**
   sin un script propio y su propia revisión.

---

## 3. Antes de activar: qué mirar

```bash
cd backend

# ¿Cuál es el saldo actual del hogar, y cuánto se ha ganado hoy?
#   (esto es lo que se va a acreditar a UNA persona)
railway run --service Housetask node -e "…"   # o desde Atlas:
#   db.economyledgers.aggregate([
#     { $match: { householdId: ObjectId('<householdId>') } },
#     { $group: { _id: null, total: { $sum: '$amount' } } }
#   ])

# ¿Quiénes son los miembros?
#   db.householdmembers.find({ householdId: ObjectId('<householdId>') })
```

Comprueba también:

- [ ] El hogar **no** aparece ya en `householdeconomymigrations`.
- [ ] El `legacyWalletUserId` elegido **es miembro** de ese hogar (el script lo
      verifica y se niega si no, pero conviene saberlo antes).
- [ ] Hay acuerdo humano sobre quién recibe el saldo (§2).

---

## 4. Ejecutar

**Siempre dry-run primero.** El script no escribe nada sin `--yes`.

```bash
cd backend

# 1) Dry run — reporta lo que haría, no toca nada
railway run --service Housetask npx ts-node src/scripts/activate-p1-economy.ts \
  --household=<householdId> --legacy-wallet=<userId>

# 2) Aplicar
railway run --service Housetask npx ts-node src/scripts/activate-p1-economy.ts \
  --household=<householdId> --legacy-wallet=<userId> --yes

# 3) Dry run otra vez — debe decir "already migrated: true" y no escribir nada
railway run --service Housetask npx ts-node src/scripts/activate-p1-economy.ts \
  --household=<householdId> --legacy-wallet=<userId>
```

La tercera pasada es la que demuestra la idempotencia, igual que se hizo con el
backfill de TD-001. Pega los tres resúmenes en la ficha de TD-066 de
`docs/TECH_DEBT.md`.

El resumen tiene esta forma:

```
[APPLIED] P1 activation for "Casa de prueba" (6a78ce17…)
  already migrated:   false
  members:            2
  legacy wallet:      6a78ce…
  legacy balance:     27
  ledger watermark:   2026-08-27T16:15:13.656Z
  legacy credit:      written
```

---

## 5. Después de activar: qué verificar

- [ ] `GET /households/<id>/economy/p1/me` responde `enabled: true` y la wallet
      con el saldo heredado.
- [ ] `GET /households/<id>/economy` (Fase A) **sigue respondiendo igual**: el
      saldo del hogar no ha cambiado y la tienda de mascota sigue funcionando.
- [ ] Completar una tarea paga según el plan semanal, no los 5 🪙 planos.
- [ ] Los logs de Railway no traen `WARN`/`ERROR`.

---

## 6. Si algo va mal

### Parada de emergencia, inmediata, para TODOS los hogares

```bash
railway variables --set P1_ECONOMY_KILL_SWITCH=true
```

`isKillSwitchOn()` se lee en **cada llamada**, no al arrancar, y corta antes
que el resolver — así que no hace falta reiniciar y no depende de que la base
de datos responda. Todo vuelve a la economía Fase A al instante.

Para rearmar: pon la variable a cualquier otra cosa, o quítala. Solo la cadena
exacta `'true'` la activa.

### Desactivar un solo hogar

```js
// Atlas, o railway run node
db.householdeconomymigrations.updateOne(
  { householdId: ObjectId('<householdId>') },
  { $set: { phase: 'rolled_back', rolledBackAt: new Date() } }
)
```

El hogar vuelve a Fase A en la siguiente petición. **No se borra nada**: los
ledgers P1, los recibos, el presupuesto y la racha siguen en disco para
reconciliar, y volver a poner `phase: 'active'` reactiva el hogar con su
historia intacta.

> **No borres la fila de migración** para desactivar. Borrarla haría que una
> nueva ejecución del script acreditara el saldo heredado por segunda vez —
> aunque el índice único del `PersonalCoinLedger` lo impediría, es una red de
> seguridad, no un plan.

### Si el crédito heredado se acreditó a quien no debía

No hay deshacer automático. El asiento está en `PersonalCoinLedger` con
`reason: 'legacy_balance'` y `refId: <householdId>`. Corregirlo exige un
asiento de compensación escrito a mano, y conviene hacerlo **antes** de que esa
persona gaste nada.

---

## 7. Riesgos conocidos que este runbook no resuelve

- **Una meta de hucha desbloqueada no entrega el cosmético todavía** (R44 de
  B10): marca que el hogar pagó, pero nada lo añade a `Pet.cosmetics`. La
  tienda de Fase A sigue cobrándolo aparte.
- **Los desbloqueos por nivel son ids sin efecto** (R28 de B7): se conceden y
  se leen, pero ninguna UI los muestra y `cosmetic:hat` no desbloquea de hecho
  el sombrero.
- **Ningún cliente consume P1 todavía.** Hasta la fase de frontend, activar un
  hogar cambia lo que el servidor calcula pero no lo que la app enseña — salvo
  que las monedas de Fase A dejarán de subir al ritmo de antes, porque el
  grant paralelo de la decisión P2(b) sigue siendo de 5 🪙 mientras la wallet
  personal recibe lo que diga el plan.

Por eso la recomendación es **no activar ningún hogar real hasta que F2 esté
desplegado**, salvo para una prueba deliberada y acotada.
