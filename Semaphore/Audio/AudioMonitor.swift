import CoreAudio
import Foundation
import Observation

/// Bridges the CoreAudio tap pipeline to the UI, and arms it automatically:
/// `MeetingDetector` says when a meeting starts and stops, and this turns
/// the tap on and off to match. The manual toggle stays as an override and
/// as a debug affordance until Milestone 3 wires the level to the signal
/// state machine.
@MainActor
@Observable
final class AudioMonitor {
    enum Status: Equatable {
        case idle
        case waitingForMeeting
        case noMeetingAppFound
        case starting
        case running(processBundleIDs: [String])
        case error(String)
    }

    private(set) var status: Status = .idle
    private(set) var dBFS: Float = -90

    let detector = MeetingDetector()

    private let tapSource = ProcessTapSource()
    private var refreshTimer: Timer?
    private var tappedProcessIDs: [AudioObjectID] = []
    /// Set when the user stops the tap by hand mid-meeting, so auto-arm
    /// doesn't immediately turn it back on. Cleared when the meeting ends.
    private var userSuppressed = false

    var currentMeeting: MeetingProcessMonitor.Meeting? {
        if case .inMeeting(let meeting) = detector.state { return meeting }
        return nil
    }

    /// Start watching for meetings. The tap - and therefore the System Audio
    /// Recording permission prompt - only comes up once a meeting is
    /// actually detected.
    func startAutomaticDetection() {
        detector.onChange = { [weak self] meeting in
            self?.meetingDidChange(meeting)
        }
        detector.start()
        if case .idle = status { status = .waitingForMeeting }
    }

    func toggle() {
        if case .running = status {
            userSuppressed = currentMeeting != nil
            stopTap()
            status = detector.state == .notRunning ? .idle : .waitingForMeeting
        } else {
            userSuppressed = false
            startTapForCurrentMeetingOrAnyMatchingApp()
        }
    }

    // MARK: - Auto-arming

    private func meetingDidChange(_ meeting: MeetingProcessMonitor.Meeting?) {
        guard let meeting else {
            userSuppressed = false
            stopTap()
            status = .waitingForMeeting
            return
        }
        guard !userSuppressed else { return }
        // Mid-meeting churn (Chrome spawning another helper) only warrants a
        // rebuild if the set of processes we're tapping actually changed.
        if tapSource.isRunning, Set(tappedProcessIDs) == Set(meeting.processIDs) { return }
        startTap(processIDs: meeting.processIDs, bundleIDs: meeting.bundleIDs)
    }

    // MARK: - Tap lifecycle

    private func startTapForCurrentMeetingOrAnyMatchingApp() {
        if let meeting = currentMeeting {
            startTap(processIDs: meeting.processIDs, bundleIDs: meeting.bundleIDs)
            return
        }
        do {
            let matches = try MeetingProcessMonitor.matchingProcesses()
            guard !matches.isEmpty else {
                status = .noMeetingAppFound
                return
            }
            startTap(processIDs: matches.map(\.id), bundleIDs: matches.map(\.bundleID))
        } catch {
            status = .error(String(describing: error))
        }
    }

    private func startTap(processIDs: [AudioObjectID], bundleIDs: [String]) {
        status = .starting
        tappedProcessIDs = processIDs
        let tap = tapSource
        Task {
            do {
                try await Task.detached { try tap.start(processes: processIDs) }.value
                self.status = .running(processBundleIDs: bundleIDs)
                self.startRefreshTimer()
            } catch {
                self.tappedProcessIDs = []
                self.status = .error(String(describing: error))
            }
        }
    }

    private func stopTap() {
        tapSource.stop()
        tappedProcessIDs = []
        refreshTimer?.invalidate()
        refreshTimer = nil
        dBFS = -90
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 50.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDisplay()
            }
        }
    }

    private func refreshDisplay() {
        dBFS = tapSource.levelMeter.dBFS
    }
}
