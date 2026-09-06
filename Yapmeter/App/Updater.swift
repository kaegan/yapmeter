import AppKit
import Combine
import Observation
import Sparkle

/// Sparkle, in the shape the menu wants: a flag for whether a check can start
/// right now, a call that starts one, and a version string when one is
/// waiting for the menu to say so.
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

    /// The version of an update Sparkle found but is deferring to us rather
    /// than showing itself (`SparkleDelegate` always declines the scheduled
    /// alert - see its comment). Nil once nobody needs telling: no update, or
    /// the existing "Check for Updates…" flow has already put it in front of
    /// the user. The menu shows this above that item rather than opening
    /// anything on its own, so a scheduled find never appears mid-meeting.
    private(set) var pendingUpdateVersion: String?

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private let sparkleDelegate = SparkleDelegate()
    @ObservationIgnored private var observation: AnyCancellable?

    /// Whether a meeting is running right now, as `YapmeterApp` last reported
    /// it. False (no meeting) is the correct assumption before the first
    /// report arrives, since a cold launch has heard nothing yet.
    @ObservationIgnored private var meetingActive = false
    @ObservationIgnored private var lastMeetingEndedAt: Date?
    /// Set once Sparkle has an update downloaded and ready, by way of
    /// `SparkleDelegate.updater(_:willInstallUpdateOnQuit:...)`. Firing it
    /// replaces the app and relaunches it with no further UI, so it only
    /// happens once `UpdateReadiness` agrees to it.
    @ObservationIgnored private var pendingInstall: (() -> Void)?
    @ObservationIgnored private var settleTimer: Timer?

    init() {
        // startingUpdater: true schedules the periodic checks as well as
        // wiring up the manual one.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: sparkleDelegate,
            userDriverDelegate: sparkleDelegate
        )
        canCheckForUpdates = controller.updater.canCheckForUpdates
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] canCheck in
                MainActor.assumeIsolated { self?.canCheckForUpdates = canCheck }
            }
        sparkleDelegate.owner = self
    }

    func checkForUpdates() {
        // Yapmeter is an LSUIElement app, so it is never the active app when
        // the menu is open, and Sparkle's window would otherwise open behind
        // whatever the user was looking at.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    /// Fed by `YapmeterApp` whenever whether a meeting is running changes.
    /// `Updater` never reads `SignalEngine` itself; the app layer does the
    /// translation so this stays a plain boolean in, nothing out.
    func meetingStateChanged(active: Bool, now: Date = Date()) {
        guard active != meetingActive else { return }
        meetingActive = active
        if active {
            settleTimer?.invalidate()
        } else {
            lastMeetingEndedAt = now
            scheduleSettleCheck()
        }
        installIfReady(now: now)
    }

    /// A staged install only gets re-considered when something changes
    /// (a meeting starting or ending) or when the settle window from the
    /// last one finishes; nothing else is watching the clock in between.
    private func scheduleSettleCheck() {
        settleTimer?.invalidate()
        let timer = Timer(timeInterval: UpdateReadiness.settleInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.installIfReady() }
        }
        RunLoop.main.add(timer, forMode: .common)
        settleTimer = timer
    }

    private func installIfReady(now: Date = Date()) {
        guard let install = pendingInstall else { return }
        guard UpdateReadiness.mayInstall(meetingActive: meetingActive, lastMeetingEndedAt: lastMeetingEndedAt, now: now) else { return }
        pendingInstall = nil
        install()
    }

    fileprivate func updateBecameAvailable(version: String) {
        pendingUpdateVersion = version
    }

    fileprivate func clearPendingUpdate() {
        pendingUpdateVersion = nil
    }

    fileprivate func stageInstall(_ install: @escaping () -> Void) {
        pendingInstall = install
        installIfReady()
    }
}

/// The Objective-C half of Sparkle's delegate protocols: both require
/// `NSObjectProtocol`, which a plain `@Observable` class doesn't get for
/// free, so this small forwarder holds the conformance and `Updater` stays
/// pure Swift.
///
/// `SPUUpdaterDelegate` is imported as main-actor-isolated (Sparkle marks it
/// `NS_SWIFT_UI_ACTOR`), which the compiler then infers for this whole class
/// - including the `SPUStandardUserDriverDelegate` methods below, whose
/// protocol carries no such isolation. Each is marked `nonisolated` to
/// override that inference back to what its protocol actually promises, and
/// hops onto `Updater` itself with `assumeIsolated`: safe because Sparkle's
/// own driver asserts throughout that it calls these on the main thread.
private final class SparkleDelegate: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    weak var owner: Updater?

    // Tells Sparkle we've implemented gentle reminders at all, silencing the
    // "users may not take notice" warning it logs for a background app that
    // hasn't. See https://sparkle-project.org/documentation/gentle-reminders.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    // Always decline: Yapmeter is `LSUIElement`, so Sparkle's own fallback
    // for a scheduled find is to show its alert ordered *behind* whatever's
    // in front (boundary 6 says no window during a call at all, not merely
    // one out of the way). Never called for a user-initiated check, so
    // "Check for Updates…" is untouched by this.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    // The doc for the method above asks that side effects happen here
    // instead. `handleShowingUpdate` is false exactly when we declined above.
    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        MainActor.assumeIsolated { owner?.updateBecameAvailable(version: update.displayVersionString) }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { owner?.clearPendingUpdate() }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { owner?.clearPendingUpdate() }
    }

    // Sparkle calls this once an automatic download is ready to install
    // silently. Returning true takes over from Sparkle's own "install at
    // quit" (which still happens as a fallback if we never call the
    // handler - see the header doc), so we can fire it the moment
    // `UpdateReadiness` allows instead of waiting for a quit that a
    // launch-at-login app may not see for weeks. Left main-actor-isolated
    // (inferred from `SPUUpdaterDelegate` above), which is what its own
    // protocol declares, so this one needs no `assumeIsolated` hop.
    func updater(
        _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        owner?.stageInstall(immediateInstallHandler)
        return true
    }
}
