/// A speech-to-text engine. Wispr Faux's is on-device WhisperKit: audio never leaves the Mac.
public protocol Transcriber: Sendable {
    /// - Parameter pcm16k: Mono Float32 samples at 16 kHz.
    func transcribe(_ pcm16k: [Float]) async throws -> Transcription
}

public struct Transcription: Sendable, Equatable {
    /// The raw transcript, before any post-processing.
    public var text: String
    public var audioDuration: Duration
    /// Wall-clock time spent transcribing.
    public var processingDuration: Duration
    /// The language Whisper transcribed in, e.g. "es" (detected or as set).
    public var language: String?

    public init(text: String, audioDuration: Duration, processingDuration: Duration, language: String? = nil) {
        self.text = text
        self.audioDuration = audioDuration
        self.processingDuration = processingDuration
        self.language = language
    }

    /// Processing time over audio length: 0.1 means ten times faster than real time.
    public var realTimeFactor: Double {
        audioDuration > .zero ? processingDuration / audioDuration : 0
    }
}
