import AudioKit
import HotkeyKit
import SwiftUI

struct SettingsView: View {
    let controller: DictationController
    let openSetup: @MainActor () -> Void

    var body: some View {
        Form {
            Section {
                ForEach(HotkeyTrigger.allCases) { trigger in
                    Toggle(trigger.displayName, isOn: binding(for: trigger))
                        // At least one trigger stays on.
                        .disabled(controller.enabledTriggers == [trigger])
                }
            } header: {
                Text("Hold to talk")
            } footer: {
                Text("Fn is best on Mac keyboards. Turn on a right-hand key for keyboards without Fn.")
                    .foregroundStyle(.secondary)
            }

            Section("Shortcuts") {
                LabeledContent("Hands-free", value: "Hold key + Space")
                LabeledContent("Stop hands-free", value: "Press the key again")
                LabeledContent("Cancel", value: "Esc")
            }

            Section("Transcription") {
                LabeledContent("Engine", value: "On-device (WhisperKit, Step 5)")
                LabeledContent("Capture format", value: "\(Int(AudioFormat.sampleRate / 1000)) kHz mono")
            }

            Section("Permissions") {
                ForEach(Permission.allCases) { permission in
                    LabeledContent(permission.title) {
                        Text(controller.permissions.status(of: permission) == .granted ? "Allowed" : "Not allowed")
                            .foregroundStyle(controller.permissions.status(of: permission) == .granted ? Color.secondary : Color.orange)
                    }
                }
                Button("Open Setup…", action: openSetup)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .onAppear {
            // Menu-bar-only apps don't come to the front on their own.
            NSApp.activate()
            controller.refreshNow()
        }
    }

    private func binding(for trigger: HotkeyTrigger) -> Binding<Bool> {
        Binding(
            get: { controller.enabledTriggers.contains(trigger) },
            set: { controller.setTrigger(trigger, enabled: $0) }
        )
    }
}
