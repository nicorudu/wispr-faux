import Foundation

/// A cloud model reachable through the common "chat completions" API that DeepSeek, Z.ai
/// (GLM), Moonshot (Kimi) and others all speak.
public struct CloudProvider: Sendable, Hashable, Identifiable {
    public let id: String
    public let displayName: String
    /// Ends before `/chat/completions`.
    public let baseURL: URL
    public let model: String
    /// Extra JSON fields for this provider, e.g. turning off GLM's reasoning step.
    public let extraFields: [String: [String: String]]
    /// Where to create an API key.
    public let keysURL: URL
    public let costNote: String

    /// Z.ai's GLM-4.7-Flash: free with an account (about one request per second).
    public static let glmFlash = CloudProvider(
        id: "zai-glm-4.7-flash",
        displayName: "GLM-4.7-Flash (Z.ai)",
        baseURL: URL(string: "https://api.z.ai/api/paas/v4")!,
        model: "glm-4.7-flash",
        extraFields: ["thinking": ["type": "disabled"]],
        keysURL: URL(string: "https://z.ai")!,
        costNote: "Free"
    )

    /// DeepSeek's chat model: pay-as-you-go, about a hundredth of a cent per cleanup.
    public static let deepSeek = CloudProvider(
        id: "deepseek-chat",
        displayName: "DeepSeek",
        baseURL: URL(string: "https://api.deepseek.com")!,
        model: "deepseek-chat",
        extraFields: [:],
        keysURL: URL(string: "https://platform.deepseek.com")!,
        costNote: "Paid, about $0.0001 per cleanup"
    )

    public static let all: [CloudProvider] = [glmFlash, deepSeek]

    public static func named(_ id: String) -> CloudProvider? {
        all.first { $0.id == id }
    }
}

/// Cleanup through a `CloudProvider`. Sends only the cleanup prompt and the transcript.
public struct CloudEngine: CleanupEngine {
    public enum CloudError: Error, LocalizedError, Equatable {
        case http(status: Int, message: String)
        case unreadableReply

        public var errorDescription: String? {
            switch self {
            case .http(let status, let message): "HTTP \(status): \(message)"
            case .unreadableReply: "The reply couldn't be read."
            }
        }
    }

    public let provider: CloudProvider
    private let apiKey: String
    private let session: URLSession

    public init(provider: CloudProvider, apiKey: String, session: URLSession = .shared) {
        self.provider = provider
        self.apiKey = apiKey
        self.session = session
    }

    public var name: String { provider.displayName }

    public func complete(
        instructions: String,
        examples: [(dictated: String, cleaned: String)],
        text: String,
        maxTokens: Int
    ) async throws -> String {
        var request = URLRequest(url: provider.baseURL.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try Self.requestBody(
            provider: provider, instructions: instructions, examples: examples, text: text, maxTokens: maxTokens
        )

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw CloudError.http(status: status, message: Self.errorMessage(in: data))
        }
        return try Self.reply(in: data)
    }

    static func requestBody(
        provider: CloudProvider,
        instructions: String,
        examples: [(dictated: String, cleaned: String)],
        text: String,
        maxTokens: Int
    ) throws -> Data {
        var messages: [[String: String]] = [["role": "system", "content": instructions]]
        for example in examples {
            messages.append(["role": "user", "content": example.dictated])
            messages.append(["role": "assistant", "content": example.cleaned])
        }
        messages.append(["role": "user", "content": text])

        var body: [String: Any] = [
            "model": provider.model,
            "messages": messages,
            "temperature": 0,
            "max_tokens": maxTokens,
            "stream": false,
        ]
        for (key, value) in provider.extraFields {
            body[key] = value
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    static func reply(in data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw CloudError.unreadableReply
        }
        return content
    }

    static func errorMessage(in data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let message = json["message"] as? String { return message }
        }
        return String(decoding: data.prefix(200), as: UTF8.self)
    }
}
