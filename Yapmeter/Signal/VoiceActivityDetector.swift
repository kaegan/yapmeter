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
/// - the noise floor is the quietest half-second of the last ten seconds
///   (minimum statistics, the standard in speech enhancement). Speech always
///   has dips between sentences and steady noise never does, so the minimum
///   finds the room under a talker and finds the hum under a hum. A long turn
///   can't drag the floor up into its own level, and a steady sound raises
///   the floor to itself within one window and stops reading as speech. The
///   floor is never frozen: an earlier version froze it while speech was
///   present, which made any latch permanent (YB-47);
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
    /// The room's level: `windowMinimum` smoothed so it moves rather than
    /// steps, and clamped into `floorRange`.
    private(set) var noiseFloor: Float
    /// The quietest level seen in any half-second slot of the last ten
    /// seconds, before smoothing. Exposed read-only for the debug log: when
    /// the floor sits somewhere surprising, this says whether the window
    /// found a dip or the room really is that loud.
    private(set) var windowMinimum: Float
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

    /// The minimum-statistics window: the last `slotCount` slots of
    /// `slotLength` seconds each, as a ring indexed by absolute slot number.
    /// Ten seconds is longer than a talker goes without a pause between
    /// sentences, so the window always holds a dip during a turn, and short
    /// enough that a new steady noise is absorbed before the release margin
    /// has time to matter. An empty slot holds `.infinity` and never wins
    /// the minimum.
    private let slotLength: TimeInterval = 0.5
    private let slotCount = 20
    private var slotMinimums: [Float]
    /// Absolute number (seconds since 1970 divided by `slotLength`) of the
    /// slot the last sample landed in, so a stalled run loop or a wake from
    /// sleep clears every slot that aged out in between instead of leaving
    /// stale minimums in the ring.
    private var currentSlot: Int64?

    /// Time constants for smoothing the window minimum into the floor, in
    /// seconds. Falling is fast so a room that goes quiet is found at once;
    /// rising is only a little slower, enough to round the half-second steps
    /// off. The old slow rise is no longer needed, the window itself is what
    /// keeps speech from lifting the floor.
    private let fallTau: TimeInterval = 0.2
    private let riseTau: TimeInterval = 0.5
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
        // Start pessimistic, at the top of the range. The floor falls fast,
        // so a quiet room is found within about a second, whereas starting
        // at the bottom means a stretch during which any steady noise clears
        // the margin and latches on. Assume noisy until the room proves
        // otherwise.
        self.noiseFloor = floorRange.upperBound
        self.windowMinimum = floorRange.upperBound
        self.slotMinimums = Array(repeating: .infinity, count: slotCount)
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

        trackNoiseFloor(dBFS: dBFS, now: now, elapsed: elapsed)

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
        noiseFloor = floorRange.upperBound
        windowMinimum = floorRange.upperBound
        slotMinimums = Array(repeating: .infinity, count: slotCount)
        currentSlot = nil
    }

    /// Record the sample in its slot, take the minimum across the window, and
    /// smooth that into the floor with asymmetric time constants.
    private mutating func trackNoiseFloor(dBFS: Float, now: Date, elapsed: TimeInterval) {
        let slot = Int64((now.timeIntervalSince1970 / slotLength).rounded(.down))
        if let current = currentSlot, slot > current {
            // Every slot between the last sample and this one has aged out.
            // Past a full window there is nothing left to keep.
            let advanced = min(Int(clamping: slot - current), slotCount)
            for step in 1...advanced {
                slotMinimums[ringIndex(current + Int64(step))] = .infinity
            }
        }
        currentSlot = slot
        let index = ringIndex(slot)
        slotMinimums[index] = min(slotMinimums[index], dBFS)
        windowMinimum = clamp(slotMinimums.min() ?? dBFS)

        guard elapsed > 0 else { return }
        let falling = windowMinimum < noiseFloor
        let tau = falling ? fallTau : riseTau
        let alpha = Float(1 - exp(-elapsed / tau))
        noiseFloor = clamp(noiseFloor + (windowMinimum - noiseFloor) * alpha)
    }

    private func ringIndex(_ slot: Int64) -> Int {
        let remainder = Int(slot % Int64(slotCount))
        return remainder < 0 ? remainder + slotCount : remainder
    }

    private func clamp(_ level: Float) -> Float {
        min(max(level, floorRange.lowerBound), floorRange.upperBound)
    }
}
