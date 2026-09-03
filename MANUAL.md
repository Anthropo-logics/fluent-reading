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
computadora. Mientras la aplicación está abierta, cambiar entre PDF e Inmersión conserva tu posición.
Si cambias el idioma de la interfaz y eliges **Reiniciar ahora**, el documento vuelve a abrirse en la
misma página y unidad de lectura. En un inicio normal, abre el PDF con **⌘O**.

Si el PDF es un escaneo (fotos de páginas, no texto seleccionable), Lectura Fluida reconoce el texto
automáticamente la primera vez que lo abres. Verás una barra de progreso mientras lo hace; puedes
empezar a leer la primera página en cuanto esté lista, sin esperar a que termine todo el documento.

La preparación se decide página por página: la app conserva el texto digital cuando es útil y usa
OCR local cuando no lo es. En la barra de progreso puedes abrir **Detalles por página** para ver qué
está pendiente, reintentar una página fallida, **Forzar OCR** u omitirla. **Cancelar** detiene el
trabajo sin perder lo ya preparado y **Reanudar** continúa después.

Cuando un PDF necesitó OCR, al terminar la app pregunta si quieres guardar el texto reconocido dentro
del documento. Es opcional: si aceptas, la apariencia no cambia y otras aplicaciones podrán buscar o
seleccionar ese texto; si eliges **No guardar**, el PDF original no se modifica.

![Vista PDF de Lectura Fluida con el selector PDF/Inmersión, los controles de narración, la navegación de página y la barra de procesamiento.](docs/images/reader-pdf.png)

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

![Detalle del Modo Inmersión con el selector de vista y una unidad de lectura resaltada.](docs/images/reader-immersion.png)

### Navegar por el documento

- El botón de barra lateral (o **⌘⌥L**) muestra el índice detectado; al elegir una entrada saltas a
  su página. Si el PDF no tiene estructura confiable, la app lo indica en lugar de inventar títulos.
- En Modo PDF, **← / →** y las flechas junto al número de página avanzan o retroceden páginas.
- En **⋯ Más** puedes girar la página actual a izquierda (**⌘[**) o derecha (**⌘]**). La app vuelve
  a preparar esa página para que lectura, OCR y resaltado usen la nueva orientación.
- En Inmersión, haz doble clic en una unidad para empezar a leer desde allí. Si desplazas el texto a
  mano, el seguimiento se suspende; usa **Reanudar seguimiento automático** para recuperarlo.

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

La hoja **Voz** permite elegir la carpeta de modelos, revisar procedencia/licencia, descargar,
cancelar o reintentar, y seleccionar idioma y voz después de verificar el modelo. Si la narración
falla en un pasaje, **⋯ Más** ofrece **Reintentar este pasaje** u **Omitir este pasaje**; omitir no
borra texto ni cambia el PDF.

## 5. Traducir un documento

Desde **⋯ Más → Traducir**, elige la carpeta de modelos, descarga y verifica el modelo si hace falta,
selecciona el idioma de destino y pulsa **Iniciar traducción**. Puedes cancelar la descarga o la
traducción y reintentarlas. Las direcciones disponibles son entre español, inglés y portugués.

El selector superior **Texto: Original / Traducción** sólo aparece cuando la traducción ha comenzado
o ya existe. Funciona tanto en PDF como en Inmersión y cambia a la vez el texto visible y la fuente
de narración, sin perder la unidad actual. Antes de ese momento no ocupa espacio en la barra. Si
quieres escuchar la traducción, instala también una voz del idioma de destino.

## 6. Exportar un audiolibro

Si prefieres escuchar el documento fuera de la aplicación, ve a **⋯ Más → Exportar**. La hoja indica
si exportará Original o Traducción y permite elegir nombre, idioma, voz y destino. Antes de empezar
muestra duración, tamaño, espacio disponible, unidades listas y contenido degradado u omitido.

El resultado es un único `.m4b`: usa capítulos cuando detecta encabezados confiables y una pista
continua cuando no. La exportación pausa la narración en vivo y puede pausarse, reanudarse,
cancelarse, reiniciarse o reintentarse desde su punto verificado, incluso después de volver a abrir
la app. Al terminar puedes abrir el audiolibro o mostrarlo en Finder; nunca sobrescribe un archivo
existente ni altera el PDF.

