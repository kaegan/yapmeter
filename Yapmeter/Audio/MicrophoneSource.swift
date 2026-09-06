import AVFoundation
import Foundation

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

    /// Handed each buffer after its level has been measured, for anything that
    /// needs the audio itself rather than a number — today only the word
    /// witness. Read once when the tap is installed, so it must be set before
    /// `start()`; changing it mid-capture does nothing until the next start.
    /// Only the near end ever has one: the far end is never transcribed
    /// (constitution clause 2).
    var bufferObserver: (@Sendable (AVAudioPCMBuffer) -> Void)?

    private let engine = AVAudioEngine()
    private(set) var isRunning = false

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
        guard !isRunning else { return }
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
        let observer = bufferObserver
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            MicrophoneSource.processBuffer(buffer, sliceLength: sliceLength, into: meter)
            observer?(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        levelMeter.reset()
    }

    deinit {
        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
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
        // The first buffer or two after `engine.start()` are partly
        // zero-filled: the engine hands over frames the device hasn't
        // produced yet. Their median sits at -100 dBFS or lower, which no
        // microphone in a room ever reads (self-noise alone is well above
        // -90). Reporting one lets the detector's noise floor collapse to
        // it in a few hundred milliseconds, after which ordinary room noise
        // reads as speech and, in a room that never goes quiet, stays that
        // way for the session (YB-50). Dropping it here means
        // `LevelMeter.hasReceivedAudio` flips on the first real buffer,
        // which is what it was meant to wait for.
        guard loudest > LevelMeter.silence else { return }
        meter.update(dBFS: loudest)
    }
}
