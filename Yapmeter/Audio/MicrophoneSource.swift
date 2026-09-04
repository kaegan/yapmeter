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
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            MicrophoneSource.processBuffer(buffer, into: meter)
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
    }

    deinit {
        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    /// Runs on the engine's render thread: RMS across every channel and frame,
    /// published as dBFS. Mirrors `ProcessTapSource.processBuffer`.
    private static func processBuffer(_ buffer: AVAudioPCMBuffer, into meter: LevelMeter) {
        guard let channels = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return }

        var sumSquares: Double = 0
        for channel in 0..<channelCount {
            let samples = channels[channel]
            for frame in 0..<frameCount {
                let sample = Double(samples[frame])
                sumSquares += sample * sample
            }
        }

        let rms = (sumSquares / Double(frameCount * channelCount)).squareRoot()
        meter.update(dBFS: Float(20 * log10(max(rms, 1e-9))))
    }
}
