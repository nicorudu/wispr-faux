import Foundation
import Testing
@testable import TranscriptionKit

@Suite("WordErrorRate")
struct WordErrorRateTests {
    @Test func ignoresCaseAndPunctuation() {
        #expect(WordErrorRate.compute(reference: "Hello, world.", hypothesis: "hello world") == 0)
        #expect(WordErrorRate.compute(reference: "Don’t stop", hypothesis: "don't stop!") == 0)
    }

    @Test func countsSubstitutionsDeletionsAndInsertions() {
        // One substitution out of four words.
        #expect(WordErrorRate.compute(reference: "send the report today", hypothesis: "send the reports today") == 0.25)
        // One deletion.
        #expect(WordErrorRate.compute(reference: "send the report today", hypothesis: "send report today") == 0.25)
        // Two insertions.
        #expect(WordErrorRate.compute(reference: "send it", hypothesis: "please send it now") == 1)
    }

    @Test func emptyInputs() {
        #expect(WordErrorRate.compute(reference: "", hypothesis: "") == 0)
        #expect(WordErrorRate.compute(reference: "", hypothesis: "thank you") == 1)
        #expect(WordErrorRate.compute(reference: "hello there", hypothesis: "") == 1)
    }
}

@Suite("ModelStore")
struct ModelStoreTests {
    private func scratchStore() -> ModelStore {
        ModelStore(directory: FileManager.default.temporaryDirectory.appending(path: "dictate-models-\(UUID().uuidString)"))
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    /// The layout WhisperKit's downloader produces, which loading relies on.
    @Test func pathsMatchWhisperKitsLayout() {
        let store = ModelStore(directory: URL(filePath: "/m"))
        #expect(store.folder(for: .smallEnglish).path == "/m/models/argmaxinc/whisperkit-coreml/openai_whisper-small.en")
        #expect(store.tokenizerFolder(for: .largeV3TurboCompressed).path == "/m/models/openai/whisper-large-v3")
    }

    /// Loading without the tokenizer would make WhisperKit fetch it from the internet,
    /// so a model only counts as downloaded with every file, tokenizer included.
    @Test func downloadedOnlyWhenEveryFileIsThere() throws {
        let store = scratchStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let model = WhisperModel.smallEnglish
        #expect(!store.isDownloaded(model))

        let folder = store.folder(for: model)
        for part in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            try touch(folder.appending(path: "\(part).mlmodelc/weights/weight.bin"))
        }
        try touch(folder.appending(path: "config.json"))
        #expect(!store.isDownloaded(model))
        #expect(store.missingFile(for: model) == "models/openai/whisper-small.en/tokenizer.json")

        try touch(store.tokenizerFolder(for: model).appending(path: "tokenizer.json"))
        #expect(store.isDownloaded(model))
        #expect(store.downloadedModels == [model])

        try store.delete(model)
        #expect(!store.isDownloaded(model))
    }
}

@Suite("WhisperKitTranscriber")
struct WhisperKitTranscriberTests {
    @Test func decodesEnglishWithoutTimestamps() async {
        let transcriber = WhisperKitTranscriber(model: .smallEnglish)
        let options = await transcriber.decodingOptions(sampleCount: 16_000 * 5)
        #expect(options.language == "en")
        #expect(!options.detectLanguage)
        #expect(options.withoutTimestamps)
        #expect(options.skipSpecialTokens)
        #expect(options.temperature == 0)
        #expect(options.chunkingStrategy == nil)
    }

    @Test func splitsLongRecordingsAtPauses() async {
        let transcriber = WhisperKitTranscriber(model: .smallEnglish)
        #expect(await transcriber.decodingOptions(sampleCount: 16_000 * 30).chunkingStrategy == nil)
        #expect(await transcriber.decodingOptions(sampleCount: 16_000 * 31).chunkingStrategy == .vad)
    }

    @Test func refusesToLoadAModelThatIsNotDownloaded() async {
        let store = ModelStore(directory: FileManager.default.temporaryDirectory.appending(path: "dictate-empty-\(UUID().uuidString)"))
        let transcriber = WhisperKitTranscriber(model: .smallEnglish, store: store)
        await #expect(throws: WhisperKitTranscriber.TranscriberError.self) {
            try await transcriber.load()
        }
    }

    @Test func realTimeFactor() {
        let result = Transcription(text: "hi", audioDuration: .seconds(5), processingDuration: .milliseconds(500))
        #expect(abs(result.realTimeFactor - 0.1) < 1e-9)
    }
}
