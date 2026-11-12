import Foundation
import Observation
import os
import ServiceManagement

/// "Open Wispr Faux at login", through a launch agent registered with `SMAppService`
/// (listed in System Settings → General → Login Items). The agent, in
/// Contents/Library/LaunchAgents, starts Wispr Faux at login and relaunches it if it ever
/// crashes; a normal quit isn't undone. Only the copy in /Applications may register, so a
/// development build never becomes the login item.
@MainActor
@Observable
final class LoginItem {
    static let agentLabel = "com.example.wisprfaux.agent"

    private(set) var isEnabled = false
    /// The user turned Wispr Faux off in System Settings → Login Items; only they can undo it.
    private(set) var needsApproval = false
    private(set) var lastError: String?

    @ObservationIgnored private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Wispr Faux", category: "LoginItem")

    private var agent: SMAppService { SMAppService.agent(plistName: "\(Self.agentLabel).plist") }

    init() {
        refresh()
    }

    /// Whether this is the installed copy rather than a build in the project folder.
    var isInstalledCopy: Bool {
        Bundle.main.bundleURL.deletingLastPathComponent().path == "/Applications"
    }

    /// Whether launchd started this process through the agent (and so will relaunch it
    /// after a crash).
    static var launchedByAgent: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == agentLabel
    }

    func refresh() {
        let status = agent.status
        isEnabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        guard isInstalledCopy else { return }
        do {
            if enabled {
                try agent.register()
            } else {
                try agent.unregister()
            }
            lastError = nil
            log.notice("Open at login \(enabled ? "on" : "off", privacy: .public)")
        } catch {
            lastError = error.localizedDescription
            log.error("Couldn't change Open at login: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    /// Earlier versions registered the app itself as the login item, which can't relaunch
    /// it after a crash. Moves that over to the agent, once.
    func migrateFromAppLoginItem() {
        guard isInstalledCopy, SMAppService.mainApp.status == .enabled else { return }
        do {
            try SMAppService.mainApp.unregister()
            log.notice("Moved Open at login from the app login item to the launch agent")
        } catch {
            log.error("Couldn't remove the old login item: \(error.localizedDescription, privacy: .public)")
        }
        setEnabled(true)
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
