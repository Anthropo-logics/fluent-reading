# User manual — Fluent Reading

*[Léelo en español](MANUAL.md) · [Leia em português](MANUAL.pt.md)*

This guide explains how to use Fluent Reading step by step, without jargon. If you're looking for
what the project is about or how to build it, that's in the [`README`](README.md).

## Before you start

- Fluent Reading runs on a Mac with Apple Silicon (M1 or newer) and macOS 15 or later.
- The first time you use voice narration or translation, the app needs to download the matching
  models — that's the only time you need an internet connection. After that, everything works
  offline.
- You choose where those models are stored (an external drive works fine if you'd rather not use
  space on your Mac). The app asks you the first time it needs to know.

## 1. Open your first document

Press **⌘O** (or the "Open" button you see when the app starts) and pick any PDF on your computer.
While the app remains open, switching between PDF and Immersion preserves your position. If you
change the interface language and choose **Restart now**, the document reopens at the same page and
reading unit. On an ordinary launch, open the PDF with **⌘O**.

If the PDF is a scan (photos of pages, not selectable text), Fluent Reading recognizes the text
automatically the first time you open it. You'll see a progress bar while it works; you can start
reading the first page as soon as it's ready, without waiting for the whole document to finish.

Preparation is decided page by page: the app keeps useful digital text and uses local OCR when the
text layer isn't reliable. Open **Page details** from the progress bar to see pending work, retry a
failed page, **Force OCR**, or skip it. **Cancel** stops without discarding completed pages and
**Resume** continues later.

When a PDF needed OCR, the app asks whether to save the recognized text inside the document. This is
optional: accepting keeps the page appearance unchanged and makes the text searchable/selectable in
other apps; choosing **Don't save** leaves the original PDF unchanged.

![Fluent Reading PDF view with the PDF/Immersion switch, narration controls, page navigation, and processing bar.](docs/images/reader-pdf.png)

## 2. The guided tour

The first time you open a document, a short seven-step tour appears, pointing at each real control
in the window and explaining what it does. You can:

- Click **Next** to move through it step by step.
- Click **Skip** to close it right away.
- Check **"Don't show again"** if you don't want to see it a second time.

If you want to go through it again later, it's always available under **Help → Replay the tour**.

## 3. Two ways to view the same document

At the top of the window there's a **PDF / Immersion** switch (you can also toggle between them
with **⌘⇧I**):

- **PDF Mode** shows the document exactly as it is — with its images, tables, and original layout.
  Useful when you need to see a chart or table while reading.
- **Immersion Mode** strips away everything that isn't the text itself: page numbers, repeated
  headers, footers, decorations. Only the reading remains, in a window built for focus. This is the
  recommended view if what you want is to read without distractions.

You can switch between the two at any time without losing your place.

![Immersion Mode detail with the view switch and an active reading unit highlighted.](docs/images/reader-immersion.png)

### Navigating the document

- The sidebar button (or **⌘⌥L**) shows the detected outline; selecting an entry jumps to its page.
  If no reliable structure exists, the app says so instead of inventing headings.
- In PDF Mode, **← / →** and the arrows beside the page number move between pages.
- Under **⋯ More**, turn the current page left (**⌘[**) or right (**⌘]**). The app prepares that page
  again so reading, OCR, and highlighting use the new orientation.
- In Immersion, double-click a unit to start there. Manual scrolling suspends following; choose
  **Resume automatic following** when you want it back.

## 4. Listening while you read

The playback controls are always visible at the top of the window:

| Button | What it does |
|---|---|
| ▶ / ⏸ (or the spacebar) | Plays or pauses narration |
| ⏮ / ⏭ | Jumps to the previous/next paragraph (or sentence) |
| **⋯ More** menu → rewind 15s / forward 15s | Adjusts audio position without changing paragraph |
| **⋯ More** menu → speed | Choose 0.75×, 1×, 1.25×, 1.5×, or 2× |

While reading aloud, the app highlights the passage being narrated on screen, so you always know
exactly where the reading is.

### Choosing a voice

The first time you press play, the app will ask you to pick and download a voice (this can take a
few minutes, depending on your connection). Once downloaded, it won't ask again — it's ready for all
your future documents. You can change the voice or reading language anytime from
**⋯ More → Voice**.

The **Voice** sheet lets you choose the models folder, inspect source/license details, download,
cancel or retry, and select a language and voice after verification. If narration fails on a
passage, **⋯ More** offers **Retry this passage** and **Skip this passage**; skipping never deletes
text or changes the PDF.

## 5. Translating a document

From **⋯ More → Translate**, choose the models folder, download and verify the model if needed,
select the target language, and press **Start translation**. Downloads and translation can be
cancelled and retried. Available directions are between Spanish, English, and Portuguese.

