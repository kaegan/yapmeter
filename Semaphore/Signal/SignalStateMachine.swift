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

    mutating func aspect(
        meetingActive: Bool,
        nearSpeaking: Bool,
        farSpeaking: Bool,
        now: Date = Date()
    ) -> Aspect {
        guard meetingActive else {
            farEndFellSilentAt = nil
            return .dark
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
