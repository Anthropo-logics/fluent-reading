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
The app automatically remembers your page and scroll position, so the next time you open that same
document you pick up right where you left off.

If the PDF is a scan (photos of pages, not selectable text), Fluent Reading recognizes the text
automatically the first time you open it. You'll see a progress bar while it works; you can start
reading the first page as soon as it's ready, without waiting for the whole document to finish.

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

## 5. Translating a document

From **⋯ More → Translate**, you can turn on translation for your document (currently between
Spanish, English, and Portuguese). Just like with voice, the translation model downloads the first
time; after that it works offline.

Once it's on, **⋯ More** shows an **Original / Translation** switch to choose which one you listen
to or read. You can switch between the two at any time without losing your place — Fluent Reading
keeps the original and the translation lined up with each other.

## 6. Exporting an audiobook

If you'd rather listen to the document outside the app (in the car, while walking, without looking
at a screen), go to **⋯ More → Export**. Fluent Reading generates an audio file (`.m4b`) with
chapters, which you can play in any audiobook-compatible player. Exporting can be paused and
resumed, and if you cancel partway through nothing is left half-done — the original document is
never affected.

## 7. Changing the interface language

Go to **Settings** (**⌘,**) and choose Spanish, English, or Portuguese — or let the app follow your
system's language. The app's own name also changes with the language you pick: *Lectura Fluida*,
*Fluent Reading*, or *Leitura Fluída*.

If changing the language requires restarting the app, you'll be told clearly and can choose to do it
right away or later, without losing your saved preferences.

## 8. Other useful settings

All of these live in the **⋯ More** menu, at the top right of the window:

- **Tracking unit**: choose whether reading advances paragraph by paragraph or sentence by
  sentence.
- **Immersion theme**: paper (light), sepia, or dark — for comfortable reading depending on the
  light around you.
- **Storage**: check or free up the space used by documents you've already processed.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘O | Open a document |
| ⌘⇧I | Switch between PDF Mode and Immersion Mode |
| Space | Play / pause narration |
| ← / → | Previous / next page (in PDF Mode) |
| ⌘⌥L | Show or hide the navigation outline |
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
