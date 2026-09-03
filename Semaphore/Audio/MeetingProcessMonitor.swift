import CoreAudio
import Foundation

/// Point-in-time queries against CoreAudio's process-object list to find
/// which running processes belong to a meeting app we know about. The
/// `AudioObjectID`s this returns are what a `ProcessTapSource` taps.
enum MeetingProcessMonitor {
    /// Bundle-ID prefixes for the meeting apps we support. Prefix match
    /// because Chrome and Slack play audio from a helper process whose
    /// bundle ID extends the main app's (e.g. "com.google.Chrome.helper"),
    /// not from the main PID `NSRunningApplication` would give you.
    static let targetBundleIDPrefixes = [
        "us.zoom.",
        "com.google.Chrome",
        "com.tinyspeck.slackmacgap",
    ]

    struct MatchedProcess: Identifiable, Sendable {
        let id: AudioObjectID
        let pid: pid_t
        let bundleID: String
        let isRunningOutput: Bool
    }

    enum MonitorError: Error {
        case propertyReadFailed(OSStatus, AudioObjectPropertySelector)
    }

    /// All currently-connected CoreAudio client processes matching our
    /// target apps, whether or not they're actively outputting audio right
    /// now (a Zoom call sitting in a lobby still counts).
    static func matchingProcesses() throws -> [MatchedProcess] {
        let allProcessIDs = try readProcessObjectList()
        var matches: [MatchedProcess] = []
        for objectID in allProcessIDs {
            guard let bundleID = try? readBundleID(of: objectID), !bundleID.isEmpty else { continue }
            guard targetBundleIDPrefixes.contains(where: { bundleID.hasPrefix($0) }) else { continue }
            let pid = (try? readPID(of: objectID)) ?? 0
            let isRunningOutput = (try? readIsRunningOutput(of: objectID)) ?? false
            matches.append(MatchedProcess(id: objectID, pid: pid, bundleID: bundleID, isRunningOutput: isRunningOutput))
        }
        return matches
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

    private static func readIsRunningOutput(of objectID: AudioObjectID) throws -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
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
