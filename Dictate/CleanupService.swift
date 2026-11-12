import AppKit
import CleanupKit
import Observation
import os

/// Fixes stumbles in transcripts ("um", "Tuesday, no wait, Wednesday", "Mark, I mean
/// Mike") with a small model on this Mac or a cloud model the user picks. Only runs when
/// a transcript shows a stumble, and any failure leaves the transcript as spoken.
@MainActor
@Observable
final class CleanupService {
    enum Mode: String, CaseIterable, Identifiable {
        case off
        case onDevice
        case cloud

        var id: String { rawValue }

        var title: String {
            switch self {
            case .off: "Off"
            case .onDevice: "On this Mac"
            case .cloud: "Cloud"
            }
        }
    }

    enum LocalStatus: Equatable {
        case notDownloaded
        case downloading(fraction: Double)
        case loading
        case ready(loadTime: Duration)
        case failed(String)
    }

    private(set) var mode: Mode
    let localModel = CleanupModel.qwen3Small
    private(set) var localStatus: LocalStatus
    private(set) var provider: CloudProvider
    private(set) var hasCloudKey = false
    /// Result of the last Test in Settings, e.g. "0.52 s: “Send it to Mike by Friday.”".
    private(set) var testResult: String?
    private(set) var isTesting = false

    let store = CleanupModelStore.standard
    @ObservationIgnored private let localEngine: LocalEngine
    @ObservationIgnored private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Dictate", category: "Cleanup")

    private static let modeKey = "cleanup.mode"
    private static let providerKey = "cleanup.provider"

    init() {
        let store = CleanupModelStore.standard
        let model = CleanupModel.qwen3Small
        localEngine = LocalEngine(model: model, store: store)
        localStatus = store.isDownloaded(model) ? .loading : .notDownloaded
        let savedMode = UserDefaults.standard.string(forKey: Self.modeKey).flatMap(Mode.init(rawValue:))
        // On this Mac by default once its model is there.
        mode = savedMode ?? (store.isDownloaded(model) ? .onDevice : .off)
        provider = UserDefaults.standard.string(forKey: Self.providerKey).flatMap(CloudProvider.named) ?? .glmFlash
        hasCloudKey = keychainItem(for: provider).read() != nil
    }

    func start() {
        if mode == .onDevice { loadLocalModel() }
    }

    // MARK: - Settings

