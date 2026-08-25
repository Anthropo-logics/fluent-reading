# Protocolo A/B de naturalidad — Story 6.27

## Comparación

- Veinte oraciones completas: siete ES, siete EN y seis PT; al menos cinco exceden el antiguo
  presupuesto de fragmentación.
- Mismo texto, Kokoro, revisión, runtime y voz en cada par. Sólo cambia el frontend prosódico.
- `legacy`: eSpeak sobre todo el texto y bloques balanceados de hasta 30 palabras IPA.
- `current`: plan hablado Rust, eSpeak por parte, puntuación reinsertada y cortes semánticos bajo el
  límite real de 510 escalares IPA.

Escuche ambos archivos de cada estímulo a velocidad normal y registre `legacy`, `current` o `tie`.
Marque además cualquier corte, omisión, repetición o artefacto que dificulte entender el contenido.

La mejora queda confirmada cuando `current` gana más pares que `legacy` y no introduce un defecto de
severidad alta. La decisión final pertenece al propietario y debe quedar registrada en la story.

Este A/B mantiene fijo el texto para aislar prosodia. La omisión de notas, llamadas, cabeceras, pies
y folios se verifica por separado con el corpus PDF estructural de la story; mezclar esa limpieza en
un solo lado haría imposible atribuir la preferencia auditiva a la segmentación.
