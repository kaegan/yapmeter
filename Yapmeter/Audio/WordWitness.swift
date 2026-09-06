import AVFoundation
import Foundation
import Speech
import os

/// Whether on-device recognition can run on this Mac, for the menu to say so.
/// Anything but `.ready` means the turn timer is running on the energy gate
/// alone, as it did before there was a witness.
enum WordModelAvailability: Equatable, Sendable {
    case ready
    /// macOS is fetching the model. Happens once, on the first launch on a
    /// Mac that has no model for your language.
    case downloading
    case downloadFailed
    /// No on-device model exists for any language this Mac prefers.
    case unsupported
}

/// Stands witness to the fact that your microphone contained *words*, so the
/// turn timer doesn't start on typing, music or a fan.
///
/// It takes one thing from Apple's on-device recogniser and throws the rest
/// away: the moment up to which the latest result containing any text covers
/// the audio. `SpeechConfirmation` turns that into a yes/no. The text is never
/// copied out of `absorb`, never logged, never stored, and the far end is
/// never fed here at all — constitution clause 2.
///
/// `.fastResults` is not optional. Without it volatile results arrive in
/// batches every ~3.7 s, which is longer than the confirmation window, and
/// nothing would ever confirm in time.
final class WordWitness: @unchecked Sendable {
    enum WitnessError: Error, CustomStringConvertible {
        case noCompatibleFormat

        var description: String {
            switch self {
            case .noCompatibleFormat: return "no audio format the recogniser accepts"
            }
        }
    }

    private static let logger = Logger(subsystem: "fyi.kaegan.yapmeter", category: "words")

    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>
    private let feed: AsyncStream<AnalyzerInput>.Continuation

    /// Guards everything below. Taken on the microphone's tap thread (10 Hz),
    /// on the results task, and on the main actor's tick, so it is cheap and
    /// uncontended in the way `os_unfair_lock` wants.
    private var lock = os_unfair_lock_s()
    private var _wordsHeardThrough: Date?
    /// The format the analyzer wants, once known. Buffers arriving before it
    /// is are dropped rather than queued: they are the mic's zero-filled
    /// startup ones anyway.
    private var _analyzerFormat: AVAudioFormat?
    private var _converter: AVAudioConverter?
    /// Frames handed to the analyzer so far, in the analyzer's own sample
    /// rate. This is the clock a result's `range` is measured against.
    private var _framesSent: AVAudioFramePosition = 0
    /// Wall-clock time of frame 0, set when the first buffer arrives. Maps a
    /// result's `range.end` onto a `Date` the signal layer can compare with
    /// the gate's onset.
    private var _anchor: Date?
    /// Character count of the last volatile result, so a result that merely
    /// repeats itself doesn't advance the witness. Never the text.
    private var _lastVolatileLength = 0
    private var _resultsTask: Task<Void, Never>?

    init(locale: Locale) {
        transcriber = SpeechTranscriber(
            locale: locale,
            // Nothing but the presence of text is wanted, so no transcription
            // options and no alternatives; `.audioTimeRange` is what makes a
            // result say which audio it covers.
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
        analyzer = SpeechAnalyzer(modules: [transcriber])
        var continuation: AsyncStream<AnalyzerInput>.Continuation!
        input = AsyncStream { continuation = $0 }
        feed = continuation
    }

    /// The wall-clock moment the recogniser's latest result with words covers
    /// audio up to, or nil if it hasn't heard any this session. Only ever
    /// moves forward. Read from the main actor on every tick.
    var wordsHeardThrough: Date? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _wordsHeardThrough
    }

    /// Resolve the analyzer's format and start it. Call before the microphone
    /// starts, so the first buffer already has somewhere to go.
    func start() async throws {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw WitnessError.noCompatibleFormat
        }

        let task = Task { [weak self, transcriber] in
            do {
                for try await result in transcriber.results {
                    self?.absorb(result)
                }
            } catch {
                Self.logger.error("Recogniser stopped: \(String(describing: error), privacy: .public)")
            }
        }

