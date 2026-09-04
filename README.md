# Semaphore

A macOS menubar app that watches the audio your meeting app is playing and
shows you, as a railway block signal, whether it's safe to speak:

- **Red (occupied)** — the other person is talking.
- **Yellow (caution)**, then **double yellow (preliminary)** — they've
  paused; the block is clearing.
- **Green (clear)** — they've stopped. Go.

It works by tapping the *output* audio of your meeting app (Zoom, Chrome/Meet,
Slack huddles, Teams) with a CoreAudio process tap, running a lightweight voice
activity detector on it, and driving a small state machine. Nothing is
recorded, transcribed, or leaves your Mac — it only ever looks at whether
there's speech-shaped energy in the signal.

It arms itself: no calendar, no integrations. CoreAudio publishes a
process object per audio client, and Semaphore watches
`kAudioProcessPropertyIsRunningInput` on the ones belonging to a known
meeting app. A meeting app holding the microphone open *is* the meeting —
Chrome playing YouTube has output but no input, and Chrome sitting idle has
neither. Both edges are debounced (2s to arm, 12s of grace to disarm) so a
device switch mid-call doesn't drop the signal.

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

Milestones 1–2 plus meeting detection: menu bar signal head + popover shell
(still cycling aspects on a demo timer), a CoreAudio process tap with a live
dBFS readout, and automatic arming when a meeting starts. Real
voice-activity detection and the signal state machine land next — see the
project plan.
