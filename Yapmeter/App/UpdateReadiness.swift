import Foundation

/// Whether now is a safe moment to let a staged update replace the app out
/// from under the user: never during a meeting (boundary 6), and not for a
/// settling stretch after one ends, since back-to-back calls are ordinary
/// and a relaunch in the gap between them could clip the start of the next.
///
/// Pure and time-injected, like `TurnClock` and `SignalStateMachine`: no
/// notion of Sparkle or timers of its own, just a function of what it's told
/// and when. `Updater` is the only caller, and owns the timer that re-asks it.
enum UpdateReadiness {
    /// How long after a meeting ends before an install is allowed.
    static let settleInterval: TimeInterval = 60

    static func mayInstall(meetingActive: Bool, lastMeetingEndedAt: Date?, now: Date) -> Bool {
        guard !meetingActive else { return false }
        guard let lastMeetingEndedAt else { return true }
        return now.timeIntervalSince(lastMeetingEndedAt) >= settleInterval
    }
}
