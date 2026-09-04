import AppKit
import SwiftUI

/// The menu behind the status item. A status line saying what the app is
/// doing right now (the one thing the lamp can't tell you: *why* it's dark),
/// then settings. Nothing else to report in here that the icon didn't
/// already say.
struct SemaphoreMenu: View {
    @Bindable var engine: SignalEngine

    var body: some View {
        Text(statusText)
        if case .microphoneUnavailable = engine.audioMonitor.status {
            Button("Open Microphone Settings…", action: openMicrophoneSettings)
        }
        Divider()
        // Checkable items in a submenu, not an inline Picker: the picker's
        // section brackets itself with separators, which leaves a stray
        // hairline across the very top of the menu. Set-and-forget, so the
        // extra click to reach it costs nothing.
        Menu("Sensitivity") {
            ForEach(VoiceActivityDetector.Sensitivity.allCases, id: \.self) { level in
                Toggle(level.displayName, isOn: selection(for: level))
            }
        }
        // For calls detection can't see (FaceTime, for one). Named for what
        // it does rather than "manual mode", because what it does is the
        // caveat: anything the Mac plays will drive the signal while it's on.
        // The timed options exist so it can't be left on by accident.
        Menu(engine.audioMonitor.listenToAllAudio ? "Listening to All Audio" : "Listen to All Audio") {
            if engine.audioMonitor.listenToAllAudio {
                Button("Turn Off") { engine.audioMonitor.stopListeningToAllAudio() }
                Divider()
            }
            ForEach(Self.listenDurations, id: \.minutes) { option in
                Button(option.label) {
                    engine.audioMonitor.listenToAllAudio(for: TimeInterval(option.minutes * 60))
                }
            }
            Button("Until Turned Off") { engine.audioMonitor.listenToAllAudio(for: nil) }
        }
        Divider()
        Toggle("Launch at Login", isOn: launchAtLogin)
        Divider()
        // An LSUIElement app has no app menu, so this is the only ⌘Q there is.
        Button("Quit Semaphore") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// The usual meeting lengths.
    private static let listenDurations: [(minutes: Int, label: String)] = [
        (15, "For 15 Minutes"),
        (30, "For 30 Minutes"),
        (45, "For 45 Minutes"),
        (60, "For 1 Hour"),
    ]

    /// What the app is doing, in one line. The override outranks detection
    /// because it's what capture is actually running on while it's on.
    private var statusText: String {
        let monitor = engine.audioMonitor
        if monitor.listenToAllAudio {
            guard let until = monitor.listenToAllAudioUntil else { return "Listening to all audio" }
            return "Listening to all audio until \(until.formatted(date: .omitted, time: .shortened))"
        }
        switch monitor.status {
        case .waitingForMeeting: return "Waiting for a meeting"
        case .starting: return "Starting…"
        case .running(let bundleIDs): return "Listening to \(appList(bundleIDs))"
        case .microphoneUnavailable: return "Microphone unavailable, so the turn timer is off"
        case .error: return "Couldn't listen to the meeting audio"
        }
    }

    /// "Zoom", or "Chrome and Slack" when two apps are in calls at once.
    private func appList(_ bundleIDs: [String]) -> String {
        var names: [String] = []
        for id in bundleIDs {
            let name = MeetingProcessMonitor.appName(forBundleID: id)
            if !names.contains(name) { names.append(name) }
        }
        return names.isEmpty ? "the meeting" : names.formatted(.list(type: .and))
    }

    /// Radio behaviour: picking a level selects it, and picking the level
    /// that's already on is a no-op rather than a way to select nothing.
    private func selection(for level: VoiceActivityDetector.Sensitivity) -> Binding<Bool> {
        Binding(
            get: { engine.sensitivity == level },
            set: { isOn in if isOn { engine.sensitivity = level } }
        )
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { LaunchAtLogin.isEnabled },
            set: { LaunchAtLogin.isEnabled = $0 }
        )
    }

    private func openMicrophoneSettings() {
        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        if let url = URL(string: pane) {
            NSWorkspace.shared.open(url)
        }
    }
}
