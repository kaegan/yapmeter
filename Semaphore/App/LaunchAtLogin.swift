import Foundation
import os
import ServiceManagement

/// The standard menu bar app toggle. For an app whose job is to be there
/// when a call starts, this is the difference between working and not.
@MainActor
enum LaunchAtLogin {
    private static let logger = Logger(subsystem: "fyi.kaegan.semaphore", category: "launch")

    static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                logger.error("Launch at login change failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