The top **Text: Original / Translation** switch appears only after translation has started or a
translation already exists. It works in both PDF and Immersion and changes the visible text and
narration source together without losing the current unit. Before then it doesn't occupy toolbar
space. To hear the translation, install a voice for the target language too.

## 6. Exporting an audiobook

If you'd rather listen outside the app, go to **⋯ More → Export**. The sheet states whether it will
export Original or Translation and lets you choose the name, language, voice, and destination.
Before starting it shows estimated duration and size, available space, ready units, and content that
will be degraded or omitted.

The result is one `.m4b`: it uses chapters when reliable headings are available and one continuous
track otherwise. Export pauses live narration and can be paused, resumed, cancelled, restarted, or
retried from its verified checkpoint, including after reopening the app. When complete, open it or
reveal it in Finder; the app never overwrites an existing file or changes the PDF.

The generated audiobook is your output file: the program's license does not extend to it. You may
use or share it while respecting the rights in the source document.

## 7. Changing the interface language

Go to **Settings** (**⌘,**) and choose Spanish, English, or Portuguese — or let the app follow your
system's language. The app's own name also changes with the language you pick: *Lectura Fluida*,
*Fluent Reading*, or *Leitura Fluída*.

If changing the language requires restarting the app, you'll be told clearly and can choose to do it
right away or later. After restarting, the open document, page, reading unit, preferences, and any
active narration are restored.

## 8. Other useful settings

- **Reading unit** (Immersion only): paragraph or sentence.
- **Theme** (Immersion only): paper, sepia, or dark.
- **Storage**: shows processed data for the open document and can remove it without touching the PDF
  or completed audiobooks.
- **Fluent Reading Help**: explains use, limits, and privacy. **Help → Replay the tour** starts the
  guided tour again.
- **About Fluent Reading** (application menu): shows version, build, installed models, authorship,
  provenance, licenses, and the bundled `NOTICE`.

## Control map

| Location | Control | Function and availability |
|---|---|---|
| Toolbar | Outline | Shows or hides structural navigation. |
| Toolbar | PDF / Immersion | Changes representation while preserving position. |
| Toolbar | Previous · Play/Pause · Next | Controls the narrated reading unit. |
| Toolbar, PDF | Previous page · number · next page | Navigates pages. |
| Toolbar, after translation starts | Text: Original / Translation | Changes text and narration in both views. |
| Toolbar | ⋯ More | Opens a document, switches view, rotates, manages storage, voice, translation, export, unit, theme, following, ±15 s, speed, and state-specific recovery actions. |
| Reading menu | Equivalents of ⋯ More | Gives keyboard and VoiceOver access to processing, voice, translation, export, storage, narration, unit, theme, and following. |
| Processing bar | Progress · Page details · Cancel/Resume | Monitors and controls extraction, layout, and OCR. |
| Sheets | Voice · Translation · Export · Storage · Help | Configures or inspects each flow without hiding the document. |
| Settings (⌘,) | Interface language | Follows the system or fixes English, Spanish, or Portuguese. |

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘O | Open a document |
| ⌘⇧I | Switch between PDF Mode and Immersion Mode |
| Space | Play / pause narration |
| ← / → | Previous / next page (in PDF Mode) |
| ⌥← / ⌥→ | Back / forward 15 seconds |
| ⌘⌥L | Show or hide the navigation outline |
| ⌘[ / ⌘] | Turn the current page left / right |
| ⌘⇧V | Open Voice |
| ⌘⌥T | Open Translation |
| ⌘⇧E | Open Export audio |
| ⌘⌥S | Open Storage |
| ⌘⇧R / ⌘⇧T | Resume / retry processing |
| ⌘⇧F | Resume automatic following (Immersion) |
| ⌘, | Open Settings |
| ⌘? | Open help |
| Esc | Cancel processing in progress |

## Frequently asked questions

**Does the app send my document anywhere online?**
No, never. All text recognition, voice, and translation happen inside your own computer. The only
connection used is to download the models the first time.

**I opened a scanned document and it's taking a while to be ready. Is that normal?**
Yes — if the PDF doesn't have selectable text, the app needs to recognize it first (OCR). You can
start reading the first page as soon as it appears; the rest keeps processing in the background.

**Narration stopped with an error notice. What do I do?**
The **⋯ More** menu offers a button to retry that part, or to skip it and keep going.

**Can I use the app without a mouse, just the keyboard?**
Yes — every main control has a keyboard shortcut (see the table above), and the app works with
VoiceOver.

**Where are the voice and translation models stored?**
Wherever you choose — your Mac or an external drive. The app never forces a fixed folder.

**I chose a folder and see “Voice engine not found.” What should I do?**
Open **⋯ More → Voice → Choose model folder…** and select the folder where the app downloaded the
verified model. Choosing a folder with only loose weight files, or moving only part of the model,
breaks the set; download it again from the same sheet if needed.
