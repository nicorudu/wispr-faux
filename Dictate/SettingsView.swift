import AudioKit
import HotkeyKit
import SwiftUI

struct SettingsView: View {
    let controller: DictationController
    let openSetup: @MainActor () -> Void

    var body: some View {
        Form {
            Section {
                Toggle("Open Dictate at login", isOn: Binding(
                    get: { controller.loginItem.isEnabled },
                    set: { controller.loginItem.setEnabled($0) }
                ))
                .disabled(!controller.loginItem.isInstalledCopy)
                if controller.loginItem.needsApproval {
                    Button("Allow in Login Items…", action: controller.loginItem.openLoginItemsSettings)
                }
            } header: {
                Text("General")
            } footer: {
                Group {
                    if let error = controller.loginItem.lastError {
                        Text(error)
                    } else if !controller.loginItem.isInstalledCopy {
                        Text("This is a development build. Install Dictate with scripts/install.sh and turn this on in the installed copy.")
                    }
                }
                .foregroundStyle(.secondary)
            }

            Section {
                ForEach(HotkeyTrigger.allCases) { trigger in
                    Toggle(trigger.displayName, isOn: binding(for: trigger))
                        // At least one trigger stays on.
                        .disabled(controller.enabledTriggers == [trigger])
                }
            } header: {
                Text("Hold to talk")
            } footer: {
                Text("Control works on every keyboard, and shortcuts like ⌃C and Ctrl-click still work: they cancel instead of dictating.")
                    .foregroundStyle(.secondary)
            }

            Section("Shortcuts") {
                LabeledContent("Hands-free", value: "Hold key + Space")
                LabeledContent("Stop hands-free", value: "Press the key again")
                LabeledContent("Cancel", value: "Esc")
            }

            Section("Transcription") {
                LabeledContent("Model", value: controller.transcription.model.displayName)
                LabeledContent("Runs", value: "On this Mac (WhisperKit, Neural Engine)")
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
            controller.loginItem.refresh()
        }
    }

    private func binding(for trigger: HotkeyTrigger) -> Binding<Bool> {
        Binding(
            get: { controller.enabledTriggers.contains(trigger) },
            set: { controller.setTrigger(trigger, enabled: $0) }
        )
    }
}
