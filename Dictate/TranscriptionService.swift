import AppKit
import AudioKit
import Observation
import os
import TranscriptionKit

/// Owns the Whisper model: loads it at launch and transcribes recordings. Everything runs
/// on this Mac; the only network use is `download()`, when the user clicks Download in
/// the menu.
@MainActor
@Observable
final class TranscriptionService {
    enum ModelStatus: Equatable {
        case notDownloaded
        case downloading(fraction: Double)
        case loading
        case ready(loadTime: Duration)
        case failed(String)
    }

    struct Result: Equatable {
        var text: String
        var audioDuration: Duration
        var processingDuration: Duration
        /// From the key going up to the text being ready, including the recorder's tail wait.
        var releaseToText: Duration
    }

    let store = ModelStore.standard
    private(set) var model: WhisperModel
    private(set) var status: ModelStatus
    private(set) var isTranscribing = false

    @ObservationIgnored private var transcriber: WhisperKitTranscriber
    @ObservationIgnored private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Dictate", category: "Transcription")

    /// Pick another model with `defaults write com.example.dictate transcription.model <id>`.
    static let modelDefaultsKey = "transcription.model"
    static let defaultModel = WhisperModel.largeV3TurboCompressed

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.modelDefaultsKey).flatMap(WhisperModel.named)
        let model = saved ?? Self.defaultModel
        self.model = model
        transcriber = WhisperKitTranscriber(model: model, store: store)
        status = store.isDownloaded(model) ? .loading : .notDownloaded
    }

    /// Loads the model from disk if it's there. Called at launch so the first dictation
    /// doesn't wait for it.
    func loadIfDownloaded() {
        guard store.isDownloaded(model) else {
            status = .notDownloaded
            log.notice("\(self.model.id, privacy: .public) isn't downloaded; transcription is off until it is")
            return
        }
        status = .loading
        Task {
            do {
                let loadTime = try await transcriber.load()
                status = .ready(loadTime: loadTime)
                log.notice("Loaded \(self.model.id, privacy: .public) in \(Self.ms(loadTime), privacy: .public) ms")
            } catch {
                status = .failed(error.localizedDescription)
                log.error("Couldn't load \(self.model.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Downloads the model from Hugging Face, then loads it. Only runs when the user asks.
    func download() {
        switch status {
        case .notDownloaded, .failed: break
        default: return
        }
        status = .downloading(fraction: 0)
        log.notice("Downloading \(self.model.id, privacy: .public)")
        Task {
            do {
                try await store.download(model) { fraction in
                    Task { @MainActor [weak self] in self?.downloadProgressed(fraction) }
                }
                loadIfDownloaded()
            } catch {
                status = .failed("Download failed: \(error.localizedDescription)")
                log.error("Download failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func downloadProgressed(_ fraction: Double) {
        if case .downloading = status { status = .downloading(fraction: fraction) }
    }

    /// Whether the model is on disk (it may still be loading).
    var isAvailable: Bool { store.isDownloaded(model) }

    /// Transcribes `recording`; `releasedAt` is when the hotkey went up. Returns nil and
    /// logs the error on failure.
    func transcribe(_ recording: Recording, releasedAt: ContinuousClock.Instant) async -> Result? {
        guard isAvailable else { return nil }
        isTranscribing = true
        defer { isTranscribing = false }
        do {
            let transcription = try await transcriber.transcribe(recording.samples)
            let result = Result(
                text: transcription.text,
                audioDuration: transcription.audioDuration,
                processingDuration: transcription.processingDuration,
                releaseToText: .now - releasedAt
            )
            // The log gets timings and length only, never the words.
            log.notice("""
                Transcribed \(Self.ms(result.audioDuration), privacy: .public) ms of audio \
                in \(Self.ms(result.processingDuration), privacy: .public) ms \
                (\(String(format: "%.2f", transcription.realTimeFactor), privacy: .public)× real time); \
                release to text \(Self.ms(result.releaseToText), privacy: .public) ms; \
                \(result.text.count, privacy: .public) characters, model \(self.model.id, privacy: .public)
                """)
            return result
        } catch {
            log.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Menu text

    var statusLine: String {
        switch status {
        case .notDownloaded:
            "Model: \(model.displayName), not downloaded"
        case .downloading(let fraction):
            "Downloading \(model.displayName)… \(Int(fraction * 100))%"
        case .loading:
            "Loading \(model.displayName)… (the first load can take a couple of minutes)"
        case .ready(let loadTime):
            "Model: \(model.displayName) (loaded in \(Self.seconds(loadTime)) s)"
        case .failed(let message):
            "Model: \(message)"
        }
    }

    var downloadButtonTitle: String {
        "Download \(model.displayName) (\(ByteCountFormatter.string(fromByteCount: model.downloadSize, countStyle: .file)))"
    }

    var isReady: Bool {
        if case .ready = status { true } else { false }
    }

    // MARK: - Formatting

    nonisolated private static func seconds(_ duration: Duration) -> String {
        (duration / .seconds(1)).formatted(.number.precision(.fractionLength(2)))
    }

    nonisolated private static func ms(_ duration: Duration) -> Int {
        Int((duration / .milliseconds(1)).rounded())
    }
}
