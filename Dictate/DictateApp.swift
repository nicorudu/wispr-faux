import AppKit
import SwiftUI

@main
struct DictateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: appDelegate.controller, openSetup: appDelegate.showSetup)
        } label: {
            Image(systemName: appDelegate.controller.state.menuBarSymbol)
        }

        Settings {
            SettingsView(controller: appDelegate.controller, openSetup: appDelegate.showSetup)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = DictationController()
    private lazy var setupWindow = SetupWindowController(controller: controller)
    private lazy var pill = StatusPillController(controller: controller)
    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard claimSingleInstance() else { exit(0) }
        quitCleanlyOnTermSignal()

        controller.start()
        pill.start()
        if !controller.permissions.allGranted {
            showSetup()
        }
        controller.loginItem.migrateFromAppLoginItem()
        // `scripts/install.sh --login` launches the installed copy with this set.
        if UserDefaults.standard.bool(forKey: "EnableOpenAtLogin"), !controller.loginItem.isEnabled {
            controller.loginItem.setEnabled(true)
        }
        #if DEBUG
        // `open Dictate.app --args -DebugRecordSeconds 3` records once at launch.
        let seconds = UserDefaults.standard.double(forKey: "DebugRecordSeconds")
        if seconds > 0 { controller.debugRecord(seconds: seconds) }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    func showSetup() {
        setupWindow.show()
    }

    /// Only one Dictate may run: two would both react to the hotkey. The copy started by
    /// the launch agent wins, since launchd relaunches it after a crash; any other copy
    /// is asked to quit. Otherwise a second copy steps aside. Returns false to exit.
    private func claimSingleInstance() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me }
        guard !others.isEmpty else { return true }
        guard LoginItem.launchedByAgent else { return false }
        for other in others {
            kill(other.processIdentifier, SIGTERM)
        }
        // Give them a moment to put the clipboard back and let go of the hotkey.
        let deadline = Date.now.addingTimeInterval(3)
        while others.contains(where: { !$0.isTerminated }), Date.now < deadline {
            RunLoop.current.run(until: .now.addingTimeInterval(0.05))
        }
        return true
    }

    /// `scripts/install.sh` and `kill` send SIGTERM. Quit normally instead of dying from
    /// it, so the clipboard is restored and the exit counts as clean: the launch agent
    /// relaunches Dictate only after a crash.
    private func quitCleanlyOnTermSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            NSApplication.shared.terminate(nil)
        }
        source.resume()
        terminationSignal = source
    }
}
