import CoreAudio
import AudioToolbox
import Foundation
import os

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

    /// Whether frames arrived since the last time this was read, and whether
    /// any sample has ever been non-zero. Together they are what tells a tap
    /// blocked by a refused System Audio Recording permission apart from a
    /// quiet one: see `TapSilence`. Written on the IO thread, read from the
    /// main actor once per detect tick.
    private let delivery = DeliveryCounter()

    /// True if the tap handed over frames since the previous call. Consuming,
    /// like `LevelMeter.consumePeak`, so each detect tick asks about its own
    /// interval rather than about all of time.
    func consumeIsDelivering() -> Bool { delivery.consumeDelivered() }

    /// Whether any sample since capture started has been non-zero. A blocked
    /// tap delivers bit-exact zeros and nothing else.
    var hasHeardNonZeroAudio: Bool { delivery.hasHeardNonZeroAudio }

    /// Counts what the IO thread delivered without allocating or blocking it
    /// for longer than `LevelMeter` already does.
    private final class DeliveryCounter: @unchecked Sendable {
        private var lock = os_unfair_lock_s()
        private var _delivered = false
        private var _heardNonZero = false

        func record(nonZero: Bool) {
            os_unfair_lock_lock(&lock)
            _delivered = true
            if nonZero { _heardNonZero = true }
            os_unfair_lock_unlock(&lock)
        }

        func consumeDelivered() -> Bool {
            os_unfair_lock_lock(&lock)
            defer { _delivered = false; os_unfair_lock_unlock(&lock) }
            return _delivered
        }

        var hasHeardNonZeroAudio: Bool {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return _heardNonZero
        }

        func reset() {
            os_unfair_lock_lock(&lock)
            _delivered = false
            _heardNonZero = false
            os_unfair_lock_unlock(&lock)
        }
    }

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "fyi.kaegan.yapmeter.audio-io", qos: .userInteractive)

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

        description.name = "Yapmeter Tap"
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
            kAudioAggregateDeviceNameKey as String: "Yapmeter Aggregate",
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
        let counter = delivery
        var newIOProcID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateDeviceID, ioQueue) { _, inputData, _, _, _ in
            ProcessTapSource.processBuffer(inputData, into: meter, counting: counter)
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
        levelMeter.reset()
        delivery.reset()
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
    ///
    /// Unlike `MicrophoneSource`, this doesn't slice the buffer through
    /// `LevelAnalysis.sustainedDBFS` first: the aggregate device delivers
    /// buffers around 10ms long, too short to slice into anything meaningful,
    /// and this end has no keyboard-click problem to begin with - it only
    /// ever hears what the meeting app plays.
    private static func processBuffer(
        _ bufferList: UnsafePointer<AudioBufferList>,
        into meter: LevelMeter,
        counting delivery: DeliveryCounter
    ) {
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
        // Free: the sum of squares is zero if and only if every sample was,
        // so the blocked-tap evidence costs nothing extra on this thread.
        delivery.record(nonZero: sumSquares > 0)
        meter.update(dBFS: LevelAnalysis.dBFS(rms: rms))
    }
}
