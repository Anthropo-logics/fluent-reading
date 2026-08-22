# Corpus TTS de Gate A

Este corpus fija cinco pasajes por idioma mediante rangos de líneas inclusivos sobre tres transcripciones de Project Gutenberg. El pasaje `*-long` de cada idioma supera 1.700 palabras, equivalentes a más de diez minutos incluso a 170 palabras por minuto. Los demás pasajes ejercitan prosa dialogada, nombres propios, números, puntuación y límites de fragmentación.

Las obras originales son de dominio público: *Don Quijote* (Miguel de Cervantes, fallecido en 1616), *Alice's Adventures in Wonderland* (Lewis Carroll, fallecido en 1898) y *Dom Casmurro* (Machado de Assis, fallecido en 1908). Las transcripciones se conservan completas, incluida la licencia de Project Gutenberg, y sus URLs, tamaños y SHA-256 están fijados en `corpus.json`. Debe revisarse la normativa del país donde se redistribuya el corpus; los audios de evaluación y las respuestas individuales no se versionan.

Los rangos se extraen normalizando CRLF a LF y uniendo líneas contiguas con un espacio. La fuente versionada conserva su ortografía histórica. Para TTS, `lectura-core` crea una forma hablada efímera: compone Unicode, contrae espacios y expande únicamente encabezados inequívocos; no reescribe palabras históricas ni intenta sustituir al diccionario fonético fijado de eSpeak-ng. Conserva capitalización y puntuación y selecciona ES, EN-US o PT-BR; `spoken-normalize.mjs` solo adapta ese plan Rust al frontend fonético y el texto fuente no cambia. `cargo test -p lectura-core --test tts_corpus` verifica hashes, rangos, conteos, cobertura ES/EN/PT y duración mínima antes de cualquier benchmark.

Los PDF académicos reales indicados por el usuario pueden probar la cadena PDF → unidades en modo de solo lectura. No se copian aquí ni sustituyen estos pasajes con derechos claros.
