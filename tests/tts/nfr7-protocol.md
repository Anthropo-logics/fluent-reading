# Protocolo ciego NFR7 v1

## Alcance

- Tres revisores humanos como mínimo.
- Quince estímulos por revisor: cinco en español, cinco en inglés y cinco en portugués.
- El orden cambia por revisor y los nombres no revelan modelo, voz, obra ni pasaje.
- Cada idioma incluye un estímulo continuo de al menos diez minutos.
- No se informa al revisor qué modelo produjo el audio. Una escucha previa con identidad conocida no cuenta para NFR7.

## Instrucciones

Escuche cada archivo con audífonos o altavoces habituales, sin alterar velocidad ni aplicar mejora de voz. Puede pausar y repetir. Complete el formulario del mismo paquete sin escribir transcripciones, nombres de modelos ni datos personales.

Para cada estímulo puntúe de 1 a 5:

1. **Naturalidad:** 1 = robótica/insoportable; 5 = natural y sostenida.
2. **Pronunciación:** 1 = ininteligible o errores constantes; 5 = clara y correcta.

Marque cada defecto observado con severidad `low`, `medium` o `high`:

- `omission`: falta contenido audible.
- `repetition`: se repite contenido sin razón.
- `invention`: aparece habla ajena al contenido.
- `cut`: palabra/frase truncada o unión abrupta.
- `artifact`: ruido o distorsión del sintetizador.

Use `high` cuando el defecto impida entender el contenido, altere su sentido o se repita de forma grave. Si no observa defectos, deje `defects` vacío.

## Cálculo y decisión

- Se valida que haya al menos tres formularios completos y exactamente 15 respuestas por formulario.
- Se calcula naturalidad y pronunciación por candidato, idioma y pasaje, conservando denominadores; el idioma se deriva del corpus versionado y no del formulario.
- NFR7 pasa únicamente si el promedio de cada dimensión es ≥4,0 en cada idioma y no existe ningún defecto `high`.
- No se promedian idiomas para ocultar un fallo. Un formulario incompleto o modificado queda excluido con una razón explícita.
- Formularios individuales, audios y clave permanecen fuera de Git. Solo se versionan protocolo, hashes, denominadores y resultados agregados.
