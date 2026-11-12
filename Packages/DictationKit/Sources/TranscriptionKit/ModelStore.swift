import Foundation
@preconcurrency import WhisperKit

/// Where Whisper models live: `~/Library/Application Support/Dictate/Models`.
///
/// `download(_:)` is the only code in Dictate that uses the network, and runs only when
/// the user asks for a model. Loading and transcribing work entirely from these files.
public struct ModelStore: Sendable {
    public enum StoreError: Error, LocalizedError {
        case incompleteDownload(WhisperModel, missing: String)

        public var errorDescription: String? {
            switch self {
            case .incompleteDownload(let model, let missing):
                "The download of \(model.displayName) is incomplete (\(missing) is missing)."
            }
        }
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static var standard: ModelStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ModelStore(directory: support.appending(path: "Dictate/Models", directoryHint: .isDirectory))
    }

    /// The model's Core ML files, laid out the way WhisperKit downloads them.
    public func folder(for model: WhisperModel) -> URL {
        directory.appending(path: "models/argmaxinc/whisperkit-coreml/\(model.id)", directoryHint: .isDirectory)
    }

    /// Where WhisperKit keeps the tokenizer when `tokenizerFolder` is `directory`.
    public func tokenizerFolder(for model: WhisperModel) -> URL {
        directory.appending(path: "models/\(model.family.tokenizerRepo)", directoryHint: .isDirectory)
    }

    /// The model and its tokenizer are both on disk, so loading needs no network.
    public func isDownloaded(_ model: WhisperModel) -> Bool {
        missingFile(for: model) == nil
    }

    public var downloadedModels: [WhisperModel] {
        WhisperModel.all.filter(isDownloaded)
    }

    /// Downloads the model and its tokenizer from Hugging Face.
    public func download(
        _ model: WhisperModel,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try await WhisperKit.download(variant: model.id, downloadBase: directory) { value in
            progress?(value.fractionCompleted)
        }
        // Fetches the tokenizer into `tokenizerFolder(for:)` unless it's already there.
        _ = try await ModelUtilities.loadTokenizer(for: model.family.variant, tokenizerFolder: directory)

        if let missing = missingFile(for: model) {
            throw StoreError.incompleteDownload(model, missing: missing)
        }
    }

    /// Removes the model's files. Tokenizers are small and shared, so they stay.
    public func delete(_ model: WhisperModel) throws {
        let folder = folder(for: model)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    /// The first required file that isn't on disk, or nil when everything is there.
    func missingFile(for model: WhisperModel) -> String? {
        let required = [
            folder(for: model).appending(path: "MelSpectrogram.mlmodelc/weights/weight.bin"),
            folder(for: model).appending(path: "AudioEncoder.mlmodelc/weights/weight.bin"),
            folder(for: model).appending(path: "TextDecoder.mlmodelc/weights/weight.bin"),
            folder(for: model).appending(path: "config.json"),
            tokenizerFolder(for: model).appending(path: "tokenizer.json"),
        ]
        return required.first { !FileManager.default.fileExists(atPath: $0.path) }?
            .path.replacingOccurrences(of: directory.path + "/", with: "")
    }
}
