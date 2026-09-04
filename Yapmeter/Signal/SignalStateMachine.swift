import Foundation

/// Maps voice activity on both ends of the call onto a block-signal aspect.
///
/// Pure and time-injectable so the whole signalling policy is testable without
/// audio hardware: everything it knows arrives through `aspect(...)`.
struct SignalStateMachine {
    /// How long the far end must stay quiet before the block reads clear.
    /// Fixed for now; learning it per-conversation (some people pause for
    /// breath far longer than others) is a later milestone.
    var dwell: TimeInterval = 1.2

    private var farEndFellSilentAt: Date?

    /// `hearingFarEnd` is the fail-safe input. A capture path that has died
    /// reports the same low levels as a quiet room, and a quiet room is what
    /// this machine turns into a green *clear to speak*. Confidently telling
    /// someone to talk over a colleague because the tap fell over is the worst
    /// thing the app can do, so when we can't hear the far end the block
    /// reports nothing at all rather than guessing.
    mutating func aspect(
        meetingActive: Bool,
        hearingFarEnd: Bool = true,
        nearSpeaking: Bool,
        farSpeaking: Bool,
        now: Date = Date()
    ) -> Aspect {
        guard meetingActive else {
            farEndFellSilentAt = nil
            return .dark
        }

        // Your own turn is measured on the microphone, independently of the
        // far end, so it survives the far end going dark.
        guard hearingFarEnd else {
            farEndFellSilentAt = nil
            return nearSpeaking ? .speaking : .dark
        }

        if farSpeaking {
            farEndFellSilentAt = nil
        } else if farEndFellSilentAt == nil {
            farEndFellSilentAt = now
        }

        // You holding the floor outranks the block state. If you're already
        // talking, what you need to know is how long for, not whether to start.
        if nearSpeaking { return .speaking }
        if farSpeaking { return .occupied }

        let silence = now.timeIntervalSince(farEndFellSilentAt ?? now)
        if silence >= dwell { return .clear }
        if silence >= dwell / 2 { return .preliminary }
        return .caution
    }
}
