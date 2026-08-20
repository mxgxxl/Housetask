# Especificación UX de P1

> Fecha: 2026-08-20. Fuente de decisiones: [PRODUCT_DECISIONS.md](PRODUCT_DECISIONS.md), PDR-010 a PDR-019.

## 0. Norte y principios

Housetask gana porque el trabajo doméstico se vuelve cooperativo, visible, equilibrado y gratificante, no por acumular más features. Se evita la gamificación punitiva, los leaderboards de culpa y el gambling. La intensidad de celebración es inversa a la frecuencia del evento.

## 1. Modelo económico cerrado

| Elemento | Regla |
|---|---|
| Monedas personales | Presupuesto semanal por miembro; reparto automático determinista por frecuencia esperada; seis asignaciones diarias de lunes a sábado; el domingo descansa; lo no gastado se acumula dentro de la semana. |
| XP personal | Portable con la cuenta. Sus niveles desbloquean títulos y badges. |
| XP de hogar | Compartido y ligado al hogar. Sus niveles desbloquean cosméticos compartidos, incluida la mascota. |
| Anti-farm común | Solo la primera completación de cada instancia recibe recompensa. |
| Autoridad | Todas las reglas económicas son server-authoritative. |

## 2. Gramática visual

- Moneda: ámbar, en la wallet.
- XP personal: relleno de anillo teal/violeta alrededor del avatar; el número de nivel vive dentro.
- Racha: llama coral.
- Hielo: ❄️ azul.
- Descanso: hoja.
- Nivel de hogar: icono de casa con número y barra.

El header persistente contiene tres objetos: avatar con anillo, wallet y racha. El nivel de hogar vive en la tarjeta de hogar, no en el header.

## 3. Jerarquía de celebración

| Evento | Feedback |
|---|---|
| Completar | Chip durante ~1,5 s y animación fly-to hacia su destino. |
| Hielo consumido | Banner de alivio al abrir la app. |
| Hito de racha | Toast, badge y hielo. |
| Nivel personal | Modal con desbloqueo. |
| Nivel de hogar | Modal compartido «lo habéis conseguido juntos» con desbloqueo de hogar. |
| Misión semanal | Cofre con reveal al tap, recompensa útil siempre y cosmético controlado, sin probabilidades aleatorias. |

## 4. Pantallas y componentes

### Línea de hoy

Debajo del header de tareas se muestra una de estas variantes:

- «Hoy: 24/34 🪙 disponibles».
- «Hoy: 58 🪙 (incluye 24 de días anteriores)».
- «Día de descanso: tu progreso cuenta, las monedas descansan».
- «Completaste tu recompensa de hoy; el progreso sigue contando».

### Tarjeta de hogar en Home

Muestra el nivel de hogar y su barra («200 XP para nivel 6»), la meta conjunta activa con desglose por miembro y, si no existe, el empty state con CTA «Elegid algo para los dos». Incluye: «Tu nivel viaja contigo. El nivel de hogar es de los dos.»

### Economía y tienda

El tap en wallet abre «Tu semana»: saldo, progreso semanal, línea de hoy y acceso a «Ajustar reparto». Tiene tabs Personal/Hogar. Si hay meta activa, muestra, por ejemplo, «Skin dragón — 68/100 🪙 · Tú: 40 · Ana: 28», barra y botones «Aportar» y «Cancelar meta»; la confirmación de cancelación avisa del reembolso. Los ítems compartidos ofrecen «Comprar (N 🪙)» y «Ahorrar juntos»; se muestra «Desbloqueado por X». Los ítems de nivel se marcan «ganado». Ambos tabs incluyen empty states con CTA.

### Ajustar reparto

Pantalla secundaria y avanzada. Muestra los valores automáticos por tarea según su frecuencia esperada, por ejemplo «Lavar platos: 4 🪙», con edición mediante stepper sin exceder el presupuesto semanal y el botón «Volver a automático». Encabezado: «Cada semana tienes 200 🪙. El reparto automático los distribuye según frecuencia; ajústalo si quieres.»

### Detalle de racha

El tap en la llama abre una llama grande con el número, reserva de hielos, vías de obtención y calendario semanal con llama/❄️/hoja/hueco. Incluye: «Un día malo no borra lo construido: tu nivel y tu XP siguen intactos.»

## 5. Reglas de rachas y hielos

Los hielos se ganan por hitos 7/14/30/50/100 o se compran por 20 🪙. Hay como máximo dos en reserva. Al cierre de un día de lunes a sábado sin actividad útil se consume uno automáticamente; el domingo es descanso por diseño y nunca consume. Un sync offline tardío de actividad reembolsa el hielo. El día cubierto se muestra como ❄️. Si no hay hielo, la racha se reinicia; nivel, XP y monedas permanecen intactos.

## 6. Reglas de hucha conjunta

La wallet es personal. Los ítems personales se compran con ella. Para un ítem compartido, un miembro puede pagar el precio completo y recibe la atribución «desbloqueado por X», o los miembros pueden aportar a una meta conjunta que se desbloquea automáticamente al alcanzar el precio. En v1 solo hay una meta activa. Cancelarla o salir del hogar reembolsa las aportaciones correspondientes.

## 7. Copy exacto

Además de todas las cadenas citadas en las secciones anteriores:

- «Ayer fue un día complicado. Un hielo cubrió tu racha 🔥 12».
- «La racha se reinicia; tu nivel y tu XP siguen intactos».

## 8. Scope y orden de construcción de P1

1. Separar XP y moneda.
2. Presupuesto, reparto y ajuste.
3. Niveles e hitos.
4. Rachas con hielos.
5. Misiones semanales cooperativas.

Las misiones entran en scope con reglas cerradas: cooperativas, escaladas por tamaño del hogar y cofre determinista. Su especificación UX detallada está **PENDIENTE**. La mascota sigue una pista de arte separada; P1 solo incorpora ganchos lógicos mediante eventos.

## 9. Diferido a v2/P2+

- XP de hogar por aportar a la hucha.
- Múltiples huchas.
- Recuperación de racha tras rotura.
- Bloques P2/P3 de la nota del dueño: reparto inteligente, dashboard de salud, recomendaciones, eventos y notificaciones contextuales.

## 10. Relación con la nota del dueño («Mejoras Housetask»)

Quedan adoptados o transformados: presupuesto semanal en vez de dificultad manual por tarea en v1, rachas tolerantes con hielos, misiones cooperativas y cofres deterministas. Quedan diferidos los elementos enumerados en la sección anterior. Los roles y la administración están parcialmente cubiertos por TDs existentes del repositorio; no se replanifican como trabajo nuevo aquí.

### Preguntas abiertas

- La spec UX detallada de las misiones semanales permanece pendiente.
- Los bloques P2/P3 se decidirán tras cerrar P1; esta especificación no añade decisiones sobre ellos.
