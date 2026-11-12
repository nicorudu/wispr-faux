import Foundation
import Hub
import MLXLLM
import MLXLMCommon

/// Cleanup with a small language model on this Mac's GPU (MLX). Loads only from
/// `CleanupModelStore` files, so nothing leaves the Mac.
public actor LocalEngine: CleanupEngine {
    public enum LocalError: Error, LocalizedError {
        case notDownloaded(CleanupModel)

        public var errorDescription: String? {
            switch self {
            case .notDownloaded(let model): "\(model.displayName) isn't downloaded yet."
            }
        }
    }

    public nonisolated let model: CleanupModel
    private let store: CleanupModelStore
    private var container: ModelContainer?
    private var loadTask: Task<Duration, any Error>?

    public init(model: CleanupModel, store: CleanupModelStore = .standard) {
        self.model = model
        self.store = store
    }

    public nonisolated var name: String { "\(model.displayName) (on this Mac)" }

    /// Loads the model and returns how long that took. Later calls return at once.
    @discardableResult
    public func load() async throws -> Duration {
        if let loadTask { return try await loadTask.value }
        guard store.isDownloaded(model) else { throw LocalError.notDownloaded(model) }

        let folder = store.folder(for: model)
        let hub = HubApi(downloadBase: store.directory)
        let task = Task<Duration, any Error> {
            let started = ContinuousClock.now
            let container = try await loadModelContainer(hub: hub, directory: folder)
            self.finishLoading(container)
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

    private func finishLoading(_ container: ModelContainer) {
        self.container = container
    }

    public func complete(
        instructions: String,
        examples: [(dictated: String, cleaned: String)],
        text: String,
        maxTokens: Int
    ) async throws -> String {
        try await load()
        guard let container else { throw LocalError.notDownloaded(model) }

        let history = examples.flatMap { example in
            [Chat.Message.user(example.dictated), Chat.Message.assistant(example.cleaned)]
        }
        // A fresh session per transcript: nothing carries over between dictations.
        let session = ChatSession(
            container,
            instructions: instructions,
            history: history,
            generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: 0),
            additionalContext: model.templateContext
        )
        return try await session.respond(to: text)
    }
}
