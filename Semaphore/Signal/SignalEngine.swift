import Foundation
import Observation

/// The app's brain. Samples both audio ends at a steady rate, runs a voice
/// activity detector over each, feeds the result to the signal state machine,
/// and keeps the turn timer for when you're the one talking.
@MainActor
@Observable
final class SignalEngine {
    private(set) var aspect: Aspect = .dark
    /// Whole seconds you've held the floor, or nil if you aren't talking.
    /// Deliberately integer: the menu bar label redraws whenever this changes,
    /// and once a second is plenty.
    private(set) var speakingSeconds: Int?
    private(set) var farEndSpeaking = false
    private(set) var nearEndSpeaking = false

    var sensitivity: VoiceActivityDetector.Sensitivity {
        didSet {
            guard sensitivity != oldValue else { return }
            farEndDetector.apply(sensitivity: sensitivity)
            nearEndDetector.apply(sensitivity: sensitivity)
            UserDefaults.standard.set(sensitivity.rawValue, forKey: Self.sensitivityKey)
        }
    }

    let audioMonitor = AudioMonitor()

    private var farEndDetector: VoiceActivityDetector
    private var nearEndDetector: VoiceActivityDetector
    private var stateMachine = SignalStateMachine()
    private var tickTimer: Timer?

    /// Your turn ends after this much silence. Longer than the detector's
    /// hangover on purpose: pausing for breath mid-sentence shouldn't reset
    /// the clock, but a genuine handover should.
    private let turnEndGap: TimeInterval = 2.0
    private var turnStartedAt: Date?
    private var lastNearSpeechAt: Date?

    private static let sensitivityKey = "sensitivity"
    private static let tickInterval: TimeInterval = 1.0 / 50.0

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.sensitivityKey)
        let sensitivity = stored.flatMap(VoiceActivityDetector.Sensitivity.init(rawValue:)) ?? .normal
        self.sensitivity = sensitivity
        self.farEndDetector = VoiceActivityDetector(sensitivity: sensitivity)
        self.nearEndDetector = VoiceActivityDetector(sensitivity: sensitivity)
    }

    func start() {
        guard tickTimer == nil else { return }
        audioMonitor.start()
        tickTimer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        audioMonitor.stop()
    }

    /// The detectors' current view of the room, for the popover's debug meters.
    var noiseFloors: (farEnd: Float, nearEnd: Float) {
        (farEndDetector.noiseFloor, nearEndDetector.noiseFloor)
    }

    private func tick(now: Date = Date()) {
        let meetingActive = audioMonitor.isMeetingActive

        guard meetingActive else {
            // No signal left to decay: drop straight out rather than letting
            // the hangover keep a stale "speaking" alive across meetings.
            farEndDetector.reset()
            nearEndDetector.reset()
            endTurn()
            update(\.farEndSpeaking, to: false)
            update(\.nearEndSpeaking, to: false)
            update(\.aspect, to: stateMachine.aspect(
                meetingActive: false, nearSpeaking: false, farSpeaking: false, now: now
            ))
            return
        }

        let levels = audioMonitor.sampleLevels()
        let far = farEndDetector.update(dBFS: levels.farEnd, now: now)
        let near = nearEndDetector.update(dBFS: levels.nearEnd, now: now)

        update(\.farEndSpeaking, to: far)
        update(\.nearEndSpeaking, to: near)
        updateTurnTimer(nearSpeaking: near, now: now)
        update(\.aspect, to: stateMachine.aspect(
            meetingActive: true, nearSpeaking: near, farSpeaking: far, now: now
        ))
    }

    private func updateTurnTimer(nearSpeaking: Bool, now: Date) {
        if nearSpeaking {
            if turnStartedAt == nil { turnStartedAt = now }
            lastNearSpeechAt = now
        } else if let last = lastNearSpeechAt, now.timeIntervalSince(last) > turnEndGap {
            endTurn()
            return
        }

        let seconds = turnStartedAt.map { Int(now.timeIntervalSince($0)) }
        update(\.speakingSeconds, to: seconds)
    }

    private func endTurn() {
        turnStartedAt = nil
        lastNearSpeechAt = nil
        update(\.speakingSeconds, to: nil)
    }

    /// Assign only on change. `@Observable` notifies on every write, and this
    /// runs 50 times a second — writing unconditionally would redraw the menu
    /// bar at 50 Hz for no reason.
    private func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<SignalEngine, Value>, to value: Value) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }
}
