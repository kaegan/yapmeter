import AppKit
import SwiftUI

/// The menu behind the status item. Settings only: the menu bar lamp is the
/// whole display, so there's nothing to report in here that the icon didn't
/// already say. The one exception is a problem worth acting on, which gets a
/// line and, where there's somewhere to send you, a button.
struct SemaphoreMenu: View {
    @Bindable var engine: SignalEngine
    @Bindable var style: MenuBarStyle

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
        // Submenus, not more headers: eight glyphs and three palettes would
        // otherwise be most of the menu, and they're a trial, not a setting
        // anyone changes twice a day.
        Menu("Glyph") {
            ForEach(GlyphStyle.allCases, id: \.self) { glyph in
                Toggle(glyph.displayName, isOn: selection(for: glyph))
            }
        }
        Menu("Colours") {
            ForEach(LampPalette.allCases, id: \.self) { palette in
                Toggle(palette.displayName, isOn: selection(for: palette))
            }
        }
        Divider()
        // An LSUIElement app has no app menu, so this is the only ⌘Q there is.
        Button("Quit Semaphore") { NSApp.terminate(nil) }
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

    private func selection(for glyph: GlyphStyle) -> Binding<Bool> {
        Binding(
            get: { style.glyph == glyph },
            set: { isOn in if isOn { style.glyph = glyph } }
        )
    }

    private func selection(for palette: LampPalette) -> Binding<Bool> {
        Binding(
            get: { style.palette == palette },
            set: { isOn in if isOn { style.palette = palette } }
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
