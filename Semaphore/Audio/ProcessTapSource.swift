import CoreAudio
import AudioToolbox
import Foundation

/// Captures a stereo mixdown of one or more processes' output audio via a
/// CoreAudio process tap (macOS 14.2+) and reports a running RMS level in
/// dBFS through `LevelMeter`. `start(processes:)` is where the first
/// `NSAudioCaptureUsageDescription` (System Audio Recording) permission
/// prompt fires, and it blocks until that's resolved - call it off the
/// main thread.
final class ProcessTapSource: @unchecked Sendable {
    enum TapError: Error, CustomStringConvertible {
        case createTapFailed(OSStatus)
        case createAggregateFailed(OSStatus)
        case createIOProcFailed(OSStatus)
        case startFailed(OSStatus)
        case noMatchingProcesses

        var description: String {
            switch self {
            case .createTapFailed(let status): return "AudioHardwareCreateProcessTap failed (\(status))"
            case .createAggregateFailed(let status): return "AudioHardwareCreateAggregateDevice failed (\(status))"
            case .createIOProcFailed(let status): return "AudioDeviceCreateIOProcIDWithBlock failed (\(status))"
            case .startFailed(let status): return "AudioDeviceStart failed (\(status))"
            case .noMatchingProcesses: return "no meeting app processes to tap"
            }
        }
    }

    let levelMeter = LevelMeter()

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "fyi.kaegan.semaphore.audio-io", qos: .userInteractive)

    private(set) var isRunning = false

    /// Builds a tap covering exactly the given processes and starts pulling
    /// audio. Intended to be called from a single serial caller
    /// (`AudioMonitor`) - it isn't safe to call concurrently with itself or
    /// with `stop()`.
    func start(processes: [AudioObjectID]) throws {
        guard !processes.isEmpty else { throw TapError.noMatchingProcesses }
        try start(description: CATapDescription(stereoMixdownOfProcesses: processes))
    }

    /// Taps everything the Mac is playing, for calls in apps we don't know
    /// how to detect. Music or a video will drive the signal too, which is
    /// why this is only ever switched on by hand.
    func startGlobal() throws {
        try start(description: CATapDescription(stereoGlobalTapButExcludeProcesses: []))
    }

    private func start(description: CATapDescription) throws {
        stop()

        description.name = "Semaphore Tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        let uuid = UUID()
        description.uuid = uuid

        var newTapID: AudioObjectID = kAudioObjectUnknown
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr else { throw TapError.createTapFailed(status) }
        tapID = newTapID

        let outputUID = try MeetingProcessMonitor.defaultOutputDeviceUID()
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Semaphore Aggregate",
            kAudioAggregateDeviceUIDKey as String: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: uuid.uuidString,
                    kAudioSubTapDriftCompensationKey as String: true,
                ]
            ],
        ]

        var newAggregateID: AudioObjectID = kAudioObjectUnknown
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
            throw TapError.createAggregateFailed(status)
        }
        aggregateDeviceID = newAggregateID

        let meter = levelMeter
        var newIOProcID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateDeviceID, ioQueue) { _, inputData, _, _, _ in
            ProcessTapSource.processBuffer(inputData, into: meter)
        }
        guard status == noErr, let procID = newIOProcID else {
            tearDownDevices()
            throw TapError.createIOProcFailed(status)
        }
        ioProcID = procID

        status = AudioDeviceStart(aggregateDeviceID, ioProcID)
        guard status == noErr else {
            tearDownDevices()
            throw TapError.startFailed(status)
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        tearDownDevices()
        isRunning = false
    }

    deinit {
        tearDownDevices()
    }

    /// Teardown must happen in this order: stop the IO proc, then destroy
    /// it, then the aggregate device, then finally the tap itself - the
    /// aggregate references the tap by UUID, and the IOProc references the
    /// aggregate.
    private func tearDownDevices() {
        if let procID = ioProcID {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            ioProcID = nil
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    /// Runs on the real-time IO thread: compute RMS across every channel and
    /// frame in the buffer list and publish it as dBFS. No allocation, no
    /// locks beyond the one inside `LevelMeter.update`.
    private static func processBuffer(_ bufferList: UnsafePointer<AudioBufferList>, into meter: LevelMeter) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        var sumSquares: Double = 0
        var sampleCount = 0

        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let frameCount = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
            guard frameCount > 0 else { continue }
            let samples = data.assumingMemoryBound(to: Float32.self)
            for i in 0..<frameCount {
                let sample = Double(samples[i])
                sumSquares += sample * sample
            }
            sampleCount += frameCount
        }

        guard sampleCount > 0 else { return }
        let rms = (sumSquares / Double(sampleCount)).squareRoot()
        let dBFS = 20 * log10(max(rms, 1e-9))
        meter.update(dBFS: Float(dBFS))
    }
}
