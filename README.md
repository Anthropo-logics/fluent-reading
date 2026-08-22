# Fluent Reading · Lectura Fluida · Leitura Fluída

**[English](#english)** · [Español](#español) · [Português](#português)

---

## English

Fluent Reading is a free, open-source PDF reader for macOS that runs entirely on your machine — no
cloud, no accounts, no external APIs. It pairs what you see with what you hear: local
machine-learning models read your document aloud in a natural voice while following along on
screen, so your eyes and ears carry the reading together instead of your eyes doing it alone.

### Why "fluent"

The name is a small manifesto. Reading a dense PDF often isn't fluent at all — the eye snags on
layout noise, attention drifts, a paragraph gets reread three times before it lands. Fluent Reading
tries to close that gap on three fronts at once: it smooths the mechanics of reading by carrying two
senses together instead of one; it builds real fluency in a second language, because hearing correct
pronunciation and cadence while your eyes follow the text trains both at once, without the constant
detour of translating word by word in your head; and it aims for the state psychologists call
*flow* — the concentration deep enough that time stops mattering — which is easier to reach without
cloud notifications, cluttered layouts, or a badly scanned page fighting you for attention.

> We called it Fluent Reading because reading shouldn't be an obstacle course. We want your focus
> to flow without interruption, your grasp of a new language to come naturally, and the step from
> text to understanding to feel as easy as the current of a river.

### Everything stays on your device

This is the part most "AI reading" tools can't say honestly: nothing you open in Fluent Reading is
ever sent anywhere. Text cleanup, OCR, translation, and voice generation all run through quantized
machine-learning models on your own processor. The only time the app touches the network is the
first time you download a model — after that, it works on a plane, in the field, or in any setting
where your documents genuinely cannot leave the room. There is no telemetry and no dependency on a
third-party server standing between you and your own reading.

That same principle shapes the license: Fluent Reading is free software (GPLv3), so the code is
there for anyone to read, audit, and improve — see `LICENSE` and `NOTICE`.

### Two ways to read

- **Immersion Mode** strips the PDF down to clean, readable text — no page furniture, no leftover
  layout — inside a window built for sustained concentration.
- **PDF Mode** keeps the document exactly as designed, so figures and tables stay put, while
  narration highlights the line being read as it goes.

### What that adds up to

Voice and text moving together do more than sound nice: they set a pace that keeps you from losing
your place, so you stop rereading the same paragraph out of habit rather than necessity. With the
mechanical work of decoding each word handed off to a natural local voice, your attention is free to
stay on what the text actually means.

The same local OCR engine (Apple's Vision, running on-device) that powers narration also repairs
documents with a damaged or poorly scanned text layer, and quietly skips page numbers, running
headers, and footnotes so they never interrupt the reading aloud. Translation between Spanish,
English, and Portuguese stays anchored to the original text — read the translation, hear it read
aloud, or step back to the source at any point — and any document can be exported as a chaptered M4B
audiobook for the moments when looking at a screen isn't an option.

### Who it's for

Researchers working through long bibliographies where the material is often under strict
confidentiality; people with ADHD, dyslexia, or visual fatigue, for whom a wall of plain text is a
real barrier rather than a minor inconvenience; and anyone who wants serious AI-assisted reading
without handing their habits to someone else's server.

It also solves a sharper problem for a few specific groups. **Lawyers, judges, and clinicians**
regularly work with case files, contracts, and patient records that legally cannot touch a
commercial AI's cloud — running locally isn't a nice-to-have for them, it's the only option that's
allowed. **Auditors and financial consultants** move through dense regulatory reports where a lapse
in attention is expensive. **Students** get through the week's required reading without a screen
headache, or listen to it on the commute instead. **Field engineers, consultants, and other people
who travel constantly** turn technical reports into audiobooks before a flight and listen to them
with no signal at all. **Writers and editors** catch by ear what the eye stops noticing after hours
of staring at the same page. And **older readers or anyone with chronic visual fatigue** get back an
independence that doesn't depend on a book happening to have an official audiobook edition.

### A note on fiction

None of this is limited to papers and reports. Turn on Immersion Mode for a novel and the printed
chapter headers, page numbers, and rigid PDF layout disappear, leaving something close to a clean
e-reader — and a voice that respects the rhythm of a sentence rather than reading it flatly makes a
real difference to how a story lands. It's also a natural way to finally get through a book that
intimidates by size alone — *One Hundred Years of Solitude*, *Ulysses*, whatever has been sitting
half-read for years — or to read Shakespeare, Camões, or Cervantes in the original with the local
translation as a safety net instead of a crutch. Any literary PDF becomes a private, portable
audiobook, which matters most for the books that were never going to show up on a commercial
platform in the first place.

---

Fluent Reading doesn't edit your PDF and doesn't promise clinical outcomes or guaranteed
improvements in attention or retention. It runs on macOS with Apple Silicon today.

### Download and open it

Go to [Releases](../../releases) and download `LecturaFluida.dmg` (or the `.zip`, if you prefer).
There's no App Store listing and no Apple notarization — this is free software built and signed
locally, not shipped through Apple's paid developer program, so **macOS will refuse to open it the
first time** with a message like *"Apple could not verify... is free of malware."* That's Gatekeeper
doing its job on anything outside the App Store, not a sign that something is wrong.

To open it anyway:

1. Move `LecturaFluida.app` to `/Applications` (drag it there from the disk image).
2. **Right-click** (or Control-click) the app and choose **Open** — not a regular double-click.
3. A dialog appears with an **Open** button this time. Click it once; macOS remembers your choice
   after that.
4. If step 2 doesn't offer an **Open** button, go to **System Settings → Privacy & Security**,
   scroll down, and click **Open Anyway** next to the mention of Fluent Reading, then try opening it
   again.

Prefer the terminal? `xattr -cr /Applications/LecturaFluida.app` clears the quarantine flag
directly and skips the dialogs.

Rather build it yourself? Clone this repository and see the
[build instructions](#documentación-para-quien-compila-o-contribuye) below — no Apple Developer
account is needed to build and run your own copy on your own Mac.

**Ready to use it?** See the [user manual](MANUAL.en.md) for a step-by-step walkthrough.

**License.** Copyright (C) 2026 Jaili Ivinai Buelvas Diaz. Free software under the GNU General
Public License, version 3 or later (`GPL-3.0-or-later`) — see `LICENSE`. Third-party components it
bundles, and what's still pending before any public distribution, are inventoried in `NOTICE`.

---

## Español

Lectura Fluida es un lector de PDF libre y de código abierto para macOS que corre por completo en
tu computadora — sin nube, sin cuentas, sin APIs externas. Une lo que ves con lo que oyes: modelos
de aprendizaje automático locales narran el documento con una voz natural mientras el texto avanza
en pantalla, así que la lectura la llevan el ojo y el oído juntos, no el ojo solo.

### Por qué "fluida"

El nombre es casi un manifiesto. Leer un PDF denso rara vez es fluido de verdad: el ojo tropieza con
el ruido visual, la atención se dispersa, un párrafo se relee tres veces antes de entenderlo.
Lectura Fluida intenta cerrar esa brecha en tres frentes a la vez: suaviza la mecánica de leer al
sumar dos sentidos en vez de uno; construye fluidez real en un segundo idioma, porque oír la
pronunciación y el ritmo correctos mientras el ojo sigue el texto entrena ambos a la vez, sin el
desvío constante de traducir mentalmente palabra por palabra; y busca ese estado que la psicología
llama *flujo* —la concentración tan profunda que el tiempo deja de importar—, más fácil de alcanzar
sin notificaciones de la nube, sin una maquetación desordenada y sin una página mal escaneada
peleando por tu atención.

> Lo llamamos Lectura Fluida porque leer no debería ser una carrera de obstáculos. Buscamos que tu
> concentración fluya sin interrupciones, que domines un idioma nuevo de forma natural, y que el
> paso del texto a la comprensión se sienta tan sencillo como la corriente de un río.

### Todo se queda en tu equipo

Esta es la parte que la mayoría de las herramientas de "lectura con IA" no pueden decir con
honestidad: nada de lo que abres en Lectura Fluida sale jamás de tu máquina. La limpieza de texto,
el OCR, la traducción y la generación de voz corren mediante modelos de aprendizaje automático
cuantizados sobre tu propio procesador. La única vez que la aplicación toca la red es la primera
descarga de un modelo — después de eso, funciona en un avión, en el campo o en cualquier entorno
donde tus documentos de verdad no puedan salir de la sala. No hay telemetría ni un servidor de
terceros interponiéndose entre tú y tu propia lectura.

Ese mismo principio define la licencia: Lectura Fluida es software libre (GPLv3), así que el código
está ahí para que cualquiera lo lea, lo audite y lo mejore — véase `LICENSE` y `NOTICE`.

### Dos maneras de leer

- **Modo Inmersión** reduce el PDF a texto limpio y legible —sin decoraciones ni restos de
  maquetación— dentro de una ventana pensada para sostener la concentración.
- **Modo PDF** conserva el documento tal como fue diseñado, para que gráficos y tablas queden en su
  sitio, mientras la narración resalta la línea que se está leyendo.

### Lo que eso significa en la práctica

Que la voz y el texto avancen juntos no es solo un efecto agradable: marcan un ritmo que evita
perder el sitio, así que dejas de releer un párrafo por costumbre y no por necesidad. Al delegar la
decodificación mecánica de cada palabra a una voz natural local, la atención queda libre para lo que
el texto realmente dice.

El mismo motor de OCR local (Vision, de Apple, ejecutado en tu propio equipo) que hace posible la
narración también repara documentos con una capa de texto dañada o mal escaneada, y salta en
silencio números de página, encabezados repetidos y notas al pie para que nunca interrumpan la
lectura en voz alta. La traducción entre español, inglés y portugués queda anclada al texto
original —puedes leerla, escucharla, o volver a la fuente en cualquier momento— y cualquier
documento puede exportarse como un audiolibro M4B con capítulos, para los momentos en que mirar una
pantalla no es una opción.

### Para quién es

Investigadores que procesan bibliografía extensa, a menudo bajo confidencialidad estricta; personas
con TDAH, dislexia o fatiga visual, para quienes un bloque de texto plano es un obstáculo real y no
una simple molestia; y cualquiera que quiera lectura asistida por IA en serio sin entregar sus
hábitos al servidor de otro.

También resuelve un problema más agudo para algunos grupos concretos. **Abogados, jueces y personal
clínico** trabajan a diario con expedientes, contratos e historiales que, por ley, no pueden tocar
la nube de ninguna IA comercial — que todo corra en local no es un lujo para ellos, es la única
opción permitida. **Auditores y consultores financieros** revisan informes regulatorios densos donde
un descuido de atención sale caro. **Estudiantes** terminan las lecturas obligatorias de la semana
sin dolor de cabeza, o las escuchan en el trayecto. **Ingenieros de campo, consultores y cualquiera
con movilidad constante** convierten informes técnicos en audiolibro antes de un vuelo y lo escuchan
sin cobertura. **Escritores y correctores** detectan por el oído lo que el ojo deja de notar tras
horas mirando la misma página. Y quienes tienen **fatiga visual crónica o son lectores mayores**
recuperan una autonomía que no depende de que un libro tenga, por casualidad, una edición comercial
en audiolibro.

### Una nota sobre la literatura

Nada de esto se limita a artículos e informes. Activa el Modo Inmersión para una novela y
desaparecen los encabezados de capítulo maquetados para imprenta, los números de página y la rigidez
del PDF, dejando algo muy cercano a un buen libro electrónico — y una voz que respeta el ritmo de
una frase, en vez de leerla de forma plana, cambia de verdad cómo aterriza una historia. Es también
una manera natural de por fin terminar ese libro que intimida solo por su tamaño —*Cien años de
soledad*, *Ulises*, lo que sea que lleve años a medio leer— o de leer a Shakespeare, a Camões o a
Cervantes en su idioma original, con la traducción local como red de seguridad y no como muleta.
Cualquier PDF literario se convierte en un audiolibro privado y portátil, lo que más importa
precisamente para los libros que nunca iban a aparecer en una plataforma comercial.

---

Lectura Fluida no edita tu PDF ni promete resultados clínicos o mejoras garantizadas de atención o
retención. Hoy corre en macOS con Apple Silicon.

### Descargarla y abrirla

Ve a [Releases](../../releases) y descarga `LecturaFluida.dmg` (o el `.zip`, si lo prefieres). No
está en la App Store ni pasó por la notarización de Apple — es software libre compilado y firmado de
forma local, no distribuido a través del programa de desarrolladores de pago de Apple, así que
**macOS se negará a abrirla la primera vez**, con un aviso como *"Apple no pudo verificar que...
está libre de malware"*. Eso es Gatekeeper haciendo su trabajo con cualquier cosa fuera de la App
Store, no una señal de que algo esté mal.

Para abrirla igualmente:

1. Mueve `LecturaFluida.app` a `/Aplicaciones` (arrástrala ahí desde la imagen de disco).
2. Haz **clic derecho** (o Control+clic) sobre la app y elige **Abrir** — no un doble clic normal.
3. Esta vez aparece un diálogo con un botón **Abrir**. Púlsalo una sola vez; macOS recuerda tu
   decisión después de eso.
4. Si el paso 2 no ofrece un botón **Abrir**, ve a **Ajustes del Sistema → Privacidad y seguridad**,
   desplázate hacia abajo y pulsa **Abrir de todos modos** junto a la mención de Lectura Fluida, y
   vuelve a intentar abrirla.

¿Prefieres la terminal? `xattr -cr /Applications/LecturaFluida.app` quita la marca de cuarentena
directamente y evita los diálogos.

¿Prefieres compilarla tú mismo? Clona este repositorio y consulta las
[instrucciones de compilación](#documentación-para-quien-compila-o-contribuye) más abajo — no hace
falta ninguna cuenta de Apple Developer para compilar y ejecutar tu propia copia en tu propio Mac.

**¿Listo para usarla?** Consulta el [manual de uso](MANUAL.md), paso a paso.

**Licencia.** Copyright (C) 2026 Jaili Ivinai Buelvas Diaz. Software libre bajo la Licencia Pública
General de GNU, versión 3 o posterior (`GPL-3.0-or-later`) — véase `LICENSE`. Los componentes de
terceros que empaqueta, y lo que aún queda pendiente antes de cualquier distribución pública, están
inventariados en `NOTICE`.

---

## Português

A Leitura Fluída é um leitor de PDF livre e de código aberto para macOS que roda inteiramente no seu
computador — sem nuvem, sem contas, sem APIs externas. Ela une o que você vê com o que você ouve:
modelos de aprendizado de máquina locais narram o documento com uma voz natural enquanto o texto
avança na tela, de modo que a leitura é conduzida pelo olho e pelo ouvido juntos, não pelo olho
sozinho.

### Por que "fluída"

O nome é quase um manifesto. Ler um PDF denso raramente é fluido de verdade: o olho tropeça no
ruído visual, a atenção se dispersa, um parágrafo é relido três vezes antes de fazer sentido. A
Leitura Fluída tenta fechar essa lacuna em três frentes ao mesmo tempo: suaviza a mecânica da
leitura ao somar dois sentidos em vez de um; constrói fluência real num segundo idioma, porque ouvir
a pronúncia e o ritmo corretos enquanto o olho acompanha o texto treina os dois ao mesmo tempo, sem
o desvio constante de traduzir mentalmente palavra por palavra; e busca esse estado que a psicologia
chama de *fluxo* — a concentração profunda o suficiente para o tempo deixar de importar —, mais
fácil de alcançar sem notificações da nuvem, sem uma diagramação bagunçada e sem uma página mal
escaneada disputando a sua atenção.

> Chamamos de Leitura Fluída porque ler não deveria ser uma corrida de obstáculos. Queremos que a
> sua concentração flua sem interrupções, que você domine um novo idioma de forma natural, e que a
> passagem do texto para a compreensão seja tão simples quanto a correnteza de um rio.

### Tudo fica no seu equipamento

Esta é a parte que a maioria das ferramentas de "leitura com IA" não consegue dizer com honestidade:
nada do que você abre na Leitura Fluída sai da sua máquina. A limpeza de texto, o OCR, a tradução e
a geração de voz rodam por meio de modelos de aprendizado de máquina quantizados no seu próprio
processador. A única vez que o aplicativo toca a rede é no primeiro download de um modelo — depois
disso, funciona num avião, no campo ou em qualquer ambiente onde os seus documentos realmente não
podem sair da sala. Não há telemetria nem um servidor de terceiros se colocando entre você e a sua
própria leitura.

Esse mesmo princípio define a licença: a Leitura Fluída é software livre (GPLv3), então o código
está ali para qualquer pessoa ler, auditar e melhorar — veja `LICENSE` e `NOTICE`.

### Duas formas de ler

- **Modo Imersão** reduz o PDF a texto limpo e legível — sem decorações nem sobras de diagramação —
  dentro de uma janela pensada para sustentar a concentração.
- **Modo PDF** mantém o documento exatamente como foi projetado, para que gráficos e tabelas fiquem
  no lugar, enquanto a narração destaca a linha que está sendo lida.

### O que isso significa na prática

Voz e texto avançando juntos não é só um efeito agradável: eles marcam um ritmo que evita perder o
lugar, então você para de reler um parágrafo por hábito, não por necessidade. Ao delegar a
decodificação mecânica de cada palavra a uma voz natural local, a atenção fica livre para o que o
texto realmente diz.

O mesmo motor de OCR local (Vision, da Apple, executado no seu próprio equipamento) que viabiliza a
narração também repara documentos com uma camada de texto danificada ou mal escaneada, e pula em
silêncio números de página, cabeçalhos repetidos e notas de rodapé para que nunca interrompam a
leitura em voz alta. A tradução entre espanhol, inglês e português fica ancorada ao texto original —
você pode lê-la, ouvi-la, ou voltar à fonte a qualquer momento — e qualquer documento pode ser
exportado como um audiolivro M4B com capítulos, para os momentos em que olhar para uma tela não é
uma opção.

### Para quem é

Pesquisadores que processam bibliografia extensa, muitas vezes sob confidencialidade estrita;
pessoas com TDAH, dislexia ou fadiga visual, para quem um bloco de texto simples é um obstáculo real
e não um mero incômodo; e qualquer pessoa que queira leitura assistida por IA a sério sem entregar
os seus hábitos ao servidor de outra empresa.

Ela também resolve um problema mais agudo para alguns grupos específicos. **Advogados, juízes e
profissionais clínicos** trabalham diariamente com processos, contratos e prontuários que, por lei,
não podem tocar a nuvem de nenhuma IA comercial — rodar tudo localmente não é um luxo para eles, é a
única opção permitida. **Auditores e consultores financeiros** revisam relatórios regulatórios
densos onde um descuido de atenção sai caro. **Estudantes** terminam as leituras obrigatórias da
semana sem dor de cabeça, ou as ouvem no trajeto. **Engenheiros de campo, consultores e qualquer
pessoa com mobilidade constante** transformam relatórios técnicos em audiolivro antes de um voo e
os ouvem sem cobertura nenhuma. **Escritores e revisores** percebem pelo ouvido o que o olho deixa
de notar depois de horas olhando para a mesma página. E quem tem **fadiga visual crônica ou é leitor
mais velho** recupera uma autonomia que não depende de um livro ter, por acaso, uma edição comercial
em audiolivro.

### Uma nota sobre literatura

Nada disso se limita a artigos e relatórios. Ative o Modo Imersão para um romance e desaparecem os
cabeçalhos de capítulo diagramados para impressão, os números de página e a rigidez do PDF, deixando
algo bem próximo de um bom e-reader — e uma voz que respeita o ritmo de uma frase, em vez de lê-la de
forma plana, muda de verdade como uma história chega até você. É também uma forma natural de
finalmente terminar aquele livro que intimida só pelo tamanho — *Cem Anos de Solidão*, *Ulisses*, o
que quer que esteja há anos pela metade — ou de ler Shakespeare, Camões ou Cervantes no idioma
original, com a tradução local como rede de segurança, não como muleta. Qualquer PDF literário se
torna um audiolivro privado e portátil, o que importa mais justamente para os livros que nunca
apareceriam numa plataforma comercial.

---

A Leitura Fluída não edita o seu PDF nem promete resultados clínicos ou melhorias garantidas de
atenção ou retenção. Hoje roda em macOS com Apple Silicon.

### Baixar e abrir

Vá em [Releases](../../releases) e baixe `LecturaFluida.dmg` (ou o `.zip`, se preferir). Ela não
está na App Store nem passou pela notarização da Apple — é software livre compilado e assinado
localmente, não distribuído através do programa de desenvolvedores pago da Apple, então **o macOS
vai recusar abri-la na primeira vez**, com um aviso do tipo *"A Apple não conseguiu verificar que...
está livre de malware"*. Isso é o Gatekeeper fazendo seu trabalho com qualquer coisa fora da App
Store, não um sinal de que algo esteja errado.

Para abrir mesmo assim:

1. Mova `LecturaFluida.app` para `/Aplicativos` (arraste-a da imagem de disco).
2. Clique com o **botão direito** (ou Control+clique) no aplicativo e escolha **Abrir** — não um
   duplo clique comum.
3. Desta vez aparece uma caixa de diálogo com um botão **Abrir**. Clique nele uma vez; o macOS
   lembra a sua escolha depois disso.
4. Se o passo 2 não oferecer um botão **Abrir**, vá em **Ajustes do Sistema → Privacidade e
   segurança**, role para baixo e clique em **Abrir mesmo assim** ao lado da menção à Leitura
   Fluída, e tente abrir de novo.

Prefere o terminal? `xattr -cr /Applications/LecturaFluida.app` remove a marca de quarentena
diretamente e evita as caixas de diálogo.

Prefere compilar você mesmo? Clone este repositório e veja as
[instruções de compilação](#documentación-para-quien-compila-o-contribuye) mais abaixo — não é
preciso nenhuma conta de Apple Developer para compilar e rodar a sua própria cópia no seu próprio
Mac.

**Pronto para usar?** Veja o [manual de uso](MANUAL.pt.md), passo a passo.

**Licença.** Copyright (C) 2026 Jaili Ivinai Buelvas Diaz. Software livre sob a Licença Pública
Geral GNU, versão 3 ou posterior (`GPL-3.0-or-later`) — veja `LICENSE`. Os componentes de terceiros
que ela empacota, e o que ainda está pendente antes de qualquer distribuição pública, estão
inventariados em `NOTICE`.

---

## Documentación para quien compila o contribuye

Lo que sigue es la referencia técnica del repositorio: requisitos, compilación y estructura. Si sólo
querías saber qué hace la aplicación, ya lo leíste arriba.

### Requisitos de desarrollo

- Apple Silicon `arm64` con macOS 15.0 o posterior.
- Xcode 26.2 completo, SDK 26.2 y Swift 6.2.3 en modo Swift 6.
- Rust 1.97.1 con `rustfmt` y `clippy` (fijado en `rust-toolchain.toml`).
- Node 24.14.1 y npm 11.16.0.

Instale Xcode por el canal oficial. El proyecto no acepta la licencia ni cambia globalmente
`xcode-select`: apunte `DEVELOPER_DIR` al Xcode correcto. Instale Rust mediante `rustup`:

```bash
rustup toolchain install 1.97.1 --profile minimal --component rustfmt --component clippy
```

### Preparación

```bash
git clone <repositorio-autorizado> lectura-fluida
cd lectura-fluida
DEVELOPER_DIR=/Applications/Xcode_26.2.app/Contents/Developer ./scripts/bootstrap.sh
npm ci
```

`bootstrap.sh` solo comprueba herramientas y versiones: no usa `sudo`, no instala dependencias y no
descarga modelos ni corpus. No existe `.env` de producto.

### Compilar y verificar

Todos los gates pasan por `scripts/verify.sh`, que es también lo que ejecutan los scripts de npm:

```bash
npm run lint        # ./scripts/verify.sh lint       — cargo fmt, JSON válido, bash -n, swift format
npm run typecheck   # ./scripts/verify.sh typecheck
npm test            # ./scripts/verify.sh test       — cargo + integración + xcodebuild test
npm run build       # ./scripts/verify.sh build
./scripts/verify.sh all
```

Compilar solo la aplicación:

```bash
DEVELOPER_DIR=/Applications/Xcode_26.2.app/Contents/Developer \
  xcodebuild \
  -project apps/macos/LecturaFluida.xcodeproj \
  -scheme LecturaFluida \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  build
```

La fase «Build Rust» del proyecto invoca `scripts/build-rust-macos.sh` y enlaza `liblectura_ffi.a`
en la aplicación; no hace falta compilar Rust por separado.

#### Motores de inferencia

Los runtimes de voz y traducción se compilan fuera de este repositorio y **se copian a mano** al
bundle; no hay fase de build que lo haga:

```bash
./scripts/embed-runtimes.sh /ruta/a/LecturaFluida.app [raíz-de-modelos]
```

El script copia `mlx-audio-swift-tts`, `lectura-translate-runtime` y eSpeak NG a
`Contents/Helpers/`, y los vuelve a firmar. El App Sandbox concede lectura sobre una carpeta externa
de modelos pero nunca permiso de ejecución, así que un helper fuera del bundle no puede arrancar.

#### CLI

El núcleo Rust expone una CLI usada por los harnesses de evidencia:

```bash
cargo run --locked -p lectura-cli -- canary --json
```

No inicia servidores ni realiza tráfico de red; `127.0.0.1` no forma parte del producto.

### Estructura

| Ruta | Contenido |
|---|---|
| `apps/macos/LecturaMacApp` | Aplicación SwiftUI: lector, Inmersión, Ajustes, Acerca de |
| `apps/macos/MacPlatform` | Servicios compartidos: documento, modelos, audio, traducción, contrato |
| `apps/macos/LecturaMacTests` | Suite unitaria (test plan `CI-Fast`) |
| `crates/lectura-core` | Núcleo Rust: extracción, normalización, manifiestos |
| `crates/lectura-cli`, `crates/lectura-ffi` | CLI de evidencia y puente FFI hacia Swift |
| `contracts/lf-v1` | Esquemas JSON del contrato entre núcleo y aplicación |
| `models/manifests` | Manifiestos verificados de cada modelo evaluado o distribuido |
| `docs/` | PRD, arquitectura, stories, QA, cumplimiento y runlogs |
| `scripts/` | Bootstrap, verificación, build de Rust, empotrado de runtimes |

Los modelos no se empaquetan con la aplicación: se descargan bajo demanda, verificando tamaño y
sha256 contra un manifiesto, a la carpeta que el lector elige (puede ser un disco externo). La
aplicación nunca impone una ubicación fija.

Cambios por versión: `CHANGELOG.md`.
