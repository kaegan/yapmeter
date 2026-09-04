import SwiftUI

/// The departure-board popover shown when the menu bar item is clicked:
/// the full signal head, what it means, your turn timer, and the one control
/// worth exposing (how readily we call something speech).
struct PopoverView: View {
    @Bindable var engine: SignalEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            SignalHeadView(aspect: engine.aspect)
                .frame(maxWidth: .infinity, alignment: .center)
            statusLines
            if engine.speakingSeconds != nil {
                turnTimer
            }
            Divider()
            sensitivityControl
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 280)
    }

    private var header: some View {
        HStack {
            Text("SEMAPHORE")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Text(engine.audioMonitor.isMeetingActive ? "IN SERVICE" : "STANDBY")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private var statusLines: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(engine.aspect.displayName)
                .font(.system(.title3, design: .monospaced, weight: .bold))
                .foregroundStyle(color(for: engine.aspect))
            Text(engine.aspect.subtitle)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var turnTimer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(SignalHeadRenderer.timeLabel(engine.speakingSeconds ?? 0))
                .font(.system(size: 28, weight: .light, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.blue)
            Text("this turn")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var sensitivityControl: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("SENSITIVITY")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            Picker("", selection: $engine.sensitivity) {
                ForEach(VoiceActivityDetector.Sensitivity.allCases, id: \.self) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("Lower this in a noisy room.")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(statusText(for: engine.audioMonitor.status))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if engine.audioMonitor.isMeetingActive {
                levelRow(label: "them", dBFS: engine.audioMonitor.farEndDBFS,
                         floor: engine.noiseFloors.farEnd, isSpeaking: engine.farEndSpeaking)
                levelRow(label: "you ", dBFS: engine.audioMonitor.nearEndDBFS,
                         floor: engine.noiseFloors.nearEnd, isSpeaking: engine.nearEndSpeaking)
            }

            Button("Quit Semaphore") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(.caption, design: .monospaced))
            .padding(.top, 2)
        }
    }

    /// Level bar with the detector's current noise floor marked on it, so it's
    /// visible why something did or didn't count as speech.
    private func levelRow(label: String, dBFS: Float, floor: Float, isSpeaking: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(isSpeaking ? .primary : .tertiary)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(isSpeaking ? Color.green : Color.secondary)
                        .frame(width: proxy.size.width * CGFloat(fraction(of: dBFS)))
                    Rectangle()
                        .fill(.orange.opacity(0.7))
                        .frame(width: 1)
                        .offset(x: proxy.size.width * CGFloat(fraction(of: floor)))
                }
            }
            .frame(height: 5)
        }
    }

    /// Map -70...0 dBFS onto 0...1. Wider than a normal meter because the
    /// noise floor marker lives down in the -60s.
    private func fraction(of dBFS: Float) -> Float {
        max(0, min(1, (dBFS + 70) / 70))
    }

    private func statusText(for status: AudioMonitor.Status) -> String {
        switch status {
        case .waitingForMeeting: return "watching for Zoom / Meet / Slack audio"
        case .starting: return "requesting audio access…"
        case .running(let bundleIDs): return "tapping: \(bundleIDs.joined(separator: ", "))"
        case .microphoneUnavailable(let message): return "no turn timer — \(message)"
        case .error(let message): return "error: \(message)"
        }
    }

    private func color(for aspect: Aspect) -> Color {
        Color(nsColor: SignalHeadRenderer.color(for: aspect))
    }
}
