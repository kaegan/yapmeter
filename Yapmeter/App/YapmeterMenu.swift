import AppKit
import SwiftUI

/// The menu behind the status item. Settings only: the menu bar lamp is the
/// whole display, so there's nothing to report in here that the icon didn't
/// already say. The one exception is a problem worth acting on, which gets a
/// line and, where there's somewhere to send you, a button.
struct YapmeterMenu: View {
    @Bindable var engine: SignalEngine

    var body: some View {
        if let problem = problemText(for: engine.audioMonitor.status) {
            Text(problem)
            if case .microphoneUnavailable = engine.audioMonitor.status {
                Button("Open Microphone Settings…", action: openMicrophoneSettings)
            }
            Divider()
        }
        // A header plus checkable items, not an inline Picker: the picker's
        // section brackets itself with separators, which leaves a stray
        // hairline across the very top of the menu.
        Text("Sensitivity")
        ForEach(VoiceActivityDetector.Sensitivity.allCases, id: \.self) { level in
            Toggle(level.displayName, isOn: selection(for: level))
        }
        Divider()
        // An LSUIElement app has no app menu, so this is the only ⌘Q there is.
        Button("Quit Yapmeter") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// Radio behaviour: picking a level selects it, and picking the level
    /// that's already on is a no-op rather than a way to select nothing.
    private func selection(for level: VoiceActivityDetector.Sensitivity) -> Binding<Bool> {
        Binding(
            get: { engine.sensitivity == level },
            set: { isOn in if isOn { engine.sensitivity = level } }
        )
    }

    private func problemText(for status: AudioMonitor.Status) -> String? {
        switch status {
        case .microphoneUnavailable: return "Microphone unavailable, so the turn timer is off."
        case .error: return "Couldn't listen to the meeting audio."
        case .waitingForMeeting, .starting, .running: return nil
        }
    }

    private func openMicrophoneSettings() {
        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        if let url = URL(string: pane) {
            NSWorkspace.shared.open(url)
        }
    }
}
