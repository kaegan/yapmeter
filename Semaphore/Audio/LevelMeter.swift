import Foundation
import os

/// Thread-safe holder for the latest audio level measurement. Written from
/// the real-time CoreAudio IO thread inside `ProcessTapSource`; read from a
/// UI timer on the main actor. Uses `os_unfair_lock` rather than `NSLock`:
/// cheap when uncontended, which is what the IO thread needs.
final class LevelMeter: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var _dBFS: Float = -90
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

    /// Called from the IO thread with a newly computed RMS dBFS value.
    func update(dBFS: Float) {
        os_unfair_lock_lock(&lock)
        _dBFS = dBFS
        _lastUpdate = Date()
        os_unfair_lock_unlock(&lock)
    }
}
