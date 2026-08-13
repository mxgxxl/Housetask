# Product Decision Records (PDRs)

Los PDRs registran decisiones de producto con Context / Decision / Consequences, espejo de los ADRs técnicos de CLAUDE.md. Las decisiones aquí contenidas son fuente de verdad para el roadmap; el código las implementa, no las redefine.

## PDR-001: Monetización F2P + mascota cooperativa del hogar

- **Context:** App de gestión doméstica para parejas/hogares. Una suscripción tiene valor percibido bajo para este público y un paywall inicial mataría la adquisición. Se necesita retención más allá de la utilidad diaria y una vía de monetización sin fricción.
- **Decision:**
  1. Free-to-play sin paywall. Monetización en Fase C mediante cosméticos: moneda ganada jugando + packs de pago único vía IAP (revenue_cat).
  2. Mascota compartida del household (pertenece al hogar, como las tareas), con tono visual cozy/adulto (referentes: Forest, Animal Crossing, Duolingo), NO infantil.
  3. Fases:
     - Fase A (MVP): 2 starters (gato/perro), adopción por consenso del hogar (un miembro inicia, el otro confirma), estados que decaen con el tiempo (hambre/ánimo), cuidado mediante tareas completadas y compras realizadas, moneda básica con caps diarios y anti-farm, tienda pequeña de cosméticos por moneda. Sin minijuegos.
     - Fase B: economía completa (loot drops variables, rachas, logros), especies desbloqueables/comprables como colección con UNA mascota activa a la vez (rotable).
     - Fase C: IAPs de packs cosméticos. Minijuegos: puerta abierta futura, no planificados.
  4. Recompensas variables e intermitentes (loot drops, críticos, bonus de racha) en lugar de salario fijo por tarea, para evitar overjustification effect.
  5. Economía server-authoritative: las monedas se otorgan server-side al completar tareas/compras; reglas anti-farm (solo primera completación otorga, caps diarios, cooldowns), apoyadas en la idempotencia y replay detection existentes.
- **Consequences:**
  - Scope nuevo grande pero fasesado; el core (tareas/compras) sigue siendo prioridad hasta validar hábito con uso real (2-4 semanas) antes de iniciar Fase A.
  - Requiere arte animado (Rive/Lottie) para 2 mascotas en Fase A.
  - Fase C requiere cuentas de developer (Apple $99/año, Google $25 único), necesarias de todos modos para publicar.
  - La mascota amplifica un hábito existente, no lo crea: si la retención del core es baja, reevaluar antes de invertir en Fase A.
