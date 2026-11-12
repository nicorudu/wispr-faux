import Foundation
import Observation
import os

/// Stumble cleanup on the phone: the Mac app's cloud engines, prompt and safety check
/// (CleanupKit). On-device cleanup isn't offered: it needs the GPU, which iOS doesn't give
/// apps in the background. Only the text of dictations with a stumble is sent.
@MainActor
@Observable
final class PhoneCleanup {
    private(set) var isOn: Bool
    private(set) var provider: CloudProvider
    private(set) var hasKey = false
    private(set) var testResult: String?
    private(set) var isTesting = false

    private let log = Logger(subsystem: "WisprFauxPhone", category: "Cleanup")

    init() {
        isOn = UserDefaults.standard.bool(forKey: "cleanup.on")
        provider = UserDefaults.standard.string(forKey: "cleanup.provider").flatMap(CloudProvider.named) ?? .glmFlash
        hasKey = keychainItem.read() != nil
    }

    private var keychainItem: KeychainItem {
        KeychainItem(service: "wisprfaux.cleanup", account: provider.id)
    }

    func setOn(_ on: Bool) {
        isOn = on
        UserDefaults.standard.set(on, forKey: "cleanup.on")
        testResult = nil
    }

    func setProvider(_ newProvider: CloudProvider) {
        provider = newProvider
        UserDefaults.standard.set(newProvider.id, forKey: "cleanup.provider")
        hasKey = keychainItem.read() != nil
        testResult = nil
    }

    /// Saves the key in the keychain; an empty key removes it.
    func saveKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        keychainItem.save(trimmed)
        hasKey = !trimmed.isEmpty
        testResult = nil
    }

    private func cleaner(timeout: Duration = .seconds(4)) -> TranscriptCleaner? {
        guard isOn, let key = keychainItem.read() else { return nil }
        return TranscriptCleaner(engine: CloudEngine(provider: provider, apiKey: key), timeout: timeout)
    }

    /// Cleans the transcript, or returns nil when cleanup is off or has no key.
    func clean(_ text: String) async -> CleanupOutcome? {
        guard let cleaner = cleaner() else { return nil }
        let outcome = await cleaner.clean(text)
        log.notice("\(self.provider.displayName, privacy: .public): \(Self.describe(outcome.kind), privacy: .public), \(text.count, privacy: .public) → \(outcome.text.count, privacy: .public) characters")
        return outcome
    }

    func test() {
        guard !isTesting else { return }
        guard let base = cleaner(timeout: .seconds(10)) else {
            testResult = isOn ? "Add an API key first" : "Turn cleanup on first"
            return
        }
        isTesting = true
        testResult = "Testing…"
        Task {
            var sample = TranscriptCleaner(engine: base.engine, timeout: .seconds(10))
            sample.alwaysRun = true
            let outcome = await sample.clean("Um, can you send it to Mark, I mean Mike, by Friday?")
            let seconds = String(format: "%.2f", outcome.duration / .seconds(1))
            testResult = outcome.kind == .cleaned ? "\(seconds) s: “\(outcome.text)”" : "\(seconds) s: \(Self.describe(outcome.kind))"
            isTesting = false
        }
    }

    nonisolated static func describe(_ kind: CleanupOutcome.Kind) -> String {
        switch kind {
        case .cleaned: "cleaned"
        case .skipped: "no stumble, skipped"
        case .rejected(let reason): "kept as spoken (\(reason.rawValue))"
        case .timedOut: "kept as spoken (too slow)"
        case .failed(let message): "kept as spoken (\(message))"
        }
    }
}
