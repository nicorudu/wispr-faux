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

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
        if !controller.permissions.allGranted {
            showSetup()
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
}
