import AudioKit
import CleanupKit
import HotkeyKit
import SwiftUI

struct SettingsView: View {
    let controller: DictationController
    let openSetup: @MainActor () -> Void
    @State private var keyDraft = ""

    var body: some View {
        Form {
            Section {
                Toggle("Open Wispr Faux at login", isOn: Binding(
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
                        Text("This is a development build. Install Wispr Faux with scripts/install.sh and turn this on in the installed copy.")
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

            cleanupSection

            Section {
                LabeledContent("Model", value: controller.transcription.model.displayName)
                Picker("Language", selection: Binding(
                    get: { controller.transcription.language },
                    set: { controller.transcription.setLanguage($0) }
                )) {
                    ForEach(controller.transcription.languageChoices, id: \.self) { code in
                        Text(TranscriptionService.languageName(code)).tag(code)
                    }
                }
                .disabled(controller.transcription.model.isEnglishOnly)
                LabeledContent("Runs", value: "On this Mac (WhisperKit, Neural Engine)")
                LabeledContent("Capture format", value: "\(Int(AudioFormat.sampleRate / 1000)) kHz mono")
            } header: {
                Text("Transcription")
            } footer: {
                Text(languageFooter)
                    .foregroundStyle(.secondary)
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

    private var languageFooter: String {
        let transcription = controller.transcription
        if transcription.model.isEnglishOnly {
            return "\(transcription.model.displayName) only knows English."
        }
        return switch transcription.language {
        case "en":
            "Choose Detect automatically to dictate in Spanish, French or another language too."
        case TranscriptionService.detectLanguage:
            "Whisper picks the language of each dictation, so you can switch between English, Spanish and French from one dictation to the next. A dictation that switches language midway is transcribed as its main language."
        default:
            "Every dictation is transcribed as \(TranscriptionService.languageName(transcription.language))."
        }
    }

    private var cleanup: CleanupService { controller.cleanup }

    private var cleanupSection: some View {
        Section {
            Picker("Fix stumbles", selection: Binding(get: { cleanup.mode }, set: { cleanup.setMode($0) })) {
                ForEach(CleanupService.Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            switch cleanup.mode {
            case .off:
                EmptyView()
            case .onDevice:
                switch cleanup.localStatus {
                case .notDownloaded, .failed:
                    Button(cleanup.downloadTitle, action: cleanup.downloadLocalModel)
                default:
                    EmptyView()
                }
            case .cloud:
                Picker("Provider", selection: Binding(get: { cleanup.provider }, set: { cleanup.setProvider($0) })) {
                    ForEach(CloudProvider.all) { provider in
                        Text("\(provider.displayName) · \(provider.costNote)").tag(provider)
                    }
                }
                LabeledContent("API key") {
                    HStack {
                        SecureField(cleanup.hasCloudKey ? "Saved in Keychain" : "Paste key", text: $keyDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 170)
                        Button("Save") {
                            cleanup.saveCloudKey(keyDraft)
                            keyDraft = ""
                        }
                        .disabled(keyDraft.isEmpty)
                    }
                }
                HStack {
                    Button("Get a Key…", action: cleanup.openKeysPage)
                    if cleanup.hasCloudKey {
                        Button("Remove Key") { cleanup.saveCloudKey("") }
                    }
                }
            }

            if cleanup.mode != .off {
                HStack(alignment: .firstTextBaseline) {
                    Button("Test", action: cleanup.test)
                        .disabled(cleanup.isTesting)
                    if let result = cleanup.testResult {
                        Text(result)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        } header: {
            Text("Clean up stumbles")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let status = cleanup.statusLine {
                    Text(status)
                }
                Text(footerText)
            }
            .foregroundStyle(.secondary)
        }
    }

    private var footerText: String {
        switch cleanup.mode {
        case .off:
            "Removes “um”, repeated words and self-corrections (“Tuesday, no wait, Wednesday”), and lays out lists and emails, before pasting."
        case .onDevice:
            "Runs only when a dictation has a stumble or reads as a list or an email, adding about half a second (a second for a list or an email). Nothing leaves this Mac."
        case .cloud:
            "Runs only when a dictation has a stumble or reads as a list or an email. That dictation's text goes to \(cleanup.provider.displayName); audio never leaves this Mac. If the reply is slow or odd, the text is pasted as spoken."
        }
    }

    private func binding(for trigger: HotkeyTrigger) -> Binding<Bool> {
        Binding(
            get: { controller.enabledTriggers.contains(trigger) },
            set: { controller.setTrigger(trigger, enabled: $0) }
        )
    }
}
