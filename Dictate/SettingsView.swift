import SwiftUI
import AudioKit

struct SettingsView: View {
    var body: some View {
        Form {
            Section("Hotkey") {
                LabeledContent("Push to talk", value: "Hold Fn")
                LabeledContent("Hands-free", value: "Fn + Space")
                LabeledContent("Cancel", value: "Esc")
                Text("Configurable in Step 2.")
                    .foregroundStyle(.secondary)
            }

            Section("Transcription") {
                LabeledContent("Engine", value: "On-device (WhisperKit, Step 5)")
                LabeledContent("Capture format", value: "\(Int(AudioFormat.sampleRate / 1000)) kHz mono")
            }

            Section("Permissions") {
                Text("Microphone, Accessibility and Input Monitoring onboarding arrives in Step 2.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onAppear {
            // Menu-bar-only apps don't come to the front on their own.
            NSApp.activate()
        }
    }
}
