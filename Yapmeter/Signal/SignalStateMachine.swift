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

    /// How long your own pause is still shown as your turn. A breath or a
    /// moment's thought mid-sentence keeps the pet blue and the count
    /// running; the lamp must not flash green for a pause and nudge you into
    /// filling it. Reads the turn clock's gap so the pet is blue for exactly
    /// as long as the clock has a count to show.
    var nearHold: TimeInterval = TurnClock().endGap

    private var farEndFellSilentAt: Date?
    /// The last tick you were heard speaking, while your hold is still open.
    /// Cleared when the far end takes the floor: the hold ends at once and
    /// does not come back when they stop, because that pause is theirs.
    private var nearEndLastSpokeAt: Date?

    mutating func aspect(
        meetingActive: Bool,
        nearSpeaking: Bool,
        farSpeaking: Bool,
        now: Date = Date()
    ) -> Aspect {
        guard meetingActive else {
            farEndFellSilentAt = nil
            nearEndLastSpokeAt = nil
            return .dark
        }

        if farSpeaking {
            farEndFellSilentAt = nil
        } else if farEndFellSilentAt == nil {
            farEndFellSilentAt = now
        }

        // You holding the floor outranks the block state. If you're already
        // talking, what you need to know is how long for, not whether to start.
        if nearSpeaking {
            nearEndLastSpokeAt = now
            return .speaking
        }
        if farSpeaking {
            nearEndLastSpokeAt = nil
            return .occupied
        }
        if let last = nearEndLastSpokeAt, now.timeIntervalSince(last) <= nearHold {
            return .speaking
        }

        let silence = now.timeIntervalSince(farEndFellSilentAt ?? now)
        if silence >= dwell { return .clear }
        if silence >= dwell / 2 { return .preliminary }
        return .caution
    }
}
