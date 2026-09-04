import AVFoundation
import Foundation
import os

/// Captures the default input device via `AVAudioEngine` and reports a running
/// RMS level in dBFS through `LevelMeter`. This is the *near* end: you.
///
/// The process tap can't do this job. It captures what the meeting app plays,
/// and your own voice never travels through that path — it goes from your mic
/// straight into the app's uplink. Hearing yourself needs a second capture and
/// a second permission (`NSMicrophoneUsageDescription`).
///
/// Known limitation: macOS exposes no per-app mute state, so if you're muted in
/// Zoom and talking anyway, this still reports speech. The failure is cosmetic
/// (a turn timer that shouldn't be running) and there is no API that fixes it.
final class MicrophoneSource: @unchecked Sendable {
    enum MicError: Error, CustomStringConvertible {
        case accessDenied
        case noInputDevice

        var description: String {
            switch self {
            case .accessDenied: return "microphone access denied"
            case .noInputDevice: return "no audio input device available"
            }
        }
    }

    let levelMeter = LevelMeter()

    private let engine = AVAudioEngine()
    /// Guards every mutation of the engine. The configuration-change
    /// notification arrives on an arbitrary thread, and `AudioMonitor` drives
    /// start/stop from a detached task, so these can genuinely collide.
    private let lock = NSLock()
    /// Restarts are serialised here rather than run inline on the notification
    /// thread: `engine.start()` can itself post a configuration change, and
    /// handling that reentrantly would deadlock on `lock`.
    private let restartQueue = DispatchQueue(label: "fyi.kaegan.yapmeter.mic-restart")
    private var _isRunning = false
    private var configurationObserver: NSObjectProtocol?

    private static let logger = Logger(subsystem: "fyi.kaegan.yapmeter", category: "microphone")

    var isRunning: Bool { lock.withLock { _isRunning } }

    /// Prompts on first call, then returns the standing answer. Safe to call
    /// every time we start; macOS only shows the dialog once.
    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start() throws {
        try lock.withLock {
            guard !_isRunning else { return }
            try startLocked()
            observeConfigurationChanges()
            _isRunning = true
        }
    }

    func stop() {
        lock.withLock {
            if let configurationObserver {
                NotificationCenter.default.removeObserver(configurationObserver)
                self.configurationObserver = nil
            }
            guard _isRunning else { return }
            stopLocked()
            _isRunning = false
        }
    }

    /// Tear the engine down and build it again. Used both by the
    /// configuration-change handler and by `AudioMonitor`'s watchdog when the
    /// level meter has gone quiet, which is the other way this path dies.
    func restart() throws {
        try lock.withLock {
            guard _isRunning else { return }
            stopLocked()
            do {
                try startLocked()
            } catch {
                _isRunning = false
                throw error
            }
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        if _isRunning { stopLocked() }
    }

    // MARK: - Engine lifecycle

    /// `AVAudioEngine` stops itself and drops every installed tap whenever the
    /// audio hardware configuration changes: a device appearing or
    /// disappearing, the default input switching, a sample-rate change. A
    /// meeting causes all of those routinely — Zoom switches input devices when
    /// you join or share a screen, headphones get plugged in, and our own
    /// process tap adds an aggregate device to the system.
    ///
    /// Without this the engine goes quiet for the rest of the meeting while
    /// `isRunning` still says true, the level meter sits at silence forever,
    /// and the turn timer never appears again. It looks exactly like the
    /// detector having stopped believing you.
    private func observeConfigurationChanges() {
        guard configurationObserver == nil else { return }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.restartQueue.async {
                do {
                    try self.restart()
                } catch {
                    Self.logger.error(
                        "Microphone restart after configuration change failed: \(String(describing: error), privacy: .public)"
                    )
                }
            }
        }
    }

    private func startLocked() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw MicError.accessDenied
        }

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        // A zero sample rate means CoreAudio handed us a placeholder: no input
        // device, or one that disappeared. Installing a tap on it would trap.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicError.noInputDevice
        }

        let meter = levelMeter
        // 10ms worth of frames at the input's real sample rate: the slice
        // size `LevelAnalysis.sustainedDBFS` uses to tell a keystroke click
        // apart from sustained speech. See `processBuffer` below.
        let sliceLength = max(1, Int(format.sampleRate / 100))
        // Removing first is harmless if there is no tap, and necessary if a
        // previous engine incarnation left one behind.
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            MicrophoneSource.processBuffer(buffer, sliceLength: sliceLength, into: meter)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    private func stopLocked() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        levelMeter.reset()
    }

    /// Runs on the engine's render thread: a sustained (not just loud) level
    /// across every channel, published as dBFS.
    ///
    /// Unlike `ProcessTapSource.processBuffer`, this slices each buffer before
    /// measuring it (`LevelAnalysis.sustainedDBFS`). The mic sits right next
    /// to your keyboard, so a click needs to be told apart from your voice at
    /// this stage; the tap only hears whatever the meeting app plays, which
    /// doesn't have that problem and arrives in buffers too short to slice
    /// anyway.
    private static func processBuffer(_ buffer: AVAudioPCMBuffer, sliceLength: Int, into meter: LevelMeter) {
        guard let channels = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return }

        // Per channel, then the max across channels - a voice on either one
        // counts - rather than blending every channel into one RMS the way
        // this used to. Built-in and USB mics are practically always mono, so
        // this rarely changes anything, but a genuinely stereo input with
        // uncorrelated per-channel noise now reads at whichever channel is
        // louder rather than their combined average.
        var loudest = LevelMeter.silence
        for channel in 0..<channelCount {
            let samples = UnsafeBufferPointer(start: channels[channel], count: frameCount)
            loudest = max(loudest, LevelAnalysis.sustainedDBFS(samples, sliceLength: sliceLength))
        }
        meter.update(dBFS: loudest)
    }
}
