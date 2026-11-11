/// A speech-to-text engine. The MVP engine is on-device WhisperKit (Step 5); a cloud
/// engine can be added later behind the same protocol.
public protocol Transcriber: Sendable {
    /// - Parameter pcm16k: Mono Float32 samples at 16 kHz.
    /// - Returns: The raw transcript, before any post-processing.
    func transcribe(_ pcm16k: [Float]) async throws -> String
}
