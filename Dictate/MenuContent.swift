import SwiftUI

struct MenuContent: View {
    let controller: DictationController
    let openSetup: @MainActor () -> Void

    var body: some View {
        Text("Status: \(controller.state.label)")
        Text(hotkeyLine)

        if controller.isSecureInputActive, controller.hotkeyStatus == .running {
            Text("⚠︎ Secure input is on in another app")
        }

        Divider()

        // Enabled in Step 6, once history is populated by real dictations.
        Button("Paste Last Transcript") {}
            .disabled(true)

        // Step 3 spike: click into a text field in any app, then choose this.
        Button("Paste Test String", action: controller.pasteTester.run)
            .disabled(controller.pasteTester.isRunning)
        if let line = controller.pasteTester.lastPaste {
            Text(line)
        }
        if let line = controller.pasteTester.lastRestore {
            Text(line)
        }

        Divider()

        // Step 4 spike: hold the hotkey, speak, release, then play it back.
        Text(controller.recordingTester.summary ?? "No recording yet: hold \(controller.triggerDescription) and speak")
        if let line = controller.recordingTester.detail {
            Text(line)
        }
        Button("Play Last Recording", action: controller.recordingTester.play)
            .disabled(controller.recordingTester.wavURL == nil)
        Button("Show Recording in Finder", action: controller.recordingTester.revealInFinder)
            .disabled(controller.recordingTester.wavURL == nil)

        Divider()

        Button(controller.permissions.allGranted ? "Permissions…" : "Finish Setup…", action: openSetup)

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")

        #if DEBUG
        Menu("Debug") {
            Button("Simulate Event-Tap Timeout on Next Key", action: controller.simulateTapTimeout)
            Button("Record 3 Seconds Without the Hotkey") { controller.debugRecord(seconds: 3) }
            Text("Tap re-enabled: \(controller.tapStats.reenableCount)×\(lastReason)")
            Text("Slow callbacks: \(controller.tapStats.slowCallbackCount)")
        }
        #endif

        Divider()

        Button("Quit Dictate") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var hotkeyLine: String {
        switch controller.hotkeyStatus {
        case .running: "Hold \(controller.triggerDescription) to dictate"
        case .waitingForPermission: "Hotkey off: needs Accessibility"
        case .failed: "Hotkey off: relaunch needed"
        }
    }

    private var lastReason: String {
        controller.tapStats.lastReenableReason.map { " (last: \($0))" } ?? ""
    }
}
