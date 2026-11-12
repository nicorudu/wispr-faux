import SwiftUI

@main
struct WisprFauxPhoneApp: App {
    @State private var controller = SessionController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(controller)
                .onOpenURL { url in
                    if url.scheme == "wisprfaux", url.host == "session" { controller.openedFromKeyboard() }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { controller.becameActive() }
                }
        }
    }
}
