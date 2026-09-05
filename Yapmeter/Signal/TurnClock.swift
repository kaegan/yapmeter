import Foundation

/// Turns a stream of speaking / not-speaking decisions into the seconds shown
/// on the menu bar, back-dated to when the speech actually started rather
/// than when the detector finished confirming it - the way an Apple Watch
/// workout back-credits the minute you actually started walking, once it's
/// sure that's what you were doing.
///
/// Pure and time-injected, like `SignalStateMachine`: no timers of its own,
/// just a function of what it's told and when.
struct TurnClock {
    /// A turn survives a pause up to this long before it's considered over.
    /// Longer than the detector's hangover on purpose: pausing for breath
    /// mid-sentence shouldn't reset the clock, but a genuine handover should.
    ///
    /// A turn can only be resumed within this window if the detector feeding
    /// it releases evidence faster than the window is long - concretely,
    /// `VoiceActivityDetector.evidenceCap` must stay below `endGap`, or a
    /// stale candidate could let a genuinely new turn absorb time from one
    /// that already ended. Both current detectors (0.6s and 0.25s onset, so
    /// 1.2s and 0.5s caps) clear that bar comfortably against the 2s default.
    var endGap: TimeInterval = 2.0

    /// When the current turn began, or nil if no turn is running. Once set,
    /// this is deliberately *not* cleared the moment speech pauses - only
    /// `update`'s return value hides it from the display while the pause is
    /// within `endGap`. That's what lets a resumption inside the gap
    /// reconnect to the original start without a separate "ended turn" record.
    private(set) var startedAt: Date?
    /// The last tick at which speech was confirmed. Compared against `now`
    /// (to decide whether the pause has become a real end) and against a new
    /// turn's back-dated onset (to decide whether it's really a resumption).
    private var lastSpeechAt: Date?

    /// Feed the current speaking decision and get back the seconds to show,
    /// or nil if no turn is running.
    ///
    /// - Parameters:
    ///   - speaking: whether the near end is speaking right now.
    ///   - speechStartedAt: when that speech actually began, per the
    ///     detector's back-dated onset. Falls back to `now` if unavailable.
    ///   - now: the current tick's timestamp.
    mutating func update(speaking: Bool, speechStartedAt: Date?, now: Date) -> Int? {
        if speaking {
            let onset = speechStartedAt ?? now
            if startedAt == nil {
                startedAt = onset
            } else if let last = lastSpeechAt, isResumption(onset: onset, after: last) == false {
                // The gap since the last confirmed speech is real, and this
                // onset falls on the far side of it: not a resumption, a new
                // turn. (A resumption inside the gap needs nothing special
                // here - `startedAt` was never cleared, so it's already
                // correct.)
                startedAt = onset
            }
            lastSpeechAt = now
        } else if let last = lastSpeechAt, now.timeIntervalSince(last) > endGap {
            // The turn is over for display purposes, but `startedAt` and
            // `lastSpeechAt` are left in place: if speech resumes within
            // `endGap` of `last`, that's what lets it reconnect below.
            return nil
        }

        return startedAt.map { Int(now.timeIntervalSince($0)) }
    }

    /// Whether `onset` falls close enough after `last` to count as resuming
    /// the same turn rather than starting a new one. Guards both directions:
    /// too far after is a real gap, and at or before `last` (which shouldn't
    /// happen - onsets aren't retroactive past speech already confirmed, but
    /// nothing enforces that across files) is never treated as a resumption.
    private func isResumption(onset: Date, after last: Date) -> Bool {
        let gap = onset.timeIntervalSince(last)
        return gap > 0 && gap <= endGap
    }

    /// Forget everything. Used when the audio source goes away entirely, so
    /// a meeting that ends and restarts doesn't resurrect an old turn.
    mutating func reset() {
        startedAt = nil
        lastSpeechAt = nil
    }
}
