# Manual de uso — Lectura Fluida

*[Read this in English](MANUAL.en.md) · [Leia em português](MANUAL.pt.md)*

Esta guía explica cómo usar Lectura Fluida paso a paso, sin tecnicismos. Si buscas de qué trata el
proyecto o cómo compilarlo, eso está en el [`README`](README.md).

## Antes de empezar

- Lectura Fluida funciona en Mac con chip Apple Silicon (M1 o más nuevo) y macOS 15 o posterior.
- La primera vez que uses la voz o la traducción, la aplicación necesita descargar los modelos
  correspondientes — para eso sí hace falta internet, una sola vez. Después de descargados, todo
  funciona sin conexión.
- Tú eliges dónde se guardan esos modelos (pueden ir en un disco externo si prefieres no ocupar
  espacio en tu Mac). La aplicación te lo pregunta la primera vez que lo necesitas.

## 1. Abrir tu primer documento

Pulsa **⌘O** (o el botón "Abrir" que ves al iniciar la aplicación) y elige cualquier PDF de tu
computadora. La aplicación recuerda automáticamente en qué página y en qué posición te quedaste, así
que la próxima vez que abras ese mismo documento retomas justo donde lo dejaste.

Si el PDF es un escaneo (fotos de páginas, no texto seleccionable), Lectura Fluida reconoce el texto
automáticamente la primera vez que lo abres. Verás una barra de progreso mientras lo hace; puedes
empezar a leer la primera página en cuanto esté lista, sin esperar a que termine todo el documento.

## 2. El recorrido guiado

La primera vez que abras un documento, aparecerá un pequeño recorrido de siete pasos que señala cada
control real de la ventana, explicando para qué sirve. Puedes:

- Pulsar **Siguiente** para avanzar paso a paso.
- Pulsar **Saltar** para cerrarlo de inmediato.
- Marcar **"No volver a mostrar"** si no quieres verlo de nuevo.

Si más adelante quieres repasarlo, está siempre disponible en el menú **Ayuda → Repetir el tour**.

## 3. Dos formas de ver el mismo documento

En la parte superior de la ventana hay un selector **PDF / Inmersión** (también puedes cambiar entre
los dos con **⌘⇧I**):

- **Modo PDF** muestra el documento tal como es — con sus imágenes, tablas y diseño original. Útil
  cuando necesitas ver un gráfico o una tabla mientras lees.
- **Modo Inmersión** quita todo lo que no es el texto en sí: números de página, encabezados
  repetidos, pies de página, decoraciones. Queda solo la lectura, en una ventana pensada para
  concentrarte. Es la vista recomendada si lo que quieres es leer sin distracciones.

Puedes cambiar de una a otra en cualquier momento sin perder tu posición.

## 4. Escuchar mientras lees

Los controles de reproducción están siempre visibles en la parte de arriba de la ventana:

| Botón | Qué hace |
|---|---|
| ▶ / ⏸ (o la barra espaciadora) | Reproduce o pausa la narración |
| ⏮ / ⏭ | Salta al párrafo (o frase) anterior/siguiente |
| Menú **⋯ Más** → retroceder 15s / avanzar 15s | Ajusta la posición del audio sin cambiar de párrafo |
| Menú **⋯ Más** → velocidad | Elige entre 0.75×, 1×, 1.25×, 1.5× o 2× |

Mientras se lee en voz alta, la aplicación resalta en pantalla el fragmento que se está narrando, así
que siempre sabes exactamente dónde va la lectura.

### Elegir la voz

La primera vez que pulses reproducir, la aplicación te pedirá elegir y descargar una voz (esto puede
tardar unos minutos, según tu conexión). Una vez descargada, no vuelve a pedirla — queda lista para
todos tus documentos futuros. Puedes cambiar de voz o de idioma de lectura desde el menú
**⋯ Más → Voz**.

## 5. Traducir un documento

Desde el menú **⋯ Más → Traducir**, puedes activar la traducción de tu documento (hoy, entre
español, inglés y portugués). Igual que con la voz, la primera vez se descarga el modelo de
traducción; después funciona sin conexión.

Una vez activada, en **⋯ Más** aparece un selector **Original / Traducción** para elegir cuál
escuchas o lees. Puedes alternar entre las dos en cualquier momento sin perder tu lugar — Lectura
Fluida mantiene la correspondencia entre el texto original y el traducido.

## 6. Exportar un audiolibro

Si prefieres escuchar el documento fuera de la aplicación (en el coche, caminando, sin pantalla),
ve a **⋯ Más → Exportar**. Lectura Fluida genera un archivo de audio (`.m4b`) con capítulos, que
puedes reproducir en cualquier reproductor compatible con audiolibros. La exportación se puede
pausar y reanudar, y si la cancelas a mitad de camino no se queda a medias: el archivo original no
se ve afectado.

## 7. Cambiar el idioma de la interfaz

Ve a **Ajustes** (**⌘,**) y elige entre español, inglés o portugués — o deja que la aplicación siga
el idioma de tu sistema. El nombre de la aplicación también cambia según el idioma elegido: *Lectura
Fluida*, *Fluent Reading* o *Leitura Fluída*.

Si el cambio de idioma requiere reiniciar la aplicación, se te avisará con claridad y podrás elegir
hacerlo de inmediato o más tarde, sin perder tus preferencias guardadas.

## 8. Otros ajustes útiles

Todos estos están en el menú **⋯ Más**, arriba a la derecha de la ventana:

- **Unidad de seguimiento**: elige si la lectura avanza párrafo por párrafo o frase por frase.
- **Tema de Inmersión**: papel (claro), sepia o oscuro — para leer cómodo según la luz del lugar.
- **Almacenamiento**: consulta o libera el espacio que usan los documentos ya procesados.

## Atajos de teclado

| Atajo | Acción |
|---|---|
| ⌘O | Abrir un documento |
| ⌘⇧I | Cambiar entre Modo PDF y Modo Inmersión |
| Espacio | Reproducir / pausar la narración |
| ← / → | Página anterior / siguiente (en Modo PDF) |
| ⌘⌥L | Mostrar u ocultar el índice de navegación |
| ⌘, | Abrir Ajustes |
| ⌘? | Abrir la ayuda |
| Esc | Cancelar el procesamiento en curso |

## Preguntas frecuentes

**¿La aplicación envía mi documento a internet?**
No, nunca. Todo el reconocimiento de texto, la voz y la traducción ocurren dentro de tu
computadora. La única conexión que se usa es para descargar los modelos la primera vez.

**Abrí un documento escaneado y tarda en estar listo. ¿Es normal?**
Sí, si el PDF no tiene texto seleccionable, la aplicación necesita reconocerlo primero (OCR). Puedes
empezar a leer la primera página en cuanto aparece; el resto sigue procesándose en segundo plano.

**La narración se detuvo con un aviso de error. ¿Qué hago?**
El menú **⋯ Más** te ofrece un botón para reintentar esa parte, o para saltarla y seguir adelante.

**¿Puedo usar la aplicación sin ratón, solo con teclado?**
Sí — todos los controles principales tienen un atajo de teclado (ver la tabla arriba), y la
aplicación es compatible con VoiceOver.

**¿Dónde se guardan los modelos de voz y traducción?**
Donde tú elijas — puede ser tu Mac o un disco externo. La aplicación nunca impone una carpeta fija.
