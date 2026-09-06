import Foundation

/// Decides whether the process tap is being blocked by a refused System Audio
/// Recording permission, from the only evidence macOS gives us: the audio
/// itself.
///
/// Measured on 2026-09-05 (macOS 27): with the permission refused, every
/// CoreAudio call in `ProcessTapSource` returns `noErr` and the IO proc fires
/// at the normal rate — 276,480 frames in 3 s with a sound playing — and every
/// sample of it is bit-exactly zero. There is no `OSStatus` to key on. The app
/// therefore reaches `.running`, the menu says "Listening to Zoom", and Yap
/// stays dark for every meeting with nothing to say why. A permission granted
/// at setup and later revoked in System Settings produces the same silence on
/// the next tap built after it, so it arrives here too rather than through a
/// path of its own.
///
/// The discriminator is that a blocked tap delivers *bit-exact* zeros. Real
/// meeting-app output carries dither and noise; `LevelMeter.silence` is −90
/// dBFS and nothing in a room ever reaches the −180 that all-zero buffers
/// read as. So: frames arriving steadily, none of them non-zero, for long
/// enough that a genuinely quiet far end has been ruled out.
///
/// Two conditions keep an honest quiet call off this verdict. The near end
/// must be alive, which proves the room and the rest of the pipeline are
/// working. And one non-zero sample latches healthy for the rest of the call —
/// a tap that has been heard once is not a blocked tap.
///
/// Pure and time-injected, like `TurnClock` and `SpeechConfirmation`.
struct TapSilence {
    enum Verdict: Equatable {
        case healthy
        /// The tap is delivering nothing but zeros; the permission is off.
        case blocked
    }

    /// How much delivered-but-silent audio it takes to call it. A minute is
    /// far longer than any real gap in a call — the far end that never makes
    /// a sound for a whole minute while you're talking into a live microphone
    /// is the one whose permission is off.
    var window: TimeInterval = 60

    /// A tick gap longer than this doesn't count towards the window. The
    /// detect timer runs every 2 s, so anything much larger means the Mac
    /// slept or the app was starved, and neither is evidence about the tap.
    var maximumTickGap: TimeInterval = 5

    private(set) var verdict: Verdict = .healthy

    /// Set by the first non-zero sample of the call and never cleared until
    /// `reset()`. The far end going quiet later must not re-open the question.
    private(set) var hasHeardAudio = false

    private var silentSeconds: TimeInterval = 0
    /// The last tick that counted. Nil while the clock is paused, so the gap
    /// across a pause is never added.
    private var lastCountedTick: Date?

    /// Feed one tick and get back the verdict.
    ///
    /// - Parameters:
    ///   - isDelivering: whether the tap handed over any frames since the last
    ///     tick. False means the aggregate device isn't running audio at all,
    ///     which is a different problem and not this one.
    ///   - heardNonZero: whether any sample the tap has delivered this call
    ///     has been non-zero.
    ///   - nearEndAlive: whether the microphone has delivered real audio. It
    ///     takes a few seconds to start, and if it never does, the microphone
    ///     line already covers it.
    ///   - now: this tick's timestamp.
    @discardableResult
    mutating func update(
        isDelivering: Bool,
        heardNonZero: Bool,
        nearEndAlive: Bool,
        now: Date
    ) -> Verdict {
        if heardNonZero { hasHeardAudio = true }
        guard !hasHeardAudio else {
            verdict = .healthy
            return verdict
        }

        guard isDelivering, nearEndAlive else {
            // Pause rather than forget: the mic waking up a few seconds into
            // the call shouldn't cost the silence already counted, and it
            // shouldn't credit the wait either.
            lastCountedTick = nil
            return verdict
        }

        if let last = lastCountedTick {
            silentSeconds += min(now.timeIntervalSince(last), maximumTickGap)
        }
        lastCountedTick = now
        verdict = silentSeconds >= window ? .blocked : .healthy
        return verdict
    }

    /// Back to the start of a call. Capture teardown and a retry both go
    /// through here, so a verdict never carries across a rebuilt tap.
    mutating func reset() {
        verdict = .healthy
        hasHeardAudio = false
        silentSeconds = 0
        lastCountedTick = nil
    }
}
