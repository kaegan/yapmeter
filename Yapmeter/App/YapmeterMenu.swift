import AppKit
import SwiftUI

/// The menu behind the status item. A status line saying what the app is
/// doing right now (the one thing the lamp can't tell you: *why* it's dark),
/// then settings. Nothing else to report in here that the icon didn't
/// already say.
struct YapmeterMenu: View {
    @Bindable var engine: SignalEngine
    @Bindable var preview: AspectPreview
    @Bindable var updater: Updater

    var body: some View {
        Text(statusText)
        // One plain line under the status when the speech model isn't ready,
        // so a timer that's running on the energy gate alone says so. Nothing
        // is shown in the ordinary case.
        if let line = speechModelLine {
            Text(line)
        }
        // The permission button outranks the microphone one: with the far end
        // dead there is nothing to time turns against, so it's the thing to
        // fix first.
        if engine.audioMonitor.isFarEndSilent {
            Button("Open System Audio Settings…", action: openSystemAudioSettings)
        } else if case .microphoneUnavailable = engine.audioMonitor.status {
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
        // Cycles the pet through every state so a change to his drawing can
        // be judged without a meeting. Turns itself off when a real one
        // starts. Behind a Developer item because nobody else needs it.
        Menu("Developer") {
            Toggle("Preview states", isOn: $preview.isOn)
        }
        Divider()
        // A scheduled check found this without ever putting a window on
        // screen (`SparkleDelegate`); this is the one place it says so. The
        // same call as the row below brings Sparkle's own window forward,
        // now that the user is the one asking.
        if let version = updater.pendingUpdateVersion {
            Button("Update to \(version)…") { updater.checkForUpdates() }
        }
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
        // An LSUIElement app has no app menu, so this is the only ⌘Q there is.
        Button("Quit Yapmeter") { NSApp.terminate(nil) }
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
        // Before everything else, including the override: a tap that hears
        // nothing is the reason the lamp is dark, whatever it's tapping.
        if monitor.isFarEndSilent {
            return "System Audio Recording is off, so Yap can't hear the meeting"
        }
        if monitor.listenToAllAudio {
            guard let until = monitor.listenToAllAudioUntil else { return "Listening to all audio" }
            return "Listening to all audio until \(until.formatted(date: .omitted, time: .shortened))"
        }
        switch monitor.status {
        case .waitingForMeeting: return "Waiting for a meeting"
        case .starting: return "Starting…"
        case .running(let bundleIDs): return "Listening to \(appList(bundleIDs))"
        case .microphoneUnavailable: return "Microphone unavailable, so the turn timer is off"
        // Distinct from the permission line above on purpose: this one is
        // CoreAudio refusing to start, which no settings pane will fix.
        case .error: return "Couldn't start the meeting audio capture"
        }
    }

    /// What the on-device model is doing, when it's doing anything worth
    /// saying. Plain and literal: this is a limitation line, not Yap's.
    private var speechModelLine: String? {
        switch engine.audioMonitor.witnessAvailability {
        case .ready: return nil
        case .downloading: return "Downloading the speech model…"
        case .downloadFailed: return "Couldn't download the speech model. The timer runs on sound alone."
        case .unsupported: return "Your language has no on-device speech model. The timer runs on sound alone."
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
        openSettings(anchor: "Privacy_Microphone")
    }

    /// Opens the Screen & System Audio Recording pane and earns the one retry
    /// the tap gets: the permission takes effect without a relaunch, but only
    /// for a tap built after it was granted, and nothing here retries on its
    /// own.
    private func openSystemAudioSettings() {
        engine.audioMonitor.armCaptureRetry()
        openSettings(anchor: "Privacy_AudioCapture")
    }

    private func openSettings(anchor: String) {
        let pane = "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        if let url = URL(string: pane) {
            NSWorkspace.shared.open(url)
        }
    }
}
