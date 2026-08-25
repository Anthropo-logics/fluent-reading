# Notas de versión — Lectura Fluida

Formato basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/).
Las versiones siguen [SemVer](https://semver.org/lang/es/).

La versión que muestra el panel «Acerca de» sale de `MARKETING_VERSION` y
`CURRENT_PROJECT_VERSION` del proyecto de Xcode. Al preparar una versión hay que subir ambos y
añadir aquí su sección.

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
