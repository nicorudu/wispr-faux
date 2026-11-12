import Foundation
@preconcurrency import WhisperKit

/// On-device transcription with WhisperKit (Core ML, Neural Engine).
///
/// Loads only from `ModelStore` files with downloading turned off, so it never touches the
/// network. Load once at launch: the first load of a model on a Mac also compiles it for
/// the Neural Engine, which can take a few minutes; macOS caches the result.
public actor WhisperKitTranscriber: Transcriber {
    public enum TranscriberError: Error, LocalizedError {
        case notDownloaded(WhisperModel)

        public var errorDescription: String? {
            switch self {
            case .notDownloaded(let model): "\(model.displayName) isn't downloaded yet."
            }
        }
    }

    public nonisolated let model: WhisperModel
    /// Spoken language. English-only models ignore anything else.
    public nonisolated let language: String
    private let store: ModelStore

    private var kit: WhisperKit?
    private var loadTask: Task<Duration, any Error>?

    public init(model: WhisperModel, store: ModelStore = .standard, language: String = "en") {
        self.model = model
        self.store = store
        self.language = language
    }

    public var isLoaded: Bool { kit != nil }

    /// Loads the model from disk and returns how long that took. Calls while a load is in
    /// progress wait for it; later calls return at once.
    @discardableResult
    public func load() async throws -> Duration {
        if let loadTask { return try await loadTask.value }
        guard store.isDownloaded(model) else { throw TranscriberError.notDownloaded(model) }

        let config = WhisperKitConfig(
            model: model.id,
            modelFolder: store.folder(for: model).path,
            // Finds the tokenizer `ModelStore.download` saved, instead of fetching it.
            tokenizerFolder: store.directory,
            verbose: false,
            logLevel: .error,
            load: true,
            download: false
        )
        let task = Task<Duration, any Error> {
            let started = ContinuousClock.now
            let kit = try await WhisperKit(config)
            self.finishLoading(kit)
            return .now - started
        }
        loadTask = task
        do {
            return try await task.value
        } catch {
            loadTask = nil // Allow another try.
            throw error
        }
    }

    private func finishLoading(_ kit: WhisperKit) {
        self.kit = kit
    }

    public func transcribe(_ pcm16k: [Float]) async throws -> Transcription {
        try await load()
        guard let kit else { throw TranscriberError.notDownloaded(model) }

        let started = ContinuousClock.now
        let results = try await kit.transcribe(audioArray: pcm16k, decodeOptions: decodingOptions(sampleCount: pcm16k.count))
        let text = results
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return Transcription(
            text: text,
            audioDuration: .seconds(Double(pcm16k.count) / 16_000),
            processingDuration: .now - started
        )
    }

    /// Frees the model's memory. The next transcription loads it again.
    public func unload() async {
        loadTask = nil
        guard let kit else { return }
        self.kit = nil
        await kit.unloadModels()
    }

    func decodingOptions(sampleCount: Int) -> DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            // Whisper hears 30 s at a time. Longer recordings are split at pauses.
            chunkingStrategy: sampleCount > 30 * 16_000 ? .vad : nil
        )
    }
}
