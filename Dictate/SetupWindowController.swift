import AppKit
import SwiftUI

/// Hosts `SetupView` in a plain AppKit window. A SwiftUI `Window` scene can't be opened
/// at launch on macOS 14 from a menu-bar-only app, so this is managed by hand.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    private let controller: DictationController
    private var window: NSWindow?

    init(controller: DictationController) {
        self.controller = controller
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        controller.isSetupWindowVisible = true
        // Menu-bar-only apps don't come to the front on their own.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        controller.isSetupWindowVisible = false
    }

    private func makeWindow() -> NSWindow {
        let view = SetupView(controller: controller) { [weak self] in
            self?.window?.close()
        }
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = .preferredContentSize

        let window = NSWindow(contentViewController: hosting)
        window.title = "Set Up Dictate"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }
}

enum AppRelauncher {
    /// Starts a fresh copy once this one has quit. macOS often only applies a new Input
    /// Monitoring grant to a newly launched process.
    @MainActor
    static func relaunch() {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        do {
            try shell.run()
            NSApp.terminate(nil)
        } catch {
            NSSound.beep()
        }
    }
}
