# Semaphore

A macOS menubar app that watches the audio of your meeting and shows you, as a
railway block signal, whether it's safe to speak:

- **Dark** — no meeting. Out of service.
- **Red (occupied)** — the other person is talking.
- **Yellow (caution)**, then **double yellow (preliminary)** — they've
  paused; the block is clearing.
- **Green (clear)** — they've stopped. Go.
- **Blue** — you have the floor, with a running timer for your turn.

The menu bar lamp is the whole display. Clicking it opens a standard menu with
settings only: sensitivity, which glyph the lamp draws, its colours, and Quit.

The glyph and colour choices are a trial from the branding work: eight
drawings (the original lamp, four pets, three railway signals) and three
palettes, so each can be lived with for a day before one is chosen. Every
glyph encodes the state in its shape as well as its colour.

It taps the *output* audio of your meeting app (Zoom, Chrome/Meet, Slack
huddles) with a CoreAudio process tap for the far end, and the microphone for
you, runs a voice activity detector over each, and drives a small state
machine. Nothing is recorded, transcribed, or leaves your Mac — it only ever
looks at whether there's speech-shaped energy in the signal.

## Meeting detection

The app starts and stops itself. It polls CoreAudio's process list every two
seconds and treats a meeting app **with the microphone open** as a live call —
output alone isn't enough, or a Chrome tab playing a video would count. Output
is the fallback when no process reports input, which covers a Zoom lobby. When
the meeting ends both capture paths are torn down, so the app isn't holding an
aggregate audio device or the mic open all day.

## Voice detection and noise

There's no fixed dB threshold: rooms vary by tens of dB, so anything low enough
to catch quiet speech in a silent room latches on permanently in a loud one.
Instead the detector tracks the room's own noise floor (fast to fall, slow to
rise) and looks for energy a margin above it, requires 150ms before believing
an onset (which rejects keyboard clicks), and holds for 700ms after (which
stops it flickering between words). Steady noise — fans, aircon — raises the
floor and gets absorbed. The menu's **Sensitivity** setting moves that margin
for rooms the default doesn't suit.

One known limitation: macOS exposes no per-app mute state, so if you're muted
in Zoom and talking anyway, the turn timer still runs.

## Requirements

- macOS 14.2+ (needs the CoreAudio process-tap API)
- Xcode 15.1+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build & run

```bash
./scripts/build.sh          # Debug build, installs to ~/Applications, launches it
./scripts/build.sh Release  # Release build
```

Or open in Xcode: `xcodegen generate && open Semaphore.xcodeproj`, then ⌘R.

## Permissions

Two prompts, both on the first meeting the app sees:

- **System Audio Recording** (Settings → Privacy & Security → Screen & System
  Audio Recording) to hear the far end.
- **Microphone** to hear you. Refusing this leaves the signal working and
  disables the turn timer.

## Status

Milestone 3: automatic meeting detection, voice activity detection on both
ends, the signal state machine, and the turn timer. The dwell time before the
block reads clear is fixed at 1.2s; learning it per-conversation is next.
