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
///   It is frozen while we believe speech is present, so a long turn can't
///   drag the floor up into its own level and mute itself;
/// - speech must hold above `onsetMargin` for `minimumOnset` before it counts,
///   which rejects impulsive noise (a keyboard, a door, a mug on a desk);
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
    /// How long the level must hold above `onsetMargin` before we believe it.
    var minimumOnset: TimeInterval
    /// How long we keep saying "speaking" after the level falls away.
    var hangover: TimeInterval
    /// Nothing below this is ever speech, however far above the noise floor it
    /// sits. In a near-silent room the floor bottoms out around -75 dBFS, and
    /// without this gate a -60 dBFS hum would clear a 12 dB margin easily.
    var absoluteGate: Float

    private(set) var isSpeaking = false
    private(set) var noiseFloor: Float

    private var aboveSince: Date?
    private var belowSince: Date?
    private var lastUpdate: Date?

    /// Time constants for the noise floor tracker, in seconds.
    private let fallTau: TimeInterval = 0.2
    private let riseTau: TimeInterval = 8.0
    /// The floor is clamped into this range: below it there is nothing to
    /// measure, above it we'd be treating speech as background.
    private let floorRange: ClosedRange<Float> = (-75)...(-30)

    init(
        sensitivity: Sensitivity = .normal,
        releaseMargin: Float = 6,
        minimumOnset: TimeInterval = 0.15,
        hangover: TimeInterval = 0.7,
        absoluteGate: Float = -50
    ) {
        self.onsetMargin = sensitivity.onsetMargin
        self.releaseMargin = releaseMargin
        self.minimumOnset = minimumOnset
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

        trackNoiseFloor(dBFS: dBFS, elapsed: elapsed)

        let margin = isSpeaking ? releaseMargin : onsetMargin
        let isLoud = dBFS > absoluteGate && dBFS > noiseFloor + margin

        if isLoud {
            belowSince = nil
            if aboveSince == nil { aboveSince = now }
            if !isSpeaking, let since = aboveSince, now.timeIntervalSince(since) >= minimumOnset {
                isSpeaking = true
            }
        } else {
            aboveSince = nil
            if belowSince == nil { belowSince = now }
            if isSpeaking, let since = belowSince, now.timeIntervalSince(since) >= hangover {
                isSpeaking = false
            }
        }

        return isSpeaking
    }

    /// Drop back to silence without waiting out the hangover. Used when the
    /// audio source goes away entirely, where there is no signal left to decay.
    mutating func reset() {
        isSpeaking = false
        aboveSince = nil
        belowSince = nil
        lastUpdate = nil
        noiseFloor = floorRange.upperBound
    }

    /// Exponential tracker with asymmetric time constants: quick to follow the
    /// signal down to a new quiet baseline, slow to follow it up. Frozen while
    /// speech is present so a long turn can't raise the floor to its own level.
    private mutating func trackNoiseFloor(dBFS: Float, elapsed: TimeInterval) {
        guard elapsed > 0 else { return }
        let falling = dBFS < noiseFloor
        if isSpeaking && !falling { return }
        let tau = falling ? fallTau : riseTau
        let alpha = Float(1 - exp(-elapsed / tau))
        noiseFloor += (dBFS - noiseFloor) * alpha
        noiseFloor = min(max(noiseFloor, floorRange.lowerBound), floorRange.upperBound)
    }
}
