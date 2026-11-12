import WhisperKit

/// A Whisper model converted to Core ML by Argmax
/// (huggingface.co/argmaxinc/whisperkit-coreml).
public struct WhisperModel: Sendable, Hashable, Identifiable, CustomStringConvertible {
    /// Folder name in the model repo, e.g. "openai_whisper-small.en".
    public let id: String
    public let displayName: String
    /// Approximate download, in bytes. The tokenizer adds a few MB.
    public let downloadSize: Int64
    /// English-only models can't transcribe other languages.
    public let isEnglishOnly: Bool
    let family: Family

    public var description: String { id }

    /// Which tokenizer the model uses.
    enum Family: Sendable, Hashable {
        case smallEnglish
        case largeV3

        var variant: ModelVariant {
            switch self {
            case .smallEnglish: .smallEn
            case .largeV3: .largev3
            }
        }

        /// Hugging Face repo the tokenizer comes from.
        var tokenizerRepo: String {
            switch self {
            case .smallEnglish: "openai/whisper-small.en"
            case .largeV3: "openai/whisper-large-v3"
            }
        }
    }

    /// Fast and small; English only.
    public static let smallEnglish = WhisperModel(
        id: "openai_whisper-small.en",
        displayName: "Whisper small (English)",
        downloadSize: 487_000_000,
        isEnglishOnly: true,
        family: .smallEnglish
    )

    /// OpenAI's large-v3-turbo (2024-09-30): large-v3 accuracy with a 4-layer decoder.
    public static let largeV3Turbo = WhisperModel(
        id: "openai_whisper-large-v3-v20240930_turbo",
        displayName: "Whisper large-v3 turbo",
        downloadSize: 1_638_000_000,
        isEnglishOnly: false,
        family: .largeV3
    )

    /// large-v3-turbo with compressed weights: about 40% of the download.
    public static let largeV3TurboCompressed = WhisperModel(
        id: "openai_whisper-large-v3-v20240930_turbo_632MB",
        displayName: "Whisper large-v3 turbo (compressed)",
        downloadSize: 646_000_000,
        isEnglishOnly: false,
        family: .largeV3
    )

    public static let all: [WhisperModel] = [smallEnglish, largeV3TurboCompressed, largeV3Turbo]

    public static func named(_ id: String) -> WhisperModel? {
        all.first { $0.id == id }
    }
}
