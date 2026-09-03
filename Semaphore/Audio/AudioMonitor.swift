import Foundation
import Observation

/// Bridges the CoreAudio tap pipeline to the UI. Milestone 2: a manual
/// start/stop toggle and a live dBFS readout in the popover, to prove the
/// tap actually receives audio before Milestone 3 wires it to the signal
/// state machine and Milestone 5 makes it start/stop automatically.
@MainActor
@Observable
final class AudioMonitor {
    enum Status: Equatable {
        case idle
        case noMeetingAppFound
        case starting
        case running(processBundleIDs: [String])
        case error(String)
    }

    private(set) var status: Status = .idle
    private(set) var dBFS: Float = -90

    private let tapSource = ProcessTapSource()
    private var refreshTimer: Timer?

    func toggle() {
        if case .running = status {
            stop()
        } else {
            start()
        }
    }

    private func start() {
        do {
            let matches = try MeetingProcessMonitor.matchingProcesses()
            guard !matches.isEmpty else {
                status = .noMeetingAppFound
                return
            }
            status = .starting
            let processIDs = matches.map(\.id)
            let bundleIDs = matches.map(\.bundleID)
            let tap = tapSource
            Task {
                do {
                    try await Task.detached { try tap.start(processes: processIDs) }.value
                    self.status = .running(processBundleIDs: bundleIDs)
                    self.startRefreshTimer()
                } catch {
                    self.status = .error(String(describing: error))
                }
            }
        } catch {
            status = .error(String(describing: error))
        }
    }

    private func stop() {
        tapSource.stop()
        refreshTimer?.invalidate()
        refreshTimer = nil
        status = .idle
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
