import Foundation
import os

/// Thread-safe holder for the latest audio level measurement. Written from
/// the real-time CoreAudio IO thread inside `ProcessTapSource`; read from a
/// UI timer on the main actor. Uses `os_unfair_lock` rather than `NSLock`:
/// cheap when uncontended, which is what the IO thread needs.
final class LevelMeter: @unchecked Sendable {
    /// The level reported when nothing has arrived at all: below anything a
    /// real signal produces, so silence and "no audio" read the same to the
    /// detector (`isReceivingAudio` is what tells those apart for the UI).
    static let silence: Float = -90

    private var lock = os_unfair_lock_s()
    private var _dBFS: Float = LevelMeter.silence
    private var _peakDBFS: Float = LevelMeter.silence
    private var _lastUpdate = Date.distantPast

    var dBFS: Float {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _dBFS
    }

    /// Whether a level was reported within the last second - lets the UI
    /// tell "tap running but silent" apart from "tap not delivering
    /// anything at all", which is a distinct failure mode worth surfacing.
    var isReceivingAudio: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return Date().timeIntervalSince(_lastUpdate) < 1.0
    }

    /// The loudest level seen since the last call, then resets. The IO thread
    /// delivers buffers faster than the 50 Hz detector tick reads them, so
    /// taking the peak rather than the latest keeps a short syllable that
    /// lands between ticks from being dropped.
    func consumePeak() -> Float {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let peak = _peakDBFS
        _peakDBFS = LevelMeter.silence
        return peak
    }

    /// Called from the IO thread with a newly computed RMS dBFS value.
    func update(dBFS: Float) {
        os_unfair_lock_lock(&lock)
        _dBFS = dBFS
        _peakDBFS = max(_peakDBFS, dBFS)
        _lastUpdate = Date()
        os_unfair_lock_unlock(&lock)
    }
}
