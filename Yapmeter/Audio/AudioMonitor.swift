import AVFoundation
import Foundation
import Observation

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
        let farEnd: Float
        let nearEnd: Float
    }

    private(set) var status: Status = .waitingForMeeting
    private(set) var isMeetingActive = false
    /// Latest levels, for the popover's meters. The detector reads peaks via
    /// `sampleLevels()` instead; these are display-only.
    private(set) var farEndDBFS: Float = LevelMeter.silence
    private(set) var nearEndDBFS: Float = LevelMeter.silence

    private let tapSource = ProcessTapSource()
    private let micSource = MicrophoneSource()
    private var detectTimer: Timer?
    private var quietPolls = 0
    private var isStarting = false

    /// How often we ask CoreAudio which meeting processes are live.
    private let detectInterval: TimeInterval = 2
    /// Consecutive negative polls before we call the meeting over. Zoom drops
    /// its input stream briefly when switching devices or screen-sharing, and
    /// going dark for a blink each time would be worse than reacting slowly.
    private let quietPollsBeforeStopping = 5

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

    /// Peak level on each end since the last call, for the voice detectors.
    func sampleLevels() -> Levels {
        let far = tapSource.levelMeter.consumePeak()
        let near = micSource.levelMeter.consumePeak()
        if far != farEndDBFS { farEndDBFS = far }
        if near != nearEndDBFS { nearEndDBFS = near }
        return Levels(farEnd: far, nearEnd: near)
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
        let matches: [MeetingProcessMonitor.MatchedProcess]
        do {
            matches = try MeetingProcessMonitor.matchingProcesses()
        } catch {
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

    private func startCapture(for matches: [MeetingProcessMonitor.MatchedProcess]) {
        guard !isStarting, !matches.isEmpty else { return }
        isStarting = true
        status = .starting

        let processIDs = matches.map(\.id)
        let bundleIDs = matches.map(\.bundleID)
        let tap = tapSource
        let mic = micSource

        Task {
            defer { self.isStarting = false }

            // Both permission prompts fire here on first run, and both block
            // until the user answers, so keep them off the main thread.
            do {
                try await Task.detached { try tap.start(processes: processIDs) }.value
            } catch {
                self.status = .error(String(describing: error))
                return
            }

            // The meeting can end while we're waiting on a permission dialog.
            guard self.isMeetingActive else {
                self.tearDownCapture()
                return
            }

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
                self.status = .microphoneUnavailable(micFailure)
            } else {
                self.status = .running(processBundleIDs: bundleIDs)
            }
        }
    }

    private func tearDownCapture() {
        tapSource.stop()
        micSource.stop()
        status = .waitingForMeeting
        farEndDBFS = LevelMeter.silence
        nearEndDBFS = LevelMeter.silence
    }
}
