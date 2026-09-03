import SwiftUI
import Observation

/// Central app state. Milestone 1: a timer cycles through every aspect so we
/// can prove the menu bar icon renders in color and the popover updates.
/// This timer is deleted once the audio pipeline (Milestones 2-3) is driving
/// `aspect` for real.
@MainActor
@Observable
final class AppState {
    var aspect: Aspect = .dark

    private var demoTimer: Timer?

    func startDemoCycle() {
        var index = 0
        let sequence = Aspect.allCases
        demoTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.aspect = sequence[index % sequence.count]
                index += 1
            }
        }
    }
}

@main
struct SemaphoreApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(appState: appState)
        } label: {
            Image(nsImage: SignalHeadRenderer.image(for: appState.aspect))
        }
        .menuBarExtraStyle(.window)
        .onChange(of: appState.aspect) { _, _ in }
        .defaultAppStorage(.standard)
        .commands { }
        .onAppear {
            appState.startDemoCycle()
        }
    }
}
