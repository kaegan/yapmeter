import AVFoundation
import Foundation
import Observation
import os

/// Owns both capture paths and their lifecycle: the process tap on the meeting
/// app's output (the far end) and the microphone (the near end). Starts them
/// when a meeting appears and tears them down when it ends, so we aren't
/// holding an aggregate audio device or the mic open all day.
///
/// The poll is a *reconciler*, not an edge trigger. Starting capture once, on
/// the moment a meeting is first seen, is not enough: the tap can fail on the
/// first attempt (the system-audio permission is still being decided), the
/// engine behind the microphone stops itself whenever the audio hardware
/// changes, and the set of processes worth tapping changes when a meeting app
/// respawns its audio helper. Any of those used to leave a capture path dead
/// for the rest of the meeting with nothing watching. Every poll now asks
/// "should this be running, and is it actually delivering?" and repairs what
/// isn't.
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
    }

    private(set) var status: Status = .waitingForMeeting
    private(set) var isMeetingActive = false

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

    /// Whether the far-end tap is actually delivering buffers right now.
    ///
    /// This is the difference between "the other person is quiet" and "we have
    /// gone deaf", which the level alone cannot tell apart — both are just low
    /// numbers. It matters because the signal's safe-looking aspect is green:
    /// a dead tap that reads as silence renders as *clear to speak*, which is
    /// the most harmful thing this app could get wrong.
    var isHearingFarEnd: Bool {
        tapSource.isRunning && tapSource.levelMeter.hasUpdated(within: Self.stallWindow)
    }

    /// Whether the microphone is delivering. False when the mic was refused,
    /// which is a supported configuration (the signal works, the turn timer
    /// doesn't), so this only drives the watchdog.
    var isHearingNearEnd: Bool {
        micSource.isRunning && micSource.levelMeter.hasUpdated(within: Self.stallWindow)
    }

    private let tapSource = ProcessTapSource()
    private let micSource = MicrophoneSource()
    private var detectTimer: Timer?
    private var quietPolls = 0
    private var isStarting = false

    /// When the current capture attempt got going, so the watchdog gives a
    /// freshly started path time to produce its first buffer before judging it.
    private var captureStartedAt: Date?
    /// Consecutive failed start attempts, for backing off a tap that can't be
    /// created at all (permission refused, unsupported hardware) rather than
    /// retrying it every two seconds forever.
    private var startFailures = 0
    private var nextStartAttempt: Date?
    /// Set when the microphone is refused outright. Retrying that just fails
    /// again; the user has to go to System Settings, and the menu says so.
    private var microphoneRefused = false
    /// The processes the live tap was built for. A meeting app that respawns
    /// its audio helper gets a new `AudioObjectID`, and the old tap then
    /// delivers silence forever.
    private var tappedProcesses: [AudioObjectID] = []
    /// When the live process set first stopped matching the tapped one, for
    /// debouncing helper processes that come and go.
    private var processMismatchSince: Date?

    /// How often we ask CoreAudio which meeting processes are live.
    private let detectInterval: TimeInterval = 2
    /// Consecutive negative polls before we call the meeting over. Zoom drops
    /// its input stream briefly when switching devices or screen-sharing, and
    /// going dark for a blink each time would be worse than reacting slowly.
    private let quietPollsBeforeStopping = 5

    /// A running IO path reports continuously, so a gap this long means it
    /// stopped rather than that the room went quiet.
    private static let stallWindow: TimeInterval = 3
    /// Grace after a start before the watchdog is allowed to call it stalled.
    private static let startGrace: TimeInterval = 5

    /// macOS naps background agents, and a napped app's timers stop firing at
    /// anything like 50 Hz. Held only while a meeting is live.
    private var activityToken: NSObjectProtocol?

    /// The menu shows a plain-English line for failures; the detail goes here.
    private static let logger = Logger(subsystem: "fyi.kaegan.yapmeter", category: "audio")

    func start() {
        guard detectTimer == nil else { return }
        detect()
        let timer = Timer(timeInterval: detectInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.detect()
            }
        }
        // `.common`, not the default mode: opening the menu bar menu puts the
        // run loop into event-tracking mode, which would otherwise suspend the
        // poll for as long as the menu is on screen.
        RunLoop.main.add(timer, forMode: .common)
        detectTimer = timer
    }

    func stop() {
        detectTimer?.invalidate()
        detectTimer = nil
        endActivity()
        tearDownCapture()
    }

    /// Peak level on each end since the last call, for the voice detectors.
    func sampleLevels() -> Levels {
        Levels(farEnd: level(from: tapSource.levelMeter), nearEnd: level(from: micSource.levelMeter))
    }

    private func level(from meter: LevelMeter) -> Float? {
        meter.hasReceivedAudio ? meter.consumePeak() : nil
    }

    /// A meeting app with the microphone open is in a call.
    ///
    /// Output alone isn't enough for a browser: a Chrome tab playing a video
    /// has output running and no meeting, and browsers are what people leave
    /// playing all day. For a dedicated meeting app, output alone is good
    /// enough and covers a Zoom lobby, where audio is playing before the mic
    /// has been opened.
    static func isLiveMeeting(_ processes: [MeetingProcessMonitor.MatchedProcess]) -> Bool {
        if processes.contains(where: \.isRunningInput) { return true }
        return processes.contains { $0.isRunningOutput && !MeetingProcessMonitor.isBrowser($0.bundleID) }
    }

    // MARK: - Detection

    private func detect() {
        // The override owns *detection* while it's on - polling would only
        // fight it - but the global tap dies the same ways a per-app one does,
        // so it still gets reconciled.
        guard !listenToAllAudio else {
            reconcileCapture(with: nil)
            return
        }

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
                beginActivity()
            }
        } else if isMeetingActive {
            quietPolls += 1
            if quietPolls >= quietPollsBeforeStopping {
                isMeetingActive = false
                quietPolls = 0
                endActivity()
                tearDownCapture()
                return
            }
        }

        reconcileCapture(with: matches)
    }

    /// Bring the capture paths into line with what the meeting needs, every
    /// poll. Idempotent: when everything is healthy this does nothing.
    ///
    /// `matches` is the processes to tap, or nil for the "Listen to All Audio"
    /// override's global tap, which has no process set to drift.
    private func reconcileCapture(with matches: [MeetingProcessMonitor.MatchedProcess]?) {
        guard isMeetingActive, !isStarting else { return }
        if let matches, matches.isEmpty { return }

        let now = Date()
        let settled = captureStartedAt.map { now.timeIntervalSince($0) > Self.startGrace } ?? false

        // The far end: rebuild the tap if it isn't running, if it has stopped
        // delivering, or if the processes worth tapping have changed.
        //
        // The process comparison is debounced by a poll. Chrome and Slack
        // spawn and retire audio helpers constantly, and reacting to every
        // single-poll flicker would rebuild the CoreAudio objects every two
        // seconds for the length of the meeting.
        let processesChanged: Bool
        if let matches {
            if Set(matches.map(\.id)) == Set(tappedProcesses) {
                processMismatchSince = nil
            } else if processMismatchSince == nil {
                processMismatchSince = now
            }
            processesChanged = processMismatchSince
                .map { now.timeIntervalSince($0) >= detectInterval } ?? false
        } else {
            processMismatchSince = nil
            processesChanged = false
        }

        let tapNeedsRebuild = !tapSource.isRunning || processesChanged || (settled && !isHearingFarEnd)
        if tapNeedsRebuild {
            if let nextStartAttempt, now < nextStartAttempt { return }
            startCapture(for: matches)
            return
        }

        // The near end: the engine stops itself on any audio configuration
        // change and puts itself back via its own observer, but if that fails
        // too we notice here.
        if settled, !microphoneRefused, micSource.isRunning, !isHearingNearEnd {
            Self.logger.error("Microphone stalled; restarting")
            do {
                try micSource.restart()
            } catch {
                Self.logger.error("Microphone restart failed: \(String(describing: error), privacy: .public)")
                microphoneRefused = true
                status = .microphoneUnavailable(String(describing: error))
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
            beginActivity()
            startCapture(for: nil)
        } else {
            isMeetingActive = false
            endActivity()
            detect()
        }
    }

    /// Pass the matched processes to tap just those, or nil to tap all
    /// system audio.
    private func startCapture(for matches: [MeetingProcessMonitor.MatchedProcess]?) {
        guard !isStarting else { return }
        if let matches, matches.isEmpty { return }
        isStarting = true
        captureStartedAt = Date()
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
                self.noteStartFailure()
                return
            }
            Self.logger.debug("Process tap started in \(Date().timeIntervalSince(startedAt), format: .fixed(precision: 2), privacy: .public)s")

            // The meeting can end while we're waiting on a permission dialog.
            guard self.isMeetingActive else {
                self.tearDownCapture()
                return
            }
            self.tappedProcesses = processIDs ?? []
            self.processMismatchSince = nil
            self.startFailures = 0
            self.nextStartAttempt = nil
            self.captureStartedAt = Date()

            if !mic.isRunning {
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
                    self.microphoneRefused = !micGranted
                    self.status = .microphoneUnavailable(micFailure)
                    return
                }
                self.microphoneRefused = false
            }

            // A tap rebuilt mid-meeting must not clear a standing microphone
            // warning: the mic is a separate path and is still refused.
            if self.microphoneRefused, case .microphoneUnavailable = self.status {
                return
            }
            Self.logger.debug("Microphone running \(Date().timeIntervalSince(startedAt), format: .fixed(precision: 2), privacy: .public)s after capture began")
            self.status = .running(processBundleIDs: bundleIDs)
        }
    }

    /// Back off a tap that won't start: 2s, 4s, 8s, capped at 30s. Without
    /// this a permanently refused system-audio permission would have us
    /// rebuilding CoreAudio objects every two seconds for the whole meeting.
    private func noteStartFailure() {
        startFailures += 1
        let delay = min(detectInterval * pow(2, Double(startFailures - 1)), 30)
        nextStartAttempt = Date().addingTimeInterval(delay)
    }

    private func tearDownCapture() {
        tapSource.stop()
        micSource.stop()
        tappedProcesses = []
        processMismatchSince = nil
        captureStartedAt = nil
        startFailures = 0
        nextStartAttempt = nil
        microphoneRefused = false
        status = .waitingForMeeting
    }

    private func beginActivity() {
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Watching meeting audio"
        )
    }

    private func endActivity() {
        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
            self.activityToken = nil
        }
    }
}
