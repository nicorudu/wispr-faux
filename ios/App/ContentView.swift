import SwiftUI

struct ContentView: View {
    @Environment(SessionController.self) private var controller
    @State private var apiKey = ""
    @State private var tryText = ""

    var body: some View {
        @Bindable var controller = controller
        NavigationStack {
            Form {
                if controller.showGoBackHint {
                    goBackSection
                }
                sessionSection
                setupSection
                speechSection
                cleanupSection
                trySection
                recentSection
            }
            .navigationTitle("Wispr Faux")
        }
    }

    // MARK: Sections

    private var goBackSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Session started", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Text("Go back to your app with **◀** at the top-left corner of the screen (or swipe right along the bottom edge), then hold the mic button to dictate.")
                    .font(.subheadline)
            }
            .padding(.vertical, 4)
            Button("Got it") { controller.showGoBackHint = false }
        }
    }

    private var sessionSection: some View {
        @Bindable var controller = controller
        return Section {
            HStack {
                Circle()
                    .fill(controller.isSessionActive ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 10, height: 10)
                Text(sessionStatus)
                Spacer()
            }
            if controller.isSessionActive {
                Button("End Session", role: .destructive) { controller.endSession() }
            } else {
                Button("Start Session") { controller.startSession() }
                    .disabled(!controller.microphoneAllowed)
            }
            Picker("End after no use for", selection: $controller.sessionLength) {
                ForEach(SessionController.SessionLength.allCases) { length in
                    Text(length.title).tag(length)
                }
            }
            if let error = controller.startError {
                Text(error).foregroundStyle(.red).font(.footnote)
            }
            if let reason = controller.endedReason {
                Text("The last session ended: \(reason).").foregroundStyle(.secondary).font(.footnote)
            }
        } header: {
            Text("Session")
        } footer: {
            Text("The keyboard's mic button works while a session runs. Starting one turns the microphone on in the background (iOS shows the orange dot); only what you say while holding the button is transcribed, and no audio is stored. If no session is running, the mic button opens this app to start one.")
        }
    }

    private var sessionStatus: String {
        switch controller.phase {
        case .off: "No session"
        case .ready: "Session running"
        case .recording: "Listening…"
        case .transcribing: "Transcribing…"
        }
    }

    private var setupSection: some View {
        Section {
            SetupRow(done: controller.microphoneAllowed, title: "Microphone") {
                Button("Allow") { controller.requestMicrophone() }
            }
            SetupRow(done: controller.modelStatus == .ready, title: "Speech model") {
                modelAction
            }
            SetupRow(done: controller.keyboardSeen, title: "Keyboard with Full Access") {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        } header: {
            Text("Setup")
        } footer: {
            Text("Keyboard: in Settings, tap **Keyboards**, turn on **Wispr Faux** and **Allow Full Access**. (Or: Settings → General → Keyboard → Keyboards → Add New Keyboard.) Full Access lets the keyboard talk to this app; the keyboard itself never sends anything anywhere. Then, in any app, hold 🌐 on the keyboard and pick Wispr Faux. The tick appears once the keyboard has been used.")
        }
    }

    @ViewBuilder
    private var modelAction: some View {
        switch controller.modelStatus {
        case .notDownloaded:
            Button("Download (\(ByteCountFormatter.string(fromByteCount: controller.model.downloadSize, countStyle: .file)))") {
                controller.downloadModel()
            }
        case .downloading(let fraction):
            ProgressView(value: fraction).frame(width: 90)
        case .loading:
            HStack(spacing: 6) {
                ProgressView()
                Text("Preparing").font(.footnote).foregroundStyle(.secondary)
            }
        case .ready:
            EmptyView()
        case .failed:
            Button("Retry") { controller.downloadModel() }
        }
    }

    private var speechSection: some View {
        @Bindable var controller = controller
        return Section {
            Picker("Model", selection: Binding(get: { controller.model }, set: { controller.setModel($0) })) {
                ForEach([WhisperModel.largeV3TurboCompressed, .smallEnglish], id: \.self) { model in
                    Text(model.displayName).tag(model)
                }
            }
            Picker("Language", selection: $controller.languageCode) {
                ForEach(SessionController.languages, id: \.name) { language in
                    Text(language.name).tag(language.code)
                }
            }
            if case .failed(let message) = controller.modelStatus {
                Text(message).foregroundStyle(.red).font(.footnote)
            }
            if case .loading = controller.modelStatus {
                Text("The first time, iOS prepares the model for the Neural Engine. That can take a few minutes; keep the app open.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Speech to text (on this iPhone)")
        } footer: {
            Text("Whisper large-v3 turbo, as on the Mac. Download it on Wi-Fi. If sessions on an older iPhone keep ending on their own, try Whisper small (English): it uses less memory.")
        }
    }

    private var cleanupSection: some View {
        let cleanup = controller.cleanup
        return Section {
            Toggle("Clean up stumbles", isOn: Binding(get: { cleanup.isOn }, set: { cleanup.setOn($0) }))
            if cleanup.isOn {
                Picker("Provider", selection: Binding(get: { cleanup.provider }, set: { cleanup.setProvider($0) })) {
                    ForEach(CloudProvider.all) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                Link("Get a key (\(cleanup.provider.costNote))", destination: cleanup.provider.keysURL)
                HStack {
                    SecureField(cleanup.hasKey ? "Key saved. Paste a new one to replace it" : "Paste the API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save") {
                        cleanup.saveKey(apiKey)
                        apiKey = ""
                    }
                    .disabled(apiKey.isEmpty)
                }
                HStack {
                    Button("Test") { cleanup.test() }.disabled(cleanup.isTesting)
                    if let result = cleanup.testResult {
                        Text(result).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Clean up stumbles (cloud)")
        } footer: {
            Text("Fixes “um”, repeated words and “Tuesday, no wait, Wednesday” before typing. Only the text of dictations with a stumble is sent; audio never leaves the iPhone. Both providers are in China, and free tiers may use requests for training.")
        }
    }

    private var trySection: some View {
        Section {
            TextField("Tap here, switch to the Wispr Faux keyboard, hold the mic", text: $tryText, axis: .vertical)
                .lineLimit(3...8)
            if let timing = controller.lastTiming {
                Text("Last: \(timing)").font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Try it")
        }
    }

    private var recentSection: some View {
        Section {
            if controller.recent.isEmpty {
                Text("Nothing yet").foregroundStyle(.secondary)
            }
            ForEach(controller.recent.prefix(20)) { record in
                Text(record.text)
                    .lineLimit(3)
                    .contextMenu {
                        Button("Copy") { UIPasteboard.general.string = record.text }
                    }
            }
            if !controller.recent.isEmpty {
                Button("Clear History", role: .destructive) { controller.clearHistory() }
            }
        } header: {
            Text("Recent")
        } footer: {
            Text("Touch and hold to copy. The last 100 dictations are kept on this iPhone.")
        }
    }
}

private struct SetupRow<Action: View>: View {
    let done: Bool
    let title: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary)
            Text(title)
            Spacer()
            if !done { action() }
        }
    }
}
