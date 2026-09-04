import CoreAudio
import Foundation
import Observation

/// Watches CoreAudio for the start and end of a meeting, without a calendar
/// and without recording anything: a meeting is a known meeting app holding
/// the microphone open (`kAudioProcessPropertyIsRunningInput`). CoreAudio
/// pushes those transitions to us via property listeners, so joining a call
/// is an event, not a poll.
///
/// The raw signal is edgy - Zoom drops and reacquires the mic when you
/// change input device, and Chrome briefly opens it during a device probe -
/// so both edges are debounced: a short confirmation before declaring a
/// meeting, a longer grace period before declaring it over.
@MainActor
@Observable
final class MeetingDetector {
    enum State: Equatable {
        case notRunning
        case noMeeting
        case inMeeting(MeetingProcessMonitor.Meeting)
    }

    /// How long the mic has to stay open before we believe it's a meeting.
    private let startConfirmation: Duration = .seconds(2)
    /// How long it has to stay closed before we believe the meeting ended.
    private let endGrace: Duration = .seconds(12)
    /// Backstop re-scan, in case a listener misses a transition or a
    /// process object is recycled without notifying us.
    private let sweepInterval: TimeInterval = 5

    private(set) var state: State = .notRunning

    /// Called on every confirmed transition; nil means the meeting ended.
    var onChange: ((MeetingProcessMonitor.Meeting?) -> Void)?

    private var listeners: [Listener] = []
    private var watchedProcessIDs: Set<AudioObjectID> = []
    private var pendingTransition: Task<Void, Never>?
    /// Which side of the fence the in-flight debounce is heading toward.
    private var pendingIsMeeting: Bool?
    private var sweepTimer: Timer?
    private let listenerQueue = DispatchQueue(label: "fyi.kaegan.semaphore.meeting-detector")

    func start() {
        guard state == .notRunning else { return }
        state = .noMeeting
        addListener(object: AudioObjectID(kAudioObjectSystemObject),
                    selector: kAudioHardwarePropertyProcessObjectList)
        sweepTimer = Timer.scheduledTimer(withTimeInterval: sweepInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rescan() }
        }
        rescan()
    }

    func stop() {
        pendingTransition?.cancel()
        pendingTransition = nil
        pendingIsMeeting = nil
        sweepTimer?.invalidate()
        sweepTimer = nil
        removeAllListeners()
        watchedProcessIDs = []
        state = .notRunning
    }

    /// Read the world, re-arm per-process listeners, and debounce whatever
    /// changed toward a confirmed state.
    private func rescan() {
        guard state != .notRunning else { return }
        let matches = (try? MeetingProcessMonitor.matchingProcesses()) ?? []
        syncProcessListeners(with: matches)

        let raw = MeetingProcessMonitor.detectMeeting(among: matches)
        let current: MeetingProcessMonitor.Meeting? = {
            if case .inMeeting(let meeting) = state { return meeting }
            return nil
        }()

        // Same side of the fence: nothing to debounce. Keep the process ID
        // list fresh though - Chrome spawns and kills helpers mid-call.
        if (raw == nil) == (current == nil) {
            pendingTransition?.cancel()
            pendingTransition = nil
            pendingIsMeeting = nil
            if let raw, raw != current {
                state = .inMeeting(raw)
                onChange?(raw)
            }
            return
        }

        // Already waiting on this same transition: let it run out.
        if let pendingIsMeeting, pendingIsMeeting == (raw != nil) { return }

        pendingTransition?.cancel()
        let target = raw != nil
        pendingIsMeeting = target
        let delay = target ? startConfirmation : endGrace
        pendingTransition = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.commitPending(expecting: target)
        }
    }

    /// Re-read at commit time rather than trusting the snapshot that opened
    /// the debounce - the process list moves during those seconds.
    private func commitPending(expecting isMeeting: Bool) {
        pendingTransition = nil
        pendingIsMeeting = nil
        guard state != .notRunning else { return }

        let matches = (try? MeetingProcessMonitor.matchingProcesses()) ?? []
        let fresh = MeetingProcessMonitor.detectMeeting(among: matches)
        guard (fresh != nil) == isMeeting else {
            rescan()
            return
        }
        state = fresh.map(State.inMeeting) ?? .noMeeting
        onChange?(fresh)
    }

    // MARK: - CoreAudio property listeners

    private struct Listener {
        let objectID: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    /// Keep one input/output listener pair per matching process, adding
    /// them as apps connect to CoreAudio and dropping them as they leave.
    private func syncProcessListeners(with matches: [MeetingProcessMonitor.MatchedProcess]) {
        let current = Set(matches.map(\.id))
        guard current != watchedProcessIDs else { return }

        let gone = watchedProcessIDs.subtracting(current)
        if !gone.isEmpty {
            listeners.removeAll { listener in
                guard gone.contains(listener.objectID) else { return false }
                var address = listener.address
                AudioObjectRemovePropertyListenerBlock(listener.objectID, &address, listenerQueue, listener.block)
                return true
            }
        }
        for objectID in current.subtracting(watchedProcessIDs) {
            addListener(object: objectID, selector: kAudioProcessPropertyIsRunningInput)
            addListener(object: objectID, selector: kAudioProcessPropertyIsRunningOutput)
        }
        watchedProcessIDs = current
    }

    private func addListener(object objectID: AudioObjectID, selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.rescan() }
        }
        let status = AudioObjectAddPropertyListenerBlock(objectID, &address, listenerQueue, block)
        guard status == noErr else { return }
        listeners.append(Listener(objectID: objectID, address: address, block: block))
    }

    private func removeAllListeners() {
        for listener in listeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.objectID, &address, listenerQueue, listener.block)
        }
        listeners = []
    }
}
