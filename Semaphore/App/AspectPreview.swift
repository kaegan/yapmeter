import Foundation
import Observation

/// Walks the lamp through every state on a timer, so a glyph and palette can
/// be judged in the real menu bar without waiting for a meeting. Nothing here
/// touches the audio engine: while the preview runs the app draws these
/// values instead of the engine's, and it stops itself the moment a real
/// meeting starts.
@MainActor
@Observable
final class AspectPreview {
    private(set) var isRunning = false
    private(set) var aspect: Aspect = .dark
    private(set) var speakingSeconds: Int?

    /// For the menu's checkbox.
    var isOn: Bool {
        get { isRunning }
        set { newValue ? start() : stop() }
    }

    private var timer: Timer?
    private var index = 0

    /// One frame per second, in the order a meeting would show them. The two
    /// speaking runs let the clock be seen counting, and the second one is
    /// long enough to get the pets' "full" drawing.
    static let frames: [(aspect: Aspect, speakingSeconds: Int?)] = {
        var frames: [(aspect: Aspect, speakingSeconds: Int?)] = []
        func hold(_ aspect: Aspect, for seconds: Int) {
            for _ in 0..<seconds { frames.append((aspect, nil)) }
        }
        hold(.dark, for: 2)
        hold(.occupied, for: 3)
        hold(.caution, for: 2)
        hold(.preliminary, for: 1)
        hold(.clear, for: 3)
        for second in 40...44 { frames.append((.speaking, second)) }
        for second in 0..<4 { frames.append((.speaking, SignalHeadRenderer.longTurnSeconds + 32 + second)) }
        return frames
    }()

    func start() {
        guard !isRunning else { return }
        isRunning = true
        index = 0
        show(Self.frames[0])
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.advance()
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        timer?.invalidate()
        timer = nil
        isRunning = false
        index = 0
        show((.dark, nil))
    }

    /// One tick of the preview. Public so tests can drive it without the timer.
    func advance() {
        guard isRunning else { return }
        index = (index + 1) % Self.frames.count
        show(Self.frames[index])
    }

    private func show(_ frame: (aspect: Aspect, speakingSeconds: Int?)) {
        if aspect != frame.aspect { aspect = frame.aspect }
        if speakingSeconds != frame.speakingSeconds { speakingSeconds = frame.speakingSeconds }
    }
}
