# Corpus reproducible v1

`manifest.json` es la autoridad del corpus distribuible: 12 PDFs de la matriz idioma×tipo, un PDF de 1.000 páginas y un adversarial controlado. Cada entrada enlaza por SHA-256 su PDF y su verdad de referencia.

Validación:

```sh
cargo run --locked -p lectura-cli -- corpus validate --manifest tests/corpus/manifest.json --json
```

El comando solo lee `manifest.json`, `documents/` y `expected/`; emite un terminal LF v1 y no modifica esos archivos. Su salida puede regenerarse o redirigirse a una ruta temporal bajo `artifacts/` sin convertirla en autoridad.

`scripts/generate-corpus-fixtures.mjs` es únicamente el constructor determinista de las muestras sintéticas versionadas. Cambiar o volver a generar una muestra requiere revisar el diff, incrementar la revisión de su ground truth y validar nuevamente el manifiesto. Las muestras con uso restringido viven en `local/`, están ignoradas por Git y nunca cuentan como cobertura completa si una entrada obligatoria falta.
