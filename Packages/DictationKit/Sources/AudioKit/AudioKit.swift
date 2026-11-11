/// Sample format handed to the transcriber.
public enum AudioFormat {
    public static let sampleRate: Double = 16_000
    public static let channelCount = 1
}

/// `AVAudioEngine` input tap converted to 16 kHz mono Float32 with `AVAudioConverter`.
/// Starts on hotkey-down (never always-on), exposes a live level for the status pill,
/// and rejects presses that are too short or too quiet to transcribe.
///
/// Implemented in Step 4.
public final class MicrophoneRecorder {
    public init() {}
}
