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

## Constitution

[CONSTITUTION.md](CONSTITUTION.md) is the one page every feature has to fit on:
what the app measures and refuses to measure, the privacy promises, and how
Yap talks. Read it before proposing anything new.

## Meeting detection

The app starts and stops itself. It polls CoreAudio's process list every two
seconds and treats a meeting app **with the microphone open** as a live call —
output alone isn't enough, or a Chrome tab playing a video would count. Output
is the fallback when no process reports input, which covers a Zoom lobby. When
the meeting ends both capture paths are torn down, so the app isn't holding an
aggregate audio device or the mic open all day.

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

## Updates

Shipped builds update themselves through [Sparkle](https://sparkle-project.org).
The app checks `https://yapmeter.com/appcast.xml` once a day and on demand from
**Check for Updates…** in the menu; the feed serves whatever the newest GitHub
release published. Every archive is signed with an EdDSA key that never leaves
the release machine, and Sparkle refuses anything the key in `Info.plist`
doesn't verify.

This is the one thing the app sends off the Mac, and it sends only what an
HTTPS request carries: the current version, in the User-Agent. No audio, no
meeting data. Turning the automatic check off in Sparkle's dialog leaves the
manual one working.

## Releasing

One-time setup, in this order:

1. **Signing key.** Run Sparkle's `generate_keys` once. It puts the private key
   in your login keychain and prints the public one; paste that into
   `SUPublicEDKey` in `Yapmeter/Info.plist`, replacing the placeholder. The
   release workflow refuses to build while the placeholder is still there,
   because an update signed against a key nobody holds is an app that can never
   be updated again. Export the private key with `generate_keys -x` for the CI
   secret, and keep a copy somewhere you'd still have it after a disk failure —
   losing it means every existing install is stranded on its current version.

   ```bash
   ./build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
   ```

2. **Repository secrets.** `CERTIFICATE_P12_BASE64` (a Developer ID Application
   certificate exported as .p12, then `base64 -i cert.p12`),
   `CERTIFICATE_P12_PASSWORD`, `APPLE_TEAM_ID`, `APPLE_ID`,
   `APPLE_APP_SPECIFIC_PASSWORD` (from appleid.apple.com, not your account
   password), and `SPARKLE_PRIVATE_KEY`. The workflow checks all six are
   non-empty before it builds anything: `gh secret set NAME < missing-file`
   stores an empty string and still prints a tick, and an empty one otherwise
   surfaces as a 401 from the notary a quarter of an hour in.

3. **The feed.** `yapmeter.com/appcast.xml` rewrites to the appcast attached to
   the newest GitHub release, so the URL baked into every shipped binary is one
   we own. That URL can never change: an old build only ever asks the address
   it was compiled with. The download button on the site wants
   `https://github.com/kaegan/yapmeter/releases/latest/download/Yapmeter.zip`,
   which is why the archive is named without its version.

Then each release is a tag:

```bash
git tag v0.2.0 && git push origin v0.2.0
```

The workflow tests, archives, signs, notarizes, staples, checks the result
against Gatekeeper, signs the archive for Sparkle, and rewrites the appcast
from the live feed plus the new item. The marketing version comes from the tag
and the build number from `git rev-list --count HEAD`, so `CFBundleVersion`
always increases — Sparkle compares that number and nothing else, and one
release that repeats it leaves those users unable to update.

## Status

Milestone 3: automatic meeting detection, voice activity detection on both
ends, the signal state machine, and the turn timer. The dwell time before the
block reads clear is fixed at 1.2s; learning it per-conversation is next.
