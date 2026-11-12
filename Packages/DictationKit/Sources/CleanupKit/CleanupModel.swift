/// A small instruction-tuned language model in MLX format, from huggingface.co/mlx-community.
public struct CleanupModel: Sendable, Hashable, Identifiable, CustomStringConvertible {
    /// Hugging Face repo, e.g. "mlx-community/LFM2.5-1.2B-Instruct-4bit".
    public let id: String
    public let displayName: String
    /// Approximate download, in bytes.
    public let downloadSize: Int64
    /// Turns off "thinking" for models that reason out loud before answering (Qwen3
    /// hybrids), which would make cleanup slow.
    let disablesThinking: Bool

    public var description: String { id }

    /// Chat-template variables passed with every request.
    var templateContext: [String: any Sendable]? {
        disablesThinking ? ["enable_thinking": false] : nil
    }

    /// Liquid AI LFM2.5, 1.2B parameters: the smallest and fastest candidate.
    public static let lfm25 = CleanupModel(
        id: "mlx-community/LFM2.5-1.2B-Instruct-4bit",
        displayName: "LFM2.5 1.2B",
        downloadSize: 660_000_000,
        disablesThinking: false
    )

    /// Qwen3 1.7B, a hybrid thinking model, with thinking turned off.
    public static let qwen3Small = CleanupModel(
        id: "mlx-community/Qwen3-1.7B-4bit",
        displayName: "Qwen3 1.7B",
        downloadSize: 980_000_000,
        disablesThinking: true
    )

    /// Qwen3 4B Instruct (2507): best at following instructions, slowest.
    public static let qwen3 = CleanupModel(
        id: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
        displayName: "Qwen3 4B Instruct",
        downloadSize: 2_280_000_000,
        disablesThinking: false
    )

    public static let all: [CleanupModel] = [lfm25, qwen3Small, qwen3]

    public static func named(_ id: String) -> CleanupModel? {
        all.first { $0.id == id }
    }

    public static func == (lhs: CleanupModel, rhs: CleanupModel) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
