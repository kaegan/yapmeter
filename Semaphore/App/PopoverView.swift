import SwiftUI

/// The departure-board style popover shown when the menu bar item is
/// clicked. Milestone 1 shows the current aspect only; Milestone 2 adds a
/// debug section to prove the CoreAudio tap is alive before Milestone 3
/// wires it to the signal state machine and this debug section goes away.
struct PopoverView: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SEMAPHORE")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            Text(appState.aspect.displayName)
                .font(.system(.title2, design: .monospaced, weight: .bold))
                .foregroundStyle(color(for: appState.aspect))

            Divider()

            Text(appState.aspect == .caution ? "Mind the gap." : " ")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            Divider()

            audioDebugSection

            Divider()

            Button("Quit Semaphore") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(.caption, design: .monospaced))
        }
        .padding(16)
        .frame(width: 260)
    }

    @ViewBuilder
    private var audioDebugSection: some View {
        let monitor = appState.audioMonitor
        VStack(alignment: .leading, spacing: 6) {
            Text("AUDIO TAP (debug)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)

            Text(statusText(for: monitor.status))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if case .running = monitor.status {
                Text(String(format: "%.1f dBFS", monitor.dBFS))
                    .font(.system(.caption, design: .monospaced))
                levelBar(dBFS: monitor.dBFS)
            }

            Button(toggleButtonTitle(for: monitor.status)) {
                monitor.toggle()
            }
            .buttonStyle(.plain)
            .font(.system(.caption, design: .monospaced))
            .disabled(monitor.status == .starting)
        }
    }

    private func levelBar(dBFS: Float) -> some View {
        // Map -60...0 dBFS onto a 0...1 fill; below -60 reads as silence.
        let fraction = max(0, min(1, (dBFS + 60) / 60))
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.green).frame(width: proxy.size.width * CGFloat(fraction))
            }
        }
        .frame(height: 6)
    }

    private func statusText(for status: AudioMonitor.Status) -> String {
        switch status {
        case .idle: return "not running"
        case .noMeetingAppFound: return "no Zoom/Chrome/Slack audio process found"
        case .starting: return "requesting audio access…"
        case .running(let bundleIDs): return "tapping: \(bundleIDs.joined(separator: ", "))"
        case .error(let message): return "error: \(message)"
        }
    }

    private func toggleButtonTitle(for status: AudioMonitor.Status) -> String {
        if case .running = status {
            return "Stop Tap"
        }
        return "Start Tap"
    }

    private func color(for aspect: Aspect) -> Color {
        switch aspect {
        case .dark: return .secondary
        case .occupied: return .red
        case .caution, .preliminary: return .yellow
        case .clear: return .green
        }
    }
}
