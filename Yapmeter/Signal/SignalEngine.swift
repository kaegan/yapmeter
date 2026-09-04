import Foundation
import Observation
import os

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
    /// Mirrors `AudioMonitor.isHearingFarEnd` as observable state, so the menu
    /// can explain a dark lamp during a meeting. The monitor's own property
    /// reads a lock rather than observable storage, so SwiftUI can't track it.
    private(set) var isFarEndAudible = true

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
    private var turnClock = TurnClock()
    private var tickTimer: Timer?

    private static let sensitivityKey = "sensitivity"
    private static let logger = Logger(subsystem: "fyi.kaegan.yapmeter", category: "signal")
    private var lastLevelLogAt = Date.distantPast
    private static let tickInterval: TimeInterval = 1.0 / 50.0

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.sensitivityKey)
        let sensitivity = stored.flatMap(VoiceActivityDetector.Sensitivity.init(rawValue:)) ?? .normal
        self.sensitivity = sensitivity
        // The far end gets a shorter onset than the near end's default: it
        // drives the block lamp, not the turn timer, and the lamp's dwell
        // (1.2s) plus the detector's hangover (0.7s) is already close to the
        // near end's 0.6s onset - stacking the full onset on top would let an
        // ordinary mid-sentence pause on their end flash the lamp clear.
        self.farEndDetector = VoiceActivityDetector(sensitivity: sensitivity, onsetEvidence: 0.25)
        self.nearEndDetector = VoiceActivityDetector(sensitivity: sensitivity)
    }

    func start() {
        guard tickTimer == nil else { return }
        audioMonitor.start()
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        // Common modes, or the signal freezes while the menu is open: a
        // default-mode timer doesn't fire during menu tracking.
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        audioMonitor.stop()
    }

    private func tick(now: Date = Date()) {
        guard audioMonitor.isMeetingActive else {
            // No signal left to decay: drop straight out rather than letting
            // the hangover keep a stale "speaking" alive across meetings.
            farEndDetector.reset()
            nearEndDetector.reset()
            turnClock.reset()
            update(\.speakingSeconds, to: nil)
            update(\.farEndSpeaking, to: false)
            update(\.nearEndSpeaking, to: false)
            update(\.isFarEndAudible, to: true)
            update(\.aspect, to: stateMachine.aspect(
                meetingActive: false, nearSpeaking: false, farSpeaking: false, now: now
            ))
            return
        }

        // An end that hasn't delivered audio yet keeps its last decision
        // (false, after a reset) rather than being fed silence it never heard.
        let levels = audioMonitor.sampleLevels()
        let near = levels.nearEnd.map { nearEndDetector.update(dBFS: $0, now: now) } ?? nearEndDetector.isSpeaking

        // A far-end tap that has stopped delivering feeds the detector nothing
        // but silence, which would decay into a confident "clear". Reset it
        // instead, so it comes back from scratch when the tap is repaired.
        let hearingFarEnd = audioMonitor.isHearingFarEnd
        var far = false
        if hearingFarEnd {
            far = levels.farEnd.map { farEndDetector.update(dBFS: $0, now: now) } ?? farEndDetector.isSpeaking
        } else {
            farEndDetector.reset()
        }
        logLevels(levels, far: far, near: near, now: now)

        update(\.farEndSpeaking, to: far)
        update(\.nearEndSpeaking, to: near)
        update(\.isFarEndAudible, to: hearingFarEnd)
        update(\.speakingSeconds, to: turnClock.update(
            speaking: near, speechStartedAt: nearEndDetector.speechStartedAt, now: now
        ))
        update(\.aspect, to: stateMachine.aspect(
            meetingActive: true,
            hearingFarEnd: hearingFarEnd,
            nearSpeaking: near,
            farSpeaking: far,
            now: now
        ))
    }

    /// Once a second, for when the detector misbehaves in a room you can't
    /// reproduce in a test. Debug level, so it only shows under
    /// `log stream --predicate 'subsystem == "fyi.kaegan.yapmeter"' --level debug`.
    private func logLevels(_ levels: AudioMonitor.Levels, far: Bool, near: Bool, now: Date) {
        guard now.timeIntervalSince(lastLevelLogAt) >= 1 else { return }
        lastLevelLogAt = now
        let nearText = levels.nearEnd.map { String(format: "%.1f", $0) } ?? "none"
        let farText = levels.farEnd.map { String(format: "%.1f", $0) } ?? "none"
        Self.logger.debug(
            "near \(nearText, privacy: .public) dBFS floor \(self.nearEndDetector.noiseFloor, format: .fixed(precision: 1), privacy: .public) evidence \(self.nearEndDetector.evidence, format: .fixed(precision: 2), privacy: .public) speaking \(near, privacy: .public) | far \(farText, privacy: .public) dBFS floor \(self.farEndDetector.noiseFloor, format: .fixed(precision: 1), privacy: .public) speaking \(far, privacy: .public)"
        )
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