El audiolibro generado es tu archivo de salida: la licencia del programa no se extiende a él. Puedes
usarlo o compartirlo, respetando siempre los derechos del documento de origen.

## 7. Cambiar el idioma de la interfaz

Ve a **Ajustes** (**⌘,**) y elige entre español, inglés o portugués — o deja que la aplicación siga
el idioma de tu sistema. El nombre de la aplicación también cambia según el idioma elegido: *Lectura
Fluida*, *Fluent Reading* o *Leitura Fluída*.

Si el cambio de idioma requiere reiniciar la aplicación, se te avisará con claridad y podrás elegir
hacerlo de inmediato o más tarde. Al reiniciar, se restauran el documento abierto, la página, la
unidad de lectura, tus preferencias y la narración que estuviera activa.

## 8. Otros ajustes útiles

- **Unidad de lectura** (sólo en Inmersión): párrafo o frase.
- **Tema** (sólo en Inmersión): papel, sepia u oscuro.
- **Almacenamiento**: muestra los datos procesados del documento abierto y permite eliminarlos sin
  tocar el PDF ni audiolibros terminados.
- **Ayuda de Lectura Fluida**: explica uso, límites y privacidad. El menú **Ayuda → Repetir el tour**
  vuelve a iniciar el recorrido guiado.
- **Acerca de Lectura Fluida** (menú de la aplicación): muestra versión, build, modelos instalados,
  autoría, procedencia, licencias y el `NOTICE` distribuido.

## Mapa de controles

| Lugar | Control | Función y disponibilidad |
|---|---|---|
| Barra superior | Índice | Muestra u oculta la navegación estructural. |
| Barra superior | PDF / Inmersión | Cambia de representación conservando la posición. |
| Barra superior | Anterior · Reproducir/Pausar · Siguiente | Controla la unidad narrada. |
| Barra superior, PDF | Página anterior · número · siguiente | Navega por páginas. |
| Barra superior, tras iniciar traducción | Texto: Original / Traducción | Cambia texto y narración en ambas vistas. |
| Barra superior | ⋯ Más | Abre documento, cambia vista, gira, gestiona almacenamiento, voz, traducción, exportación, unidad, tema, seguimiento, saltos de 15 s, velocidad y recuperación de errores según el estado actual. |
| Menú Lectura | Equivalentes de ⋯ Más | Da acceso por teclado y VoiceOver a procesamiento, voz, traducción, exportación, almacenamiento, narración, unidad, tema y seguimiento. |
| Barra de procesamiento | Progreso · Detalles por página · Cancelar/Reanudar | Supervisa y controla extracción, layout y OCR. |
| Hojas | Voz · Traducción · Exportar · Almacenamiento · Ayuda | Configura o inspecciona cada flujo sin ocultar el documento. |
| Ajustes (⌘,) | Idioma de la interfaz | Sigue el sistema o fija español, inglés o portugués. |

## Atajos de teclado

| Atajo | Acción |
|---|---|
| ⌘O | Abrir un documento |
| ⌘⇧I | Cambiar entre Modo PDF y Modo Inmersión |
| Espacio | Reproducir / pausar la narración |
| ← / → | Página anterior / siguiente (en Modo PDF) |
| ⌥← / ⌥→ | Retroceder / avanzar 15 segundos |
| ⌘⌥L | Mostrar u ocultar el índice de navegación |
| ⌘[ / ⌘] | Girar la página actual a izquierda / derecha |
| ⌘⇧V | Abrir Voz |
| ⌘⌥T | Abrir Traducción |
| ⌘⇧E | Abrir Exportar audio |
| ⌘⌥S | Abrir Almacenamiento |
| ⌘⇧R / ⌘⇧T | Reanudar / reintentar procesamiento |
| ⌘⇧F | Reanudar seguimiento automático (Inmersión) |
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

**Elegí una carpeta y aparece “No se encontró el motor de voz”. ¿Qué hago?**
Abre **⋯ Más → Voz → Elegir carpeta de modelos…** y selecciona de nuevo la carpeta donde la app
descargó el modelo verificado. Elegir una carpeta que sólo contiene pesos sueltos o mover parte del
modelo rompe el conjunto; en ese caso vuelve a descargarlo desde la misma hoja.
