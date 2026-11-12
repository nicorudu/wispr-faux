import Foundation
@preconcurrency import WhisperKit

/// On-device Whisper for the phone, using the Mac app's model list and model store
/// (TranscriptionKit), so models download and load the same way.
///
/// The one difference from the Mac's transcriber: everything runs on the CPU and the Neural
/// Engine. iOS doesn't let apps use the GPU in the background, and transcription happens while
/// the keyboard is in front, i.e. with Wispr Faux in the background. WhisperKit's default puts
/// the spectrogram step on the GPU.
actor PhoneTranscriber {
    enum PhoneTranscriberError: LocalizedError {
        case notDownloaded(WhisperModel)
        var errorDescription: String? {
            switch self {
            case .notDownloaded(let model): "\(model.displayName) isn't downloaded yet."
            }
        }
    }

    nonisolated let model: WhisperModel
    private let store: ModelStore
    private var kit: WhisperKit?
    private var loadTask: Task<Duration, any Error>?

    init(model: WhisperModel, store: ModelStore = .standard) {
        self.model = model
        self.store = store
    }

    var isLoaded: Bool { kit != nil }

    @discardableResult
    func load() async throws -> Duration {
        if let loadTask { return try await loadTask.value }
        guard store.isDownloaded(model) else { throw PhoneTranscriberError.notDownloaded(model) }
        let config = WhisperKitConfig(
            model: model.id,
            modelFolder: store.folder(for: model).path,
            tokenizerFolder: store.directory,
            computeOptions: ModelComputeOptions(
                melCompute: .cpuOnly,
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            ),
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        let task = Task<Duration, any Error> {
            let started = ContinuousClock.now
            let kit = try await WhisperKit(config)
            self.finish(kit)
            return .now - started
        }
        loadTask = task
        do {
            return try await task.value
        } catch {
            loadTask = nil
            throw error
        }
    }

    private func finish(_ kit: WhisperKit) {
        self.kit = kit
    }

    /// - Parameter language: e.g. "en"; nil detects it.
    func transcribe(_ samples: [Float], language: String?) async throws -> Transcription {
        try await load()
        guard let kit else { throw PhoneTranscriberError.notDownloaded(model) }
        let started = ContinuousClock.now
        // Whisper wants at least a second of audio.
        let padded = samples.count >= 17_600 ? samples : samples + [Float](repeating: 0, count: 17_600 - samples.count)
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            chunkingStrategy: padded.count > 30 * 16_000 ? .vad : nil
        )
        let results = try await kit.transcribe(audioArray: padded, decodeOptions: options)
        let text = results
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return Transcription(
            text: text,
            audioDuration: .seconds(Double(samples.count) / 16_000),
            processingDuration: .now - started
        )
    }
}
