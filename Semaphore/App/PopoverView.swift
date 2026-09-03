import SwiftUI

/// The departure-board style popover shown when the menu bar item is clicked.
/// Milestone 1: shows the current aspect only. The occupancy strip and
/// learned-dwell readout are added once the audio pipeline exists.
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

            Button("Quit Semaphore") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(.caption, design: .monospaced))
        }
        .padding(16)
        .frame(width: 220)
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