        store(format: format, resultsTask: task)
        try await analyzer.start(inputSequence: input)
    }

    /// The lock can't be taken from an async context, so the one write
    /// `start()` needs is done from here.
    private func store(format: AVAudioFormat, resultsTask: Task<Void, Never>) {
        os_unfair_lock_lock(&lock)
        _analyzerFormat = format
        _resultsTask = resultsTask
        os_unfair_lock_unlock(&lock)
    }

    /// Nothing is held between calls: the stream ends, the analyzer finishes,
    /// and this object is dropped by `AudioMonitor` straight after.
    func stop() {
        feed.finish()
        os_unfair_lock_lock(&lock)
        let task = _resultsTask
        _resultsTask = nil
        os_unfair_lock_unlock(&lock)
        let analyzer = self.analyzer
        Task {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            task?.cancel()
        }
    }

    deinit {
        feed.finish()
        _resultsTask?.cancel()
    }

    /// Called on the microphone's tap thread with each buffer, after the level
    /// has been measured. Converts to the analyzer's format, stamps the buffer
    /// with its position in the stream, and hands it over.
    func receive(_ buffer: AVAudioPCMBuffer) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let format = _analyzerFormat, let converted = convert(buffer, to: format) else { return }

        if _anchor == nil {
            // Frame 0 is the start of this buffer's audio, which the engine
            // handed over at the end of it - about 100 ms ago.
            let heldBack = Double(buffer.frameLength) / buffer.format.sampleRate
            _anchor = Date().addingTimeInterval(-heldBack)
        }
        let start = CMTime(value: _framesSent, timescale: CMTimeScale(format.sampleRate))
        _framesSent += AVAudioFramePosition(converted.frameLength)
        feed.yield(AnalyzerInput(buffer: converted, bufferStartTime: start))
    }

    /// Reads the *length* of a result's text, never the text. A result that
    /// says something new (or any final one) with any text at all moves the
    /// witness forward to the end of the audio it covers.
    private func absorb(_ result: SpeechTranscriber.Result) {
        let length = result.text.characters.count
        let end = result.range.end
        guard length > 0, end.isNumeric else { return }

        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let anchor = _anchor else { return }
        // Volatile results repeat and extend the same phrase as it firms up;
        // only one that changed length is evidence of anything new.
        let isFinal = result.isFinal
        guard isFinal || length != _lastVolatileLength else { return }
        _lastVolatileLength = isFinal ? 0 : length

        let heard = anchor.addingTimeInterval(end.seconds)
        if heard > (_wordsHeardThrough ?? .distantPast) {
            _wordsHeardThrough = heard
        }
    }

    /// Resamples the microphone's buffers into whatever the analyzer asked
    /// for (typically mono at a lower rate). The converter is kept across
    /// calls so resampling stays continuous between buffers.
    ///
    /// Caller holds `lock`.
    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if _converter == nil || _converter?.inputFormat != buffer.format {
            _converter = AVAudioConverter(from: buffer.format, to: format)
            _converter?.reset()
        }
        guard let converter = _converter, buffer.frameLength > 0 else { return nil }

        let ratio = format.sampleRate / buffer.format.sampleRate
        // Headroom on top of the ratio: a resampler holds a few frames back
        // and can hand over more than the arithmetic suggests.
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        // The input block's type is `@Sendable`, but the converter calls it
        // synchronously on this thread before `convert` returns, so nothing
        // here ever crosses one.
        nonisolated(unsafe) let source = buffer
        nonisolated(unsafe) var offered = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if offered {
                // One buffer per call: tell the converter to emit what it has
                // rather than block waiting for more.
                outStatus.pointee = .noDataNow
                return nil
            }
            offered = true
            outStatus.pointee = .haveData
            return source
        }
        guard status != .error, output.frameLength > 0 else {
            if let error {
                Self.logger.error("Buffer conversion failed: \(error.localizedDescription, privacy: .public)")
            }
            return nil
        }
        return output
    }

    // MARK: - The model

    /// The language to recognise in: this Mac's own if there's a model for it,
    /// else the first of its preferred languages that has one. Nil means no
    /// language this Mac asks for can be recognised on device.
    static func supportedLocale() async -> Locale? {
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            return match
        }
        for identifier in Locale.preferredLanguages {
            if let match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) {
                return match
            }
        }
        return nil
    }

    /// Whether the on-device model for `locale` is already on this Mac.
    static func isInstalled(_ locale: Locale) async -> Bool {
        let installed = await SpeechTranscriber.installedLocales
        let wanted = locale.identifier(.bcp47)
        return installed.contains { $0.identifier(.bcp47) == wanted }
    }

    /// Asks macOS to fetch the on-device model. This is the one network
    /// request the app can cause besides Sparkle's, it is macOS that makes
    /// it, and it happens once, on first launch on a Mac that has no model
    /// for your language (constitution clause 3).
    static func install(_ locale: Locale) async throws {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            return
        }
        try await request.downloadAndInstall()
    }
}
