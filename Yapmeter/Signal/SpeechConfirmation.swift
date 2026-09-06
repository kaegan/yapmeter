import Foundation

/// Holds the energy gate's "you're speaking" decision back until the Mac has
/// actually heard words in it.
///
/// The gate reads speech-shaped energy, and at a desk that isn't specific
/// enough: measured on 2026-09-05, fast typing read as speaking for 70-80% of
/// a burst, background music for a whole clip, and a fan for 21 of 25 s. So
/// the turn timer ran while you typed notes on a call, which is the one moment
/// it most needs to be quiet. On-device recognition fed the same buffers
/// produced no words at all on any of them.
///
/// Words are the *precondition* for the lamp turning blue, not a veto after
/// the fact. A veto would let typing turn the lamp blue for a second and snap
/// back, which looks broken and briefly runs the timer. So:
///
/// - the gate firing opens a **candidate**, and nothing is shown yet;
/// - the candidate **confirms** the moment the recogniser has heard words
///   covering audio at or after the candidate's onset, and the turn is
///   back-dated to that onset, so the timer appears at 0:02 rather than
///   losing the two seconds;
/// - a candidate with no words inside `window` is **discarded** and stays
///   discarded until the gate lets go. Noise produces no words, so noise
///   never produces blue.
///
/// The gate keeps running exactly as it does now and still owns the onset
/// timestamp and the release: this only ever delays a start, never causes one
/// and never ends one. Pure and time-injected, like `TurnClock`.
struct SpeechConfirmation {
    /// What the engine feeds to the turn clock and the state machine in place
    /// of the gate's own decision.
    struct Decision: Equatable {
        let isSpeaking: Bool
        /// The onset to back-date the turn to, or nil when not speaking.
        let speechStartedAt: Date?
    }

    /// How long a candidate waits for its first words. Measured first words
    /// land 0.8 to 1.5 s after speech starts, against a gate that fires 0.9 to
    /// 1.3 s in, so three seconds is roughly double the worst observed lag —
    /// long enough to cover a slow first result, short enough that a candidate
    /// that is never going to confirm doesn't sit open through a whole
    /// sentence of somebody else's turn.
    var window: TimeInterval = 3.0

    private(set) var isSpeaking = false
    /// The confirmed turn's onset, frozen at the moment it confirmed. Nil
    /// whenever `isSpeaking` is false.
    private(set) var speechStartedAt: Date?

    /// When the gate fired, i.e. when the current candidate's window opened.
    /// Deliberately *not* the back-dated onset: the window is a statement
    /// about how long we'll wait for the recogniser from the moment we start
    /// waiting, not about the sound that earned the gate's confirmation.
    private var candidateOpenedAt: Date?
    /// The gate's back-dated onset for the current candidate.
    private var candidateOnset: Date?
    /// When the current candidate ran out of window, or nil if it hasn't.
    private var discardedAt: Date?

    /// Feed one tick and get back the decision to act on.
    ///
    /// - Parameters:
    ///   - gateSpeaking: the energy gate's decision this tick.
    ///   - gateStartedAt: the gate's back-dated onset, or nil if it isn't
    ///     speaking. Falls back to `now`.
    ///   - wordsHeardThrough: the wall-clock moment the recogniser's latest
    ///     result with words covers audio up to, or nil if it hasn't produced
    ///     any this session. Only ever moves forward.
    ///   - now: this tick's timestamp.
    @discardableResult
    mutating func update(
        gateSpeaking: Bool,
        gateStartedAt: Date?,
        wordsHeardThrough: Date?,
        now: Date
    ) -> Decision {
        guard gateSpeaking else {
            // The gate owns the release, so letting go ends everything here
            // too - including a discard, which is only ever about the episode
            // the gate is currently in.
            candidateOpenedAt = nil
            candidateOnset = nil
            discardedAt = nil
            isSpeaking = false
            speechStartedAt = nil
            return decision
        }

        // Once confirmed, this follows the gate and keeps the onset it
        // confirmed with. The recogniser going quiet mid-turn (it always does,
        // between results) must not release the turn.
        guard !isSpeaking else { return decision }

        if candidateOpenedAt == nil {
            candidateOpenedAt = now
            candidateOnset = gateStartedAt ?? now
        }

        // Words before the timeout, on purpose: a result landing on the same
        // tick the window closes should confirm the turn rather than lose it
        // to the order of two comparisons.
        if let heard = wordsHeardThrough {
            if let discardedAt {
                // Late words on a candidate we'd given up on - you typed, then
                // talked, and the gate never let go in between. Time it from
                // when the words were heard: the gate's onset belongs to the
                // typing, and back-dating to it would credit you the typing.
                if heard > discardedAt {
                    confirm(at: heard)
                    return decision
                }
            } else if let onset = candidateOnset, heard >= onset {
                confirm(at: onset)
                return decision
            }
        }

        if discardedAt == nil, let opened = candidateOpenedAt, now.timeIntervalSince(opened) >= window {
            discardedAt = now
        }
        return decision
    }

    /// Forget everything. Used when the meeting ends, or when the setting is
    /// switched off mid-call, so a stale candidate can't confirm later.
    mutating func reset() {
        isSpeaking = false
        speechStartedAt = nil
        candidateOpenedAt = nil
        candidateOnset = nil
        discardedAt = nil
    }

    private mutating func confirm(at onset: Date) {
        isSpeaking = true
        speechStartedAt = onset
    }

    private var decision: Decision {
        Decision(isSpeaking: isSpeaking, speechStartedAt: speechStartedAt)
    }
}
