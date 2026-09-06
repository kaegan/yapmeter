import Foundation

/// Turns a stream of RMS levels into a speaking / not-speaking decision.
///
/// A fixed dB threshold doesn't work. A laptop fan, HVAC, or a busy cafe sits
/// at a level that varies by tens of dB between rooms, so any threshold low
/// enough to catch quiet speech in a silent room latches on permanently in a
/// loud one. We track the room's own noise floor instead and look for energy a
/// fixed margin *above* it.
///
/// Three mechanisms keep steady noise and transients out:
///
/// - the noise floor falls fast and rises slowly, so it settles on the quiet
///   parts of the signal and absorbs steady broadband noise (fans, aircon).
///   It follows the quietest level of the last couple of seconds rather
///   than the current one, whether or not speech is present: speech has
///   gaps between words that hold that minimum at the room level, so a
///   long turn can't drag the floor up into its own level and mute itself,
///   while a steady noise has no gaps, so the floor climbs to meet it and
///   the detector lets go;
/// - loudness above `onsetMargin` has to accumulate for `onsetEvidence`
///   seconds before it counts as speech, which rejects transients (a cough,
///   a door, a mug on a desk) regardless of how loud they are. The evidence
///   leaks away during quiet stretches rather than resetting outright, so
///   speech with brief gaps (between words, between syllables) still
///   accumulates toward the threshold instead of starting over each time;
/// - once speaking, it takes the lower `releaseMargin` plus a `hangover` of
///   quiet to drop out, so the decision doesn't flicker between words.
///
/// The same detector runs on both ends of the call: the far end via the
/// process tap, the near end via the microphone.
struct VoiceActivityDetector {
    /// How readily the detector calls something speech. Exposed in the menu
    /// because rooms differ by more than any single default can cover.
    enum Sensitivity: String, CaseIterable, Sendable {
        /// Noisy room. Needs a clear voice to trigger.
        case low
        case normal
        /// Quiet room, quiet talker. Catches more, false-positives more.
        case high

        /// Menu item labels. The parentheticals are the only hint the user
        /// gets, so they say when to pick each one.
        var displayName: String {
            switch self {
            case .low: return "Low (noisy room)"
            case .normal: return "Normal"
            case .high: return "High (quiet room)"
            }
        }

        /// dB above the noise floor required to *start* calling it speech.
        var onsetMargin: Float {
            switch self {
            case .high: return 8
            case .normal: return 12
            case .low: return 18
            }
        }
    }

    /// dB above the noise floor required to start calling it speech.
    var onsetMargin: Float
    /// dB above the noise floor required to keep calling it speech. Lower than
    /// `onsetMargin`: this hysteresis is what stops the decision chattering.
    var releaseMargin: Float
    /// How many seconds of accumulated loudness confirm speech. Fixed rather
    /// than tied to `Sensitivity`: sensitivity is a level margin for the room,
    /// this is a statement about what a sustained voice looks like in time,
    /// which doesn't change with the room.
    var onsetEvidence: TimeInterval
    /// The accumulator never carries more evidence than this. Keeping it
    /// modest (rather than, say, minutes of headroom) means a burst of
    /// transients can't "pre-charge" an instant confirmation later; keeping
    /// it above `onsetEvidence` means a resumption shortly after release
    /// still has some residual credit and confirms a little faster than a
    /// cold start.
    var evidenceCap: TimeInterval
    /// How long we keep saying "speaking" after the level falls away.
    var hangover: TimeInterval
    /// Nothing below this is ever speech, however far above the noise floor it
    /// sits. In a near-silent room the floor bottoms out around -75 dBFS, and
    /// without this gate a -60 dBFS hum would clear a 12 dB margin easily.
    var absoluteGate: Float

    private(set) var isSpeaking = false
    private(set) var noiseFloor: Float
    /// When the detector last confirmed speech, this is when the sound that
    /// earned that confirmation actually started - not the (later) moment
    /// enough evidence had accumulated to believe it. Nil whenever
    /// `isSpeaking` is false. This is the back-dated timestamp a turn timer
    /// should use instead of "now".
    private(set) var speechStartedAt: Date?

    /// Seconds of accumulated loudness, in `0...evidenceCap`. Rises while
    /// loud, decays while quiet; speech confirms once it reaches
    /// `onsetEvidence`. Exposed read-only for the debug log, to help tune
    /// `onsetEvidence` and `absoluteGate` against a real room.
    private(set) var evidence: TimeInterval = 0
    /// When the current unbroken run of evidence-building began - i.e. the
    /// real onset of whatever sound is currently pushing `evidence` up. Nil
    /// whenever `evidence` is zero.
    ///
    /// Known tradeoff: this only resets when `evidence` fully decays to zero,
    /// not on every quiet sample. That's what lets speech survive brief gaps
    /// without losing its credited start, but it also means two unrelated
    /// transients close enough together (a cough, then a keystroke a moment
    /// later, then real speech) can chain into one candidate and back-date
    /// the confirmed turn to the first of them. The overcount is bounded by
    /// how long it takes evidence to drain between transients, and the turn
    /// still can't confirm on the transients alone - only real speech can
    /// push it over `onsetEvidence` - so this trades a small, rare timing
    /// error for the gap-tolerance the design is built around.
    private var candidateStartedAt: Date?
    private var belowSince: Date?
    private var lastUpdate: Date?

