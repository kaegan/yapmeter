# Semaphore

A macOS menubar app that watches the audio your meeting app is playing and
shows you, as a railway block signal, whether it's safe to speak:

- **Red (occupied)** — the other person is talking.
- **Yellow (caution)**, then **double yellow (preliminary)** — they've
  paused; the block is clearing.
- **Green (clear)** — they've stopped. Go.

It works by tapping the *output* audio of your meeting app (Zoom, Chrome/Meet,
Slack huddles) with a CoreAudio process tap, running a lightweight voice
activity detector on it, and driving a small state machine. Nothing is
recorded, transcribed, or leaves your Mac — it only ever looks at whether
there's speech-shaped energy in the signal.

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

The first time it taps a meeting app's audio, macOS will prompt for
**System Audio Recording** permission (Settings → Privacy & Security →
Screen & System Audio Recording).

## Status

Milestone 1: menu bar signal head + popover shell, cycling through all five
aspects on a timer to prove the UI works. Audio capture and real
voice-activity detection land in the next milestones — see the project plan.
