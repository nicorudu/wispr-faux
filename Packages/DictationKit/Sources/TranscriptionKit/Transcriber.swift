/// A speech-to-text engine. Dictate's is on-device WhisperKit: audio never leaves the Mac.
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

    public init(text: String, audioDuration: Duration, processingDuration: Duration) {
        self.text = text
        self.audioDuration = audioDuration
        self.processingDuration = processingDuration
    }

    /// Processing time over audio length: 0.1 means ten times faster than real time.
    public var realTimeFactor: Double {
        audioDuration > .zero ? processingDuration / audioDuration : 0
    }
}
