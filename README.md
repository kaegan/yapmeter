# Yapmeter

A macOS menubar app that watches the audio of your meeting and shows you, as a
railway block signal, whether it's safe to speak:

- **Dark** — no meeting. Out of service.
- **Red (occupied)** — the other person is talking.
- **Yellow (caution)**, then **double yellow (preliminary)** — they've
  paused; the block is clearing.
- **Green (clear)** — they've stopped. Go.
- **Blue** — you have the floor, with a running timer for your turn.

The menu bar lamp is the whole display. When there's no meeting it shows a
pair of speech bubbles instead, tinted like the system's own menu bar icons.
Clicking it opens a standard menu: a status line saying what the app is
doing ("Waiting for a meeting", "Listening to Zoom"), then a **Sensitivity**
submenu, a **Listen to All Audio** submenu, **Launch at Login**, a
**Developer** submenu, and Quit.

The Developer submenu holds the branding trial: **Glyph** (eight drawings:
the original lamp, four pets, three railway signals), **Colours** (three
palettes), and **Preview states**, which walks the lamp through the whole
sequence, clock included, so a glyph can be judged without a meeting. The
preview switches itself off when a real meeting starts. Every glyph encodes
the state in its shape as well as its colour, and each draws its own idle
state in the menu bar's label colour; the speech bubbles belong to the Lamp.

It taps the *output* audio of your meeting app (Zoom, Chrome/Meet, Slack
huddles) with a CoreAudio process tap for the far end, and the microphone for
you, runs a voice activity detector over each, and drives a small state
machine. Nothing is recorded, transcribed, or leaves your Mac — it only ever
looks at whether there's speech-shaped energy in the signal.

## Meeting detection

The app starts and stops itself. It polls CoreAudio's process list every two
seconds and treats a meeting app **with the microphone open** as a live call.
For a browser, output alone isn't enough — a Chrome tab playing a video would
otherwise count. For a dedicated meeting app it is, which covers a Zoom lobby.
When the meeting ends both capture paths are torn down, so the app isn't
holding an aggregate audio device or the mic open all day.

That poll is a reconciler, not a one-shot. Starting capture on the moment a
meeting first appears isn't enough to keep it running: the process tap can fail
on the first attempt while the system-audio permission is still being decided,
`AVAudioEngine` stops itself and drops its tap whenever the audio hardware
changes (which a meeting does routinely — joining a call, sharing a screen,
plugging in headphones), and a meeting app that respawns its audio helper
leaves the tap pointed at a process that no longer plays anything. Every poll
asks whether each path *should* be running and whether it is *actually
delivering*, and rebuilds whatever isn't.

Calls the detector can't see (FaceTime is one) can be handled by hand: the
**Listen to All Audio** submenu taps everything the Mac is playing, plus the
mic, for 15, 30, 45 or 60 minutes, or until you switch it off. Music or a
video will drive the signal too while it's on, and it resets when the app
relaunches.

## Voice detection and noise

There's no fixed dB threshold: rooms vary by tens of dB, so anything low enough
to catch quiet speech in a silent room latches on permanently in a loud one.
Instead the detector tracks the room's own noise floor (fast to fall, slow to
rise) and looks for energy a margin above it. Loudness above that margin has
to accumulate for about 600ms before it counts as speech — long enough that a
cough or a keyboard click never confirms, even though each is loud on its own
— and once confirmed, the turn timer is back-dated to when the sound actually
started rather than when the app finished convincing itself. Speech keeps
building that evidence through brief gaps (between words, between syllables)
instead of resetting at the first quiet moment, and holds for 700ms of
silence after release so it doesn't flicker between words. The mic buffer is
also sliced into 10ms pieces and measured by its median rather than its
average, so a single loud keystroke inside an otherwise quiet buffer doesn't
read as sustained sound. Steady noise — fans, aircon — raises the floor and
gets absorbed. The menu's **Sensitivity** setting moves that margin for rooms
the default doesn't suit.

One known limitation: macOS exposes no per-app mute state, so if you're muted
in Zoom and talking anyway, the turn timer still runs.

## Failing safe

Silence and deafness look identical to a level meter — both are just low
numbers — and silence is what the signal turns into a green *clear to speak*.
So a capture path that has died would confidently tell you to talk over
someone. Each path's liveness is tracked separately from its level (a running
IO path reports continuously whether or not there's sound in it), and when the
far end can't be heard the lamp goes **dark** rather than green, with the menu
saying why. Your own turn is measured on the microphone, so the timer keeps
working even when the far end is out.

## Requirements

- macOS 14.2+ (needs the CoreAudio process-tap API)
- Xcode 15.1+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build & run

```bash
./scripts/build.sh          # Debug build, installs to ~/Applications, launches it
./scripts/build.sh Release  # Release build
```

Or open in Xcode: `xcodegen generate && open Yapmeter.xcodeproj`, then ⌘R.

## Permissions

Two prompts, both on the first meeting the app sees:

- **System Audio Recording** (Settings → Privacy & Security → Screen & System
  Audio Recording) to hear the far end.
- **Microphone** to hear you. Refusing this leaves the signal working and
  disables the turn timer.

## Status

Milestone 3: automatic meeting detection, voice activity detection on both
ends, the signal state machine, and the turn timer, plus a pass of hardening on
all three (capture recovery, failing safe, and a detector that no longer latches
on steady noise). The dwell time before the block reads clear is fixed at 1.2s;
learning it per-conversation is next.