    /// Time constants for the noise floor tracker, in seconds.
    private let fallTau: TimeInterval = 0.2
    private let riseTau: TimeInterval = 8.0
    /// How far back the floor tracker looks for the quietest level. Long
    /// enough that ordinary speech always has an inter-word gap inside it,
    /// short enough that a noise which starts mid-call is absorbed within
    /// seconds: the floor rises toward a 20 dB step in about 12 s (2 s for
    /// the old quiet to leave the window, then 8 s of `riseTau` to cover
    /// enough of the gap to release). Speech with no 100 ms dip at all for
    /// this long plus about 14 s would start to mute itself; nobody talks
    /// that long without a breath.
    private let floorWindow: TimeInterval = 2.0
    /// Levels seen inside `floorWindow`, oldest first. Bounded by the tick
    /// rate: about a hundred entries at 50 Hz.
    private var recentLevels: [(at: Date, dBFS: Float)] = []
    /// The floor is clamped into this range: below it there is nothing to
    /// measure, above it we'd be treating speech as background.
    private let floorRange: ClosedRange<Float> = (-75)...(-30)

    init(
        sensitivity: Sensitivity = .normal,
        releaseMargin: Float = 6,
        onsetEvidence: TimeInterval = 0.6,
        hangover: TimeInterval = 0.7,
        absoluteGate: Float = -50
    ) {
        self.onsetMargin = sensitivity.onsetMargin
        self.releaseMargin = releaseMargin
        self.onsetEvidence = onsetEvidence
        self.evidenceCap = onsetEvidence * 2
        self.hangover = hangover
        self.absoluteGate = absoluteGate
        // Start pessimistic, at the top of the range. The tracker falls fast
        // and rises slowly, so a quiet room is found within about a second,
        // whereas starting at the bottom means several seconds during which
        // the floor is still climbing and any steady noise clears the margin
        // and latches on. Assume noisy until the room proves otherwise.
        self.noiseFloor = floorRange.upperBound
    }

    mutating func apply(sensitivity: Sensitivity) {
        onsetMargin = sensitivity.onsetMargin
    }

    /// Feed one level measurement and get back the current decision. Expects to
    /// be called steadily (the app runs it at 50 Hz); the noise floor uses the
    /// real elapsed time between calls, so an irregular rate is survivable.
    @discardableResult
    mutating func update(dBFS: Float, now: Date = Date()) -> Bool {
        let elapsed = lastUpdate.map { now.timeIntervalSince($0) } ?? 0
        lastUpdate = now

        recentLevels.append((at: now, dBFS: dBFS))
        while let oldest = recentLevels.first, now.timeIntervalSince(oldest.at) > floorWindow {
            recentLevels.removeFirst()
        }
        trackNoiseFloor(elapsed: elapsed)

        let margin = isSpeaking ? releaseMargin : onsetMargin
        let isLoud = dBFS > absoluteGate && dBFS > noiseFloor + margin
        // Clamp: after a stalled run loop or a wake from sleep, `elapsed`
        // could be seconds long, and a single loud sample must not be able to
        // confirm speech outright just because the app was asleep.
        let dt = min(elapsed, 0.1)

        if isLoud {
            belowSince = nil
            if evidence == 0 { candidateStartedAt = now }
            evidence = min(evidence + dt, evidenceCap)
            if !isSpeaking, evidence >= onsetEvidence {
                isSpeaking = true
                speechStartedAt = candidateStartedAt ?? now
            }
        } else {
            if belowSince == nil { belowSince = now }
            if isSpeaking, let since = belowSince, now.timeIntervalSince(since) >= hangover {
                isSpeaking = false
                speechStartedAt = nil
            }
            evidence = max(evidence - dt, 0)
            if evidence == 0 { candidateStartedAt = nil }
        }

        return isSpeaking
    }

    /// Drop back to silence without waiting out the hangover. Used when the
    /// audio source goes away entirely, where there is no signal left to decay.
    mutating func reset() {
        isSpeaking = false
        speechStartedAt = nil
        evidence = 0
        candidateStartedAt = nil
        belowSince = nil
        lastUpdate = nil
        recentLevels.removeAll()
        noiseFloor = floorRange.upperBound
    }

    /// Exponential tracker with asymmetric time constants: quick to follow the
    /// signal down to a new quiet baseline, slow to follow it up. The target
    /// is the quietest level inside `floorWindow`, not the latest one, and
    /// the tracker runs whether or not speech is present.
    ///
    /// This used to freeze while speaking so a long turn couldn't raise the
    /// floor to its own level. Freezing had a failure with no way out: if
    /// the floor was wrong-low at the moment speech confirmed (the mic's
    /// zero-filled startup buffers, or a dryer starting after the room had
    /// been quiet), it stayed wrong, and release - which is measured against
    /// the floor - could never happen (YB-50). Tracking the window minimum
    /// gives the same protection for real speech, which always dips to the
    /// room level between words, while letting a floor that is simply wrong
    /// correct itself.
    private mutating func trackNoiseFloor(elapsed: TimeInterval) {
        guard elapsed > 0, let target = recentLevels.lazy.map(\.dBFS).min() else { return }
        let falling = target < noiseFloor
        let tau = falling ? fallTau : riseTau
        let alpha = Float(1 - exp(-elapsed / tau))
        noiseFloor += (target - noiseFloor) * alpha
        noiseFloor = min(max(noiseFloor, floorRange.lowerBound), floorRange.upperBound)
    }
}
