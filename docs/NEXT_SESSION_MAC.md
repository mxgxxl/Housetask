# NEXT_SESSION_MAC

## Decisión activa

- Claude Code sigue siendo herramienta principal en Mac.
- OpenAI Codex es agente secundario:
  - Mac: Codex CLI, commits directos a main, push aprobado por el dueño.
  - Móvil/cloud: Codex app/web, rama + PR + CI + aprobación del dueño.
- gh CLI instalado y autenticado (Claude Code gestiona PRs y merges).
- Piloto Codex cerrado el 2026-08-17 con resultado positivo.

## Reglas de ejecución

- Un solo agente activo en el repo a la vez.
- El dueño no edita archivos: todo cambio va en prompts de agente.
- No tocar TDs abiertos sin instrucción explícita.
- Commits atómicos; push solo con aprobación del dueño.
- CI verde obligatorio para PRs (flujo móvil/cloud).

## Historial

- 2026-08-16: backlog grooming móvil; TD-002 y TD-015 Resolved.
- 2026-08-17: PR #32 config fallback (Codex); PR #33 integración legacy
  (Claude); PR #34 sync (Codex, cerrado como superseded sin merge). Plan free de Codex activo y validado.
  gh instalado; Codex CLI instalado y autenticado.

## Pendientes arrastrados (grooming 2026-08-16)

- ~~TD-040: CI se cuelga en `offline_banner_test.dart`~~ — Resolved 2026-08-17 (ver "Fase 1" abajo).
- TD-010: verificar backups en el dashboard de MongoDB Atlas/Railway.
- Top-3 Mac (reordenado por PDR-009): TD-059, TD-007 y TD-001.

## Siguiente tarea

**Fase 2 — durabilidad de la caché Hive (TD-059).** Los seis escritores de Hive
de `CacheService` están declarados `void` y descartan el `Future` que devuelve
Hive, así que nadie puede esperar a que una escritura llegue a disco. Pasa a ir
por delante de TD-007 por decisión **PDR-009**: un optimistic update confía en
que la escritura local sobreviva hasta que la cola la reproduzca, y construirlo
sobre persistencia fire-and-forget dejaría dos sospechosos ante el mismo
síntoma. Alcance: seis firmas a `Future<void>`, sus llamadores, auditoría de los
`testWidgets` que tocan Hive y timeouts explícitos en esos tests.

Después, en este orden:

1. **TD-007 — optimistic updates en frontend.** Toca `TaskCubit` y
   `ShoppingCubit` y su interacción con la cola offline (TD-003 / ADR-010).
2. **TD-001 — migrar `members` embebido a colección separada.** La migración
   más grande del backlog abierto.

### Fase 1 — cerrada (TD-040, 2026-08-17)

**Resultado A: la causa raíz era nuestra, no del toolchain.** El 4º test de
`offline_banner_test.dart` escribía en Hive (`Box.put()`, escritura real a
disco) dentro de la zona fake-async de `testWidgets`; el callback de
finalización queda agendado en el reloj falso, que deja de bombearse al
terminar el cuerpo del test, así que la escritura nunca completa y el lock de
la box no se libera — y el `clearAll()` del `tearDown` se queda esperándolo
para siempre. De ahí el 0% de CPU sin fallo de aserción.

Evidencia: una sonda con prints mostró el cuerpo completando (`count=1`) y
`tearDown: antes de clearAll` imprimiéndose, mientras `despues de clearAll` no
aparecía nunca; la misma sonda con la escritura envuelta en `tester.runAsync`
pasó con exit 0. Explica por qué solo este archivo se colgaba:
`cache_service_test.dart` golpea la misma box con las mismas escrituras pero
usa `test()` plano, sin zona fake-async. Refuta la lectura anterior de "stall
de host": la compilación ya había terminado, así que el 0% de CPU era el
deadlock esperando.

Cierre: fix de una línea en el test (`tester.runAsync`); los 6 tests pasan en
<1s y la suite completa (234 tests) en verde. `ci.yml` plegado — el paso
aislado con `continue-on-error` se eliminó, así que una regresión vuelve a
romper CI. De paso se corrigió un falso negativo de `scripts/check_docs.sh`,
que no reconocía un estado `**Resolved**` en negrita.

### Pendientes menores

- Extender el check de enlaces de docs a `CLAUDE.md` (enlaza `docs/ADRs.md`,
  entre otros). Hoy `scripts/check_docs.sh` solo valida los de `AGENTS.md`.
