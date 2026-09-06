import AVFoundation
import Foundation
import Observation
import os

/// Owns both capture paths and their lifecycle: the process tap on the meeting
/// app's output (the far end) and the microphone (the near end). Starts them
/// when a meeting appears and tears them down when it ends, so we aren't
/// holding an aggregate audio device or the mic open all day.
@MainActor
@Observable
final class AudioMonitor {
    enum Status: Equatable {
        /// No meeting detected. Both capture paths are torn down.
        case waitingForMeeting
        case starting
        case running(processBundleIDs: [String])
        /// Tapping the far end works, but the mic was refused, so the turn
        /// timer can't run. Worth surfacing rather than failing silently.
        case microphoneUnavailable(String)
        case error(String)
    }

    struct Levels {
        /// Nil until that end has delivered its first buffer; see
        /// `LevelMeter.hasReceivedAudio`.
        let farEnd: Float?
        let nearEnd: Float?
        /// The moment the word witness's latest result with words covers your
        /// microphone audio up to, or nil when it isn't running or hasn't
        /// heard any. Never a word, only a time.
        let nearEndWordsThrough: Date?
    }

    private(set) var status: Status = .waitingForMeeting
    private(set) var isMeetingActive = false

    /// Whether the turn timer waits for on-device recognition to hear words
    /// before it starts. `SignalEngine` owns the setting and persists it; this
    /// is the copy capture reads. Off by default (constitution clause 2).
    private(set) var confirmWithWords = false
    /// What the menu says about the on-device model. Meaningless while
    /// `confirmWithWords` is off.
    private(set) var witnessAvailability: WordModelAvailability = .ready

    /// Whether a witness is actually listening. The engine only holds the
    /// gate's decision back when this is true, so an unsupported language, a
    /// failed download or a refused microphone all fall back to today's
    /// behaviour rather than to a timer that never starts.
    var isWitnessRunning: Bool { witness != nil }

    /// The recogniser arrived in macOS 26; below it the menu doesn't show the
    /// switch at all.
    static var supportsWordConfirmation: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    /// Treat the Mac as being in a call regardless of what detection says,
    /// tapping all system audio instead of one app's. For calls in apps we
    /// can't see (FaceTime, a browser we don't list, a phone mirrored to the
    /// desktop). Never persisted: forgetting it's on would leave the mic and
    /// a system-audio tap open all day, so it resets on relaunch.
    private(set) var listenToAllAudio = false {
        didSet {
            guard listenToAllAudio != oldValue else { return }
            applyListenToAllAudio()
        }
    }

    /// When a timed override switches itself off, or nil for an open-ended
    /// one (or none).
    private(set) var listenToAllAudioUntil: Date?
    private var listenTimer: Timer?

