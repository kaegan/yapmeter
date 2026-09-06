# Yapmeter constitution

Yapmeter is a macOS menu bar app that tells you whether it's safe to speak in a
meeting, and how long you've been speaking once you start. It measures **how you
yap**. Everything it does, and every feature added to it, has to fit on this page.

Two people download it: the one who worries they talk too much, and the one who
never finds the gap. Every feature should be able to say which of them it's for.

## Boundaries

These are not preferences. A feature that crosses one is not a Yapmeter feature.

1. **It's about you, not them.** The far end of the call is one bit of
   information: someone is talking, or nobody is. Yapmeter never identifies
   other speakers, counts them, scores them, ranks them, or reports on them.
   "Airtime share" is your share of the room. "Yap clash" is you talking over
   someone. There is no "who dominated the meeting".
2. **Not a transcript tool.** Yapmeter never stores, displays, exports, or syncs
   words. It listens for speech-shaped energy, and asks one yes/no question of
   speech itself: were there words? That question is how the turn timer
   starts, so typing, music and a fan never run it. It is answered by
   on-device speech recognition on **your microphone only**, and the text is
   discarded the moment the yes/no is taken. Recognition standing witness like
   that may report only "there were words, covering audio up to this moment";
   the text itself never leaves the code that receives it, and is never
   logged. A measure that genuinely needs words (filler count, question ratio)
   is held to the same rule: the number is taken and the text is dropped. The
   far end is never transcribed, under any setting.
3. **Nothing leaves the Mac.** The app makes exactly one network request of its
   own: the Sparkle update check, which carries the app version and nothing
   else. That check can be followed by a second request of its own, made
   without asking: Sparkle downloading the signed release archive, which it
   stages on disk until it installs. A third can happen once, on first
   launch, made by macOS rather than by the app: if this Mac has no on-device
   speech model for your language, the system is asked to fetch one. None of
   the three carries anything about you or your meetings. No
   accounts, no login, no cloud sync, no crash reporting, no analytics in the
   app. The website may run anonymous page analytics. Downloading never
   requires an email address. The staged update, and when it's allowed to
   install, are covered under "Never interrupts a meeting" below.
4. **It only listens during a call.** Capture starts when a meeting app opens
   the mic and tears down when the call ends. The app never holds the mic or
   system audio open all day. Manual listening is always on a timer or
   visibly on, and resets on relaunch.
5. **Single-player.** No team plans, shared dashboards, manager views, or
   comparisons between people. Yapmeter is never a tool one person uses to
   measure another.
6. **Never interrupts a meeting.** During a call the menu bar lamp is the entire
   interface. No windows, popovers, sounds, or notifications while a meeting
   is running. Anything that needs more than a glance (the report) arrives
   after the call ends, and can be switched off entirely. A downloaded update
   waits the same way: it never installs during a meeting, or in the minute
   after one ends, so back-to-back calls aren't caught by a relaunch in the
   gap between them.
7. **A new permission, network call, or file on disk is a constitutional
   amendment.** Edit this document first, and update the README, the
   permission prompt strings, and the site's privacy section in the same
   change. The line "Nothing is recorded or sent anywhere" is a promise, not
   copy, and so is every condition attached to it.

## How it should feel

- **The lamp is the product.** It's read at a glance in peripheral vision.
  The menu behind it stays short: a status line and a few set-and-forget
  settings. If a feature needs a settings screen, it's probably too big.
- **Judge gently, and only you.** At four minutes Yap gives you a look. That's
  the ceiling. No streaks, no nagging, no guilt, no "you talked 40% more than
  last week" push notifications.
- **Every number can be explained.** The Yap score is composed from things the
  app measured (airtime, longest turn, clashes, handover latency) and always
  shows what moved it. No opaque scores.
- **Say what it can't see.** Muted-but-talking still runs the clock. Teams and
  Safari aren't detected yet. State limitations plainly, in the product and on
  the site, rather than hiding them.
- **Defaults over settings.** Sensitivity exists because rooms differ. Most
  things should not become a setting; make the default right instead. Waiting
  for words before the timer starts shipped behind a switch and then lost it:
  the behaviour was right for everyone, so it is simply how the app works.
- **Cheap to run.** No background work and no CPU burn between calls. The one
  on-device speech model runs only during a call and is dropped when the call
  ends.

## Voice

There are two registers, and they never mix in one sentence.

**Yap, the pet, is the one who's funny.** Deadpan, short, and self-deprecating:
the joke is always at your expense, never your colleagues'. "Shh. Their turn."
"Yap yap yap. 0:42." "That's a long yap sesh." Self-aware, not try-hard: one
joke per surface, then stop. Yap is "he". The app is "it". The tagline is "Know
when to yap".

**Everything about privacy, permissions, and limitations is plain and literal.**
Short declarative sentences, no jokes within a paragraph of the privacy line,
no softeners ("we take your privacy seriously"), no "AI-powered".

Both registers: plain English in the interface, railway vocabulary stays in the
code. Canadian spelling (colour, favourite). Sentence case for menu items.
Exclamation marks only in Yap's mouth, and rarely there.

## Before shipping a feature

- Which of the two users is it for, in one sentence?
- Can you describe what it measures without the word "transcript"?
- Does it add a permission, a network call, or persistent data? If yes, amend
  this document first (boundary 7).
- Does it put anything on screen during a call other than the lamp?
- Which register is the copy in, and is it one of the two above?
- Is the signal logic pure and time-injected, with a test, like the state
  machine and turn clock already are?
