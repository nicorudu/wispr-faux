import Foundation
import Hub

/// Where on-device cleanup models live: `~/Library/Application Support/Wispr Faux/Models/llm`.
///
/// Like Whisper's `ModelStore`, `download(_:)` is the only network use and runs only when
/// asked; loading reads these files and nothing else.
public struct CleanupModelStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static var standard: CleanupModelStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return CleanupModelStore(directory: support.appending(path: "Wispr Faux/Models/llm", directoryHint: .isDirectory))
    }

    /// The model's files, laid out the way the Hub client downloads them.
    public func folder(for model: CleanupModel) -> URL {
        directory.appending(path: "models/\(model.id)", directoryHint: .isDirectory)
    }

    /// Complete: the marker is written only once every file has arrived.
    public func isDownloaded(_ model: CleanupModel) -> Bool {
        ["config.json", "tokenizer.json", Self.marker].allSatisfy {
            FileManager.default.fileExists(atPath: folder(for: model).appending(path: $0).path)
        }
    }

    public var downloadedModels: [CleanupModel] {
        CleanupModel.all.filter(isDownloaded)
    }

    /// Downloads the weights, config, tokenizer and chat template from Hugging Face.
    public func download(_ model: CleanupModel, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hub = HubApi(downloadBase: directory)
        // Newer models keep the chat template in a .jinja file and some tokenizers need
        // merges.txt; MLX's own downloader fetches only weights and JSON.
        let folder = try await hub.snapshot(
            from: Hub.Repo(id: model.id),
            matching: ["*.safetensors", "*.json", "*.jinja", "*.txt"]
        ) { value in
            progress?(value.fractionCompleted)
        }
        try Data().write(to: folder.appending(path: Self.marker))
    }

    public func delete(_ model: CleanupModel) throws {
        let folder = folder(for: model)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    /// Kept from when the app was called Dictate, so models downloaded then still count.
    static let marker = ".dictate-complete"
}
