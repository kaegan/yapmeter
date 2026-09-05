import AppKit
import Combine
import Observation
import Sparkle

/// Sparkle, in the shape the menu wants: a flag for whether a check can start
/// right now, and a call that starts one.
///
/// The controller has to outlive any one showing of the menu — it runs the
/// scheduled background checks, not only the ones the user asks for — so the
/// app owns it for the process lifetime and the menu only reads it.
@MainActor
@Observable
final class Updater {
    /// False while a check is already in flight, so the menu item dims
    /// instead of stacking a second update window behind the first.
    private(set) var canCheckForUpdates: Bool

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: AnyCancellable?

    init() {
        // startingUpdater: true schedules the periodic checks as well as
        // wiring up the manual one.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        canCheckForUpdates = controller.updater.canCheckForUpdates
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] canCheck in
                MainActor.assumeIsolated { self?.canCheckForUpdates = canCheck }
            }
    }

    func checkForUpdates() {
        // Yapmeter is an LSUIElement app, so it is never the active app when
        // the menu is open, and Sparkle's window would otherwise open behind
        // whatever the user was looking at.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}