    func setMode(_ newMode: Mode) {
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: Self.modeKey)
        testResult = nil
        log.notice("Cleanup mode: \(newMode.rawValue, privacy: .public)")
        if newMode == .onDevice { loadLocalModel() }
    }

    func setProvider(_ newProvider: CloudProvider) {
        provider = newProvider
        UserDefaults.standard.set(newProvider.id, forKey: Self.providerKey)
        hasCloudKey = keychainItem(for: newProvider).read() != nil
        testResult = nil
    }

    /// Stores the provider's API key in the keychain; an empty string removes it.
    func saveCloudKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        keychainItem(for: provider).save(trimmed)
        hasCloudKey = !trimmed.isEmpty
        testResult = nil
    }

    func openKeysPage() {
        NSWorkspace.shared.open(provider.keysURL)
    }

    /// Downloads the on-device model. The only network use for on-device cleanup.
    func downloadLocalModel() {
        switch localStatus {
        case .notDownloaded, .failed: break
        default: return
        }
        localStatus = .downloading(fraction: 0)
        Task {
            do {
                try await store.download(localModel) { fraction in
                    Task { @MainActor [weak self] in
                        if case .downloading = self?.localStatus { self?.localStatus = .downloading(fraction: fraction) }
                    }
                }
                loadLocalModel()
            } catch {
                localStatus = .failed("Download failed: \(error.localizedDescription)")
            }
        }
    }

    private func loadLocalModel() {
        guard store.isDownloaded(localModel) else {
            localStatus = .notDownloaded
            return
        }
        if case .ready = localStatus { return }
        localStatus = .loading
        Task {
            do {
                let loadTime = try await localEngine.load()
                localStatus = .ready(loadTime: loadTime)
                log.notice("Loaded \(self.localModel.id, privacy: .public) in \(Int(loadTime / .milliseconds(1)), privacy: .public) ms")
            } catch {
                localStatus = .failed(error.localizedDescription)
                log.error("Couldn't load the cleanup model: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Cleaning

    /// The engine for the current mode, or nil when cleanup is off or not set up.
    private var cleaner: TranscriptCleaner? {
        switch mode {
        case .off:
            return nil
        case .onDevice:
            guard store.isDownloaded(localModel) else { return nil }
            return TranscriptCleaner(engine: localEngine, timeout: .seconds(3))
        case .cloud:
            guard let key = keychainItem(for: provider).read() else { return nil }
            return TranscriptCleaner(engine: CloudEngine(provider: provider, apiKey: key), timeout: .seconds(4))
        }
    }

    /// Cleans `transcript`, or returns nil when cleanup is off or not set up.
    func clean(_ transcript: String) async -> CleanupOutcome? {
        guard let cleaner else { return nil }
        let outcome = await cleaner.clean(transcript)
        // Lengths and timings only, never the words.
        log.notice("""
            \(cleaner.engine.name, privacy: .public): \(Self.describe(outcome.kind), privacy: .public) \
            in \(Int(outcome.duration / .milliseconds(1)), privacy: .public) ms, \
            \(transcript.count, privacy: .public) → \(outcome.text.count, privacy: .public) characters
            """)
        return outcome
    }

    /// Cleans a sample stumble so the user can see the engine work (and how fast).
    func test() {
        guard !isTesting else { return }
        guard let cleaner else {
            testResult = mode == .cloud ? "Add an API key first" : "Download the model first"
            return
        }
        isTesting = true
        testResult = "Testing…"
        Task {
            defer { isTesting = false }
            var sample = TranscriptCleaner(engine: cleaner.engine, timeout: .seconds(10))
            sample.alwaysRun = true
            let outcome = await sample.clean("Um, can you send it to Mark, I mean Mike, by Friday?")
            let seconds = (outcome.duration / .seconds(1)).formatted(.number.precision(.fractionLength(2)))
            testResult = switch outcome.kind {
            case .cleaned: "\(seconds) s: “\(outcome.text)”"
            default: "\(seconds) s: \(Self.describe(outcome.kind))"
            }
        }
    }

    // MARK: - Helpers

    var statusLine: String? {
        switch mode {
        case .off:
            return nil
        case .onDevice:
            return switch localStatus {
            case .notDownloaded: "\(localModel.displayName) isn't downloaded"
            case .downloading(let fraction): "Downloading \(localModel.displayName)… \(Int(fraction * 100))%"
            case .loading: "Loading \(localModel.displayName)…"
            case .ready: "\(localModel.displayName), on this Mac"
            case .failed(let message): message
            }
        case .cloud:
            return hasCloudKey ? "\(provider.displayName). Dictated text with stumbles is sent to it" : "Add a \(provider.displayName) API key"
        }
    }

    var downloadTitle: String {
        "Download \(localModel.displayName) (\(ByteCountFormatter.string(fromByteCount: localModel.downloadSize, countStyle: .file)))"
    }

    private func keychainItem(for provider: CloudProvider) -> KeychainItem {
        KeychainItem(service: "com.example.dictate.cleanup", account: provider.id)
    }

    static func describe(_ kind: CleanupOutcome.Kind) -> String {
        switch kind {
        case .cleaned: "cleaned"
        case .skipped: "no stumble, skipped"
        case .rejected(let reason): "kept as spoken (\(reason.rawValue))"
        case .timedOut: "kept as spoken (too slow)"
        case .failed(let message): "kept as spoken (\(message))"
        }
    }
}