    /// Switch the override on, for a duration matched to the meeting or
    /// open-ended with nil. Picking a new duration while already on just
    /// moves the deadline; capture keeps running.
    func listenToAllAudio(for duration: TimeInterval?) {
        listenTimer?.invalidate()
        listenTimer = nil
        listenToAllAudioUntil = duration.map { Date().addingTimeInterval($0) }
        if let duration {
            listenTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.stopListeningToAllAudio()
                }
            }
        }
        listenToAllAudio = true
    }

    func stopListeningToAllAudio() {
        listenTimer?.invalidate()
        listenTimer = nil
        listenToAllAudioUntil = nil
        listenToAllAudio = false
    }

    private let tapSource = ProcessTapSource()
    private let micSource = MicrophoneSource()
    private var detectTimer: Timer?
    private var quietPolls = 0
    private var isStarting = false

    /// Held as the protocol, not the concrete type: a stored property can't
    /// carry the macOS 26 availability the witness does.
    private var witness: (any SpeechWitness)?
    /// The language the model was found or fetched for, resolved once when the
    /// switch is turned on.
    private var witnessLocale: Locale?
    private var modelTask: Task<Void, Never>?
    private var isStartingWitness = false

    /// How often we ask CoreAudio which meeting processes are live.
    private let detectInterval: TimeInterval = 2
    /// Consecutive negative polls before we call the meeting over. Zoom drops
    /// its input stream briefly when switching devices or screen-sharing, and
    /// going dark for a blink each time would be worse than reacting slowly.
    private let quietPollsBeforeStopping = 5

    /// The menu shows a plain-English line for failures; the detail goes here.
    private static let logger = Logger(subsystem: "fyi.kaegan.yapmeter", category: "audio")

    func start() {
        guard detectTimer == nil else { return }
        detect()
        detectTimer = Timer.scheduledTimer(withTimeInterval: detectInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.detect()
            }
        }
    }

    func stop() {
        detectTimer?.invalidate()
        detectTimer = nil
        tearDownCapture()
    }

    /// Peak level on each end since the last call, for the voice detectors,
    /// plus how far the witness has heard words into your own audio.
    func sampleLevels() -> Levels {
        Levels(
            farEnd: level(from: tapSource.levelMeter),
            nearEnd: level(from: micSource.levelMeter),
            nearEndWordsThrough: witness?.wordsHeardThrough
        )
    }

    private func level(from meter: LevelMeter) -> Float? {
        meter.hasReceivedAudio ? meter.consumePeak() : nil
    }

    /// A meeting app with the microphone open is in a call. Output alone isn't
    /// enough: a Chrome tab playing a video has output running and no meeting.
    /// We fall back to output-only if nothing reports input, which covers a
    /// Zoom lobby and any app whose input state we can't read.
    static func isLiveMeeting(_ processes: [MeetingProcessMonitor.MatchedProcess]) -> Bool {
        if processes.contains(where: \.isRunningInput) { return true }
        return processes.contains(where: \.isRunningOutput)
    }

    // MARK: - Detection

    private func detect() {
        // The override owns capture while it's on; polling would only fight it.
        guard !listenToAllAudio else { return }

        let matches: [MeetingProcessMonitor.MatchedProcess]
        do {
            matches = try MeetingProcessMonitor.matchingProcesses()
        } catch {
            Self.logger.error("Meeting process detection failed: \(String(describing: error), privacy: .public)")
            status = .error(String(describing: error))
            return
        }

        if AudioMonitor.isLiveMeeting(matches) {
            quietPolls = 0
            if !isMeetingActive {
                isMeetingActive = true
                startCapture(for: matches)
            }
        } else if isMeetingActive {
            quietPolls += 1
            if quietPolls >= quietPollsBeforeStopping {
                isMeetingActive = false
                quietPolls = 0
                tearDownCapture()
            }
        }
    }

    /// Switching the override on replaces whatever capture is running with a
    /// global one; switching it off tears down and hands back to detection,
    /// which restarts a per-app tap on its next pass if a meeting is live.
    private func applyListenToAllAudio() {
        tearDownCapture()
        quietPolls = 0
        if listenToAllAudio {
            isMeetingActive = true
            startCapture(for: nil)
        } else {
            isMeetingActive = false
            detect()
        }
    }

    /// Pass the matched processes to tap just those, or nil to tap all
    /// system audio.
    private func startCapture(for matches: [MeetingProcessMonitor.MatchedProcess]?) {
        guard !isStarting else { return }
        if let matches, matches.isEmpty { return }
        isStarting = true
        status = .starting

        let processIDs = matches?.map(\.id)
        let bundleIDs = matches?.map(\.bundleID) ?? []
        let tap = tapSource
        let mic = micSource

        Task {
            defer { self.isStarting = false }

            // Both permission prompts fire here on first run, and both block
            // until the user answers, so keep them off the main thread.
            let startedAt = Date()
            do {
                try await Task.detached {
                    if let processIDs {
                        try tap.start(processes: processIDs)
                    } else {
                        try tap.startGlobal()
                    }
                }.value
            } catch {
                Self.logger.error("Process tap failed: \(String(describing: error), privacy: .public)")
                self.status = .error(String(describing: error))
                return
            }
            Self.logger.debug("Process tap started in \(Date().timeIntervalSince(startedAt), format: .fixed(precision: 2), privacy: .public)s")

            // The meeting can end while we're waiting on a permission dialog.
            guard self.isMeetingActive else {
                self.tearDownCapture()
                return
            }

            // Before the microphone, not after: the tap captures the buffer
            // observer when it's installed, so the witness has to exist first.
            // It also means the recogniser is warm before anyone speaks, which
            // is what keeps the first turn of a call from missing its window.
            await self.startWitness()

            let micGranted = await MicrophoneSource.requestAccess()
            var micFailure: String?
            if micGranted {
                do {
                    try await Task.detached { try mic.start() }.value
                } catch {
                    micFailure = String(describing: error)
                }
            } else {
                micFailure = String(describing: MicrophoneSource.MicError.accessDenied)
            }

            guard self.isMeetingActive else {
                self.tearDownCapture()
                return
            }

            if let micFailure {
                Self.logger.error("Microphone unavailable: \(micFailure, privacy: .public)")
                self.status = .microphoneUnavailable(micFailure)
            } else {
                Self.logger.debug("Microphone started \(Date().timeIntervalSince(startedAt), format: .fixed(precision: 2), privacy: .public)s after capture began")
                self.status = .running(processBundleIDs: bundleIDs)
            }
        }
    }

    private func tearDownCapture() {
        tapSource.stop()
        micSource.stop()
        stopWitness()
        status = .waitingForMeeting
    }

    // MARK: - Words

    /// Turn the word confirmation on or off. Turning it on resolves the
    /// language and asks macOS for the model if this Mac doesn't have it;
    /// turning it off drops the witness immediately.
    func setConfirmWithWords(_ on: Bool) {
        guard confirmWithWords != on else { return }
        confirmWithWords = on
        modelTask?.cancel()
        modelTask = nil

        guard on else {
            witnessAvailability = .ready
            stopWitness()
            return
        }
        modelTask = Task { [weak self] in
            await self?.prepareModel()
        }
    }

    /// Find a language with an on-device model, downloading one if needed.
    private func prepareModel() async {
        guard #available(macOS 26, *) else {
            witnessAvailability = .unsupported
            return
        }
        guard let locale = await WordWitness.supportedLocale() else {
            Self.logger.error("No on-device speech model for any preferred language")
            witnessAvailability = .unsupported
            return
        }
        witnessLocale = locale

        if await WordWitness.isInstalled(locale) {
            witnessAvailability = .ready
        } else {
            witnessAvailability = .downloading
            do {
                try await WordWitness.install(locale)
                witnessAvailability = .ready
            } catch {
                Self.logger.error("Speech model download failed: \(String(describing: error), privacy: .public)")
                witnessAvailability = .downloadFailed
                return
            }
        }

        guard !Task.isCancelled, confirmWithWords else { return }
        // The model can become ready long after capture started - at launch
        // with a call already running, or the first time the switch is turned
        // on mid-call. The microphone's buffer observer can be attached to a
        // tap that is already installed, so the witness just joins in rather
        // than capture having to be torn down and rebuilt around it.
        await startWitness()
    }

    /// Build the witness and start the recogniser, if the setting is on and
    /// there is a model to run. Does nothing otherwise, which is what leaves
    /// the signal exactly as it is today.
    ///
    /// Two callers can reach this at once — capture starting, and the model
    /// becoming ready — and there's an `await` before the witness is stored,
    /// so `isStartingWitness` is what stops them building two.
    private func startWitness() async {
        guard !isStartingWitness, witness == nil, isMeetingActive else { return }
        guard confirmWithWords, witnessAvailability == .ready else { return }
        guard #available(macOS 26, *), let locale = witnessLocale else { return }

        isStartingWitness = true
        defer { isStartingWitness = false }

        let witness = WordWitness(locale: locale)
        do {
            try await witness.start()
        } catch {
            Self.logger.error("Word witness failed to start: \(String(describing: error), privacy: .public)")
            return
        }
        guard isMeetingActive, confirmWithWords else {
            witness.stop()
            return
        }
        self.witness = witness
        micSource.bufferObserver = { [weak witness] buffer in
            witness?.receive(buffer)
        }
    }

    /// Nothing is held between calls.
    private func stopWitness() {
        micSource.bufferObserver = nil
        witness?.stop()
        witness = nil
    }
}
