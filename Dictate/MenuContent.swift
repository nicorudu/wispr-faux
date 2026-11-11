import SwiftUI

struct MenuContent: View {
    let controller: DictationController

    var body: some View {
        Text("Status: \(controller.state.label)")

        Divider()

        // Enabled in Step 6, once history is populated by real dictations.
        Button("Paste Last Transcript") {}
            .disabled(true)

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit Dictate") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
