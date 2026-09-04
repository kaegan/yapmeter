import CoreAudio
import Foundation

/// Point-in-time queries against CoreAudio's process-object list to find
/// which running processes belong to a meeting app we know about, and
/// which of those are actually in a call right now. The `AudioObjectID`s
/// this returns are what a `ProcessTapSource` taps.
enum MeetingProcessMonitor {
    struct MeetingApp: Sendable {
        let name: String
        /// Prefix match because Chrome and Slack play audio from a helper
        /// process whose bundle ID extends the main app's (e.g.
        /// "com.google.Chrome.helper"), not from the main PID
        /// `NSRunningApplication` would give you.
        let bundleIDPrefix: String
    }

    static let targetApps: [MeetingApp] = [
        MeetingApp(name: "Zoom", bundleIDPrefix: "us.zoom."),
        MeetingApp(name: "Chrome", bundleIDPrefix: "com.google.Chrome"),
        MeetingApp(name: "Slack", bundleIDPrefix: "com.tinyspeck.slackmacgap"),
        MeetingApp(name: "Teams", bundleIDPrefix: "com.microsoft.teams"),
    ]

    struct MatchedProcess: Identifiable, Sendable, Equatable {
        let id: AudioObjectID
        let pid: pid_t
        let bundleID: String
        /// True while the process holds an input stream open - i.e. it has
        /// the microphone. This is the meeting signal.
        let isRunningInput: Bool
        let isRunningOutput: Bool
    }

    /// A meeting inferred purely from audio-device usage: a known meeting
    /// app is holding the microphone open.
    struct Meeting: Equatable, Sendable {
        /// Display names of the apps whose mic is open ("Zoom").
        let appNames: [String]
        /// Bundle IDs of the specific processes holding the mic, for debug.
        let bundleIDs: [String]
        /// Every process object belonging to those apps - the tap wants the
        /// app's whole audio footprint, not just the process with the mic,
        /// because in Chrome the renderer and the audio service are
        /// different process objects.
        let processIDs: [AudioObjectID]
    }

    enum MonitorError: Error {
        case propertyReadFailed(OSStatus, AudioObjectPropertySelector)
    }

    /// All currently-connected CoreAudio client processes matching our
    /// target apps, whether or not they're in a meeting.
    static func matchingProcesses() throws -> [MatchedProcess] {
        let allProcessIDs = try readProcessObjectList()
        var matches: [MatchedProcess] = []
        for objectID in allProcessIDs {
            guard let bundleID = try? readBundleID(of: objectID), !bundleID.isEmpty else { continue }
            guard app(for: bundleID) != nil else { continue }
            let pid = (try? readPID(of: objectID)) ?? 0
            let isRunningInput = (try? readIsRunningInput(of: objectID)) ?? false
            let isRunningOutput = (try? readIsRunningOutput(of: objectID)) ?? false
            matches.append(MatchedProcess(id: objectID, pid: pid, bundleID: bundleID,
                                          isRunningInput: isRunningInput, isRunningOutput: isRunningOutput))
        }
        return matches
    }

    static func app(for bundleID: String) -> MeetingApp? {
        targetApps.first { bundleID.hasPrefix($0.bundleIDPrefix) }
    }

    /// The whole detection rule, kept pure so it's testable without a live
    /// CoreAudio graph: a meeting is a known meeting app with the mic open.
    /// Output alone isn't enough - that's Chrome playing YouTube - and the
    /// app merely running isn't enough either, since Chrome and Slack are
    /// always running. False positives are limited to a meeting app using
    /// the mic for something that isn't a call (dictation in a Chrome tab).
    static func detectMeeting(among matches: [MatchedProcess]) -> Meeting? {
        let live = matches.filter { $0.isRunningInput && app(for: $0.bundleID) != nil }
        guard !live.isEmpty else { return nil }

        let liveApps = live.compactMap { app(for: $0.bundleID) }
        let livePrefixes = Set(liveApps.map(\.bundleIDPrefix))
        let group = matches.filter { match in
            livePrefixes.contains { match.bundleID.hasPrefix($0) }
        }

        return Meeting(
            appNames: Array(Set(liveApps.map(\.name))).sorted(),
            bundleIDs: live.map(\.bundleID).sorted(),
            processIDs: group.map(\.id)
        )
    }

    /// The default output device's UID. A tap-only aggregate device delivers
    /// silence, so the aggregate needs a real device as its "master".
    static func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var deviceID: AudioObjectID = 0
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID)
        guard status == noErr else { throw MonitorError.propertyReadFailed(status, address.mSelector) }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        var cfUID: CFString?
        status = withUnsafeMutablePointer(to: &cfUID) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, ptr)
        }
        guard status == noErr, let uid = cfUID as String? else {
            throw MonitorError.propertyReadFailed(status, uidAddress.mSelector)
        }
        return uid
    }

    // MARK: - CoreAudio property reads

    private static func readProcessObjectList() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
        guard status == noErr else { throw MonitorError.propertyReadFailed(status, address.mSelector) }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
        status = ids.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, buffer.baseAddress!)
        }
        guard status == noErr else { throw MonitorError.propertyReadFailed(status, address.mSelector) }
        return ids
    }

    private static func readBundleID(of objectID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var cfString: CFString?
        let status = withUnsafeMutablePointer(to: &cfString) { ptr -> OSStatus in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, ptr)
        }
        guard status == noErr else { throw MonitorError.propertyReadFailed(status, address.mSelector) }
        return (cfString as String?) ?? ""
    }

    private static func readPID(of objectID: AudioObjectID) throws -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        var pid: pid_t = 0
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &pid)
        guard status == noErr else { throw MonitorError.propertyReadFailed(status, address.mSelector) }
        return pid
    }

    private static func readIsRunningInput(of objectID: AudioObjectID) throws -> Bool {
        try readFlag(of: objectID, selector: kAudioProcessPropertyIsRunningInput)
    }

    private static func readIsRunningOutput(of objectID: AudioObjectID) throws -> Bool {
        try readFlag(of: objectID, selector: kAudioProcessPropertyIsRunningOutput)
    }

    private static func readFlag(of objectID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value)
        guard status == noErr else { throw MonitorError.propertyReadFailed(status, address.mSelector) }
        return value != 0
    }
}
