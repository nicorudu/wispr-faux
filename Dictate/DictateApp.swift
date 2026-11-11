import SwiftUI

@main
struct DictateApp: App {
    @State private var controller = DictationController()

    var body: some Scene {
        MenuBarExtra("Dictate", systemImage: controller.state.menuBarSymbol) {
            MenuContent(controller: controller)
        }

        Settings {
            SettingsView()
        }
    }
}
