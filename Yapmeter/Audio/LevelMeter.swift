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
    private var _hasUnreadPeak = false
    private var _hasReceivedAudio = false
    private var _lastUpdate = Date.distantPast

    /// False until the first buffer lands after a start (or `reset()`).
    /// The microphone takes a few seconds to deliver its first buffer, and
    /// feeding the detector `silence` meanwhile drags its noise floor to the
    /// bottom of the range, where ordinary room noise then reads as speech.
    var hasReceivedAudio: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _hasReceivedAudio
    }

    /// Back to the never-started state. Sources call this on stop so the
    /// next start waits for real audio again instead of holding a stale level.
    func reset() {
        os_unfair_lock_lock(&lock)
        _dBFS = LevelMeter.silence
        _peakDBFS = LevelMeter.silence
        _hasUnreadPeak = false
        _hasReceivedAudio = false
        _lastUpdate = .distantPast
        os_unfair_lock_unlock(&lock)
    }

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

    /// The loudest level seen since the last call, or the latest level if
    /// nothing new has arrived. Two rates meet here and neither matches the
    /// detector's 50 Hz tick: the process tap delivers faster (so we take the
    /// peak, keeping a short syllable that lands between ticks), and the
    /// microphone delivers slower, in 100 ms chunks whatever buffer size we
    /// ask for. Reporting "silence" on the ticks between chunks was a bug
    /// that pinned the noise floor to the bottom and reset the onset timer
    /// four times out of five: the turn timer took ages to start and, once
    /// room noise cleared a floor that low, never stopped.
    func consumePeak() -> Float {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard _hasUnreadPeak else { return _dBFS }
        _hasUnreadPeak = false
        let peak = _peakDBFS
        _peakDBFS = LevelMeter.silence
        return peak
    }

    /// Called from the IO thread with a newly computed RMS dBFS value.
    func update(dBFS: Float) {
        os_unfair_lock_lock(&lock)
        _dBFS = dBFS
        _peakDBFS = max(_peakDBFS, dBFS)
        _hasUnreadPeak = true
        _hasReceivedAudio = true
        _lastUpdate = Date()
        os_unfair_lock_unlock(&lock)
    }
}
