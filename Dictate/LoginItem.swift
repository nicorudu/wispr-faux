import Foundation
import Observation
import os
import ServiceManagement

/// "Open Dictate at login", through `SMAppService` (System Settings → General → Login
/// Items). Only the copy in /Applications may register, so a development build never
/// becomes the login item.
@MainActor
@Observable
final class LoginItem {
    private(set) var isEnabled = false
    /// The user turned Dictate off in System Settings → Login Items; only they can undo it.
    private(set) var needsApproval = false
    private(set) var lastError: String?

    @ObservationIgnored private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Dictate", category: "LoginItem")

    init() {
        refresh()
    }

    /// Whether this is the installed copy rather than a build in the project folder.
    var isInstalledCopy: Bool {
        Bundle.main.bundleURL.deletingLastPathComponent().path == "/Applications"
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        guard isInstalledCopy else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
            log.notice("Open at login \(enabled ? "on" : "off", privacy: .public)")
        } catch {
            lastError = error.localizedDescription
            log.error("Couldn't change Open at login: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
