# Notas de versión — Lectura Fluida

Formato basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/).
Las versiones siguen [SemVer](https://semver.org/lang/es/).

La versión que muestra el panel «Acerca de» sale de `MARKETING_VERSION` y
`CURRENT_PROJECT_VERSION` del proyecto de Xcode. Al preparar una versión hay que subir ambos y
añadir aquí su sección.

## [0.4.0] — 2026-08-25 (build 4)

### Añadido

- Clasificación estructural local con PP-DocLayoutV3/Core ML para orientar el orden de lectura,
  columnas, pliegos, notas, cabeceras, pies y folios sin sustituir el texto fiel de PDFKit/Vision.
- Degradación conservadora: regiones vacías, insuficientes o inciertas conservan el texto fuente
  como contenido audible y trazable.

### Corregido

- La narración mantiene frases y pausas naturales mediante una única planificación prosódica para
  lectura y exportación, validada por el propietario en un A/B Kokoro ES/EN/PT sin degradación.
- El fallback OCR conserva cada mitad válida de un pliego y recupera páginas JBIG2 que el thumbnail
  de PDFKit puede renderizar sin tinta.
- Cancelar o cambiar de documento termina también los procesos activos de eSpeak y Kokoro.

## [0.3.0] — 2026-08-25 (build 3)

### Añadido

- Proyección hablada separada del texto visible: conserva el documento y sus anclas mientras omite
  de la narración llamadas de nota emparejadas, notas al pie y mobiliario editorial repetido.
- Un único plan de habla para lectura y exportación, con puntuación prosódica y cortes por oración o
  cláusula dentro del límite real de Kokoro.

### Corregido

- Las notas densas, cabeceras, pies, folios y créditos editoriales ya no interrumpen la lectura
  automática; los años, cifras y numerales relevantes del cuerpo permanecen audibles.
- Las entradas numeradas de tablas de contenido conservan sus títulos y orden; los puntos guía y el
  folio final no se narran.
- El gate de macOS serializa tests de modelo y UI para evitar que Xcode mate el runner por presión de
  recursos.

## [0.2.0] — 2026-08-24 (build 2)

### Añadido

- Icono propio de Lectura Fluida: un libro abierto y un pulso violeta que representan lectura y
  narración continua.

### Corregido

- La prueba de rendimiento permite reabrir documentos con ⌘O desde el estado de lectura.

## [0.1.0] — 2026-08-22 (build 1)

El proyecto es software libre bajo `GPL-3.0-or-later` (`LICENSE`); `NOTICE` enumera los componentes
de terceros y sus obligaciones de distribución.

### Añadido

- Apertura y visualización del PDF original, con extracción digital de texto y OCR local (Vision)
  página a página cuando el documento es escaneado o de calidad mixta.
- Vista Inmersión: el texto extraído, sin maquetación, intercambiable con el PDF original sin
  perder la posición de lectura.
- Narración local en español, inglés y portugués con una voz cuantizada, seguimiento por párrafo o
  frase, desplazamiento automático de la vista y transporte de reproducción (reproducir, pausar,
  avanzar y retroceder).
- Exportación de audiolibro en formato M4B con capítulos y metadatos, de forma incremental,
  cancelable y reanudable.
- Traducción local anclada al texto original, con correspondencia reversible frente al original,
  elección entre narrar la versión Original o la Traducción, y exportación de la narración
  traducida.
- Tutorial interactivo de primer uso.
- Selector explícito de idioma de la interfaz (español, inglés, portugués), independiente del
  idioma del sistema; el nombre visible de la aplicación cambia con el idioma elegido («Lectura
  Fluida» / «Fluent Reading» / «Leitura Fluída»).
- Panel «Acerca de» con nombre, versión, número de build y créditos de los modelos y bibliotecas de
  terceros, leídos de sus manifiestos reales.
- Archivos `LICENSE` y `NOTICE` en la raíz del proyecto.

### Seguridad

- Corregido un fallo en el script de empaquetado que, en cada compilación, volvía a firmar la
  aplicación sin el sandbox de macOS.

Todo el procesamiento ocurre en el dispositivo: la aplicación no envía el documento, el texto ni el
audio a ningún servicio remoto, y no requiere cuenta ni conexión salvo para descargar los modelos la
primera vez, a la carpeta que el propio lector elige.
