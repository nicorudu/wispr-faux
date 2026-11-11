import AVFAudio

/// Sample format handed to the transcriber: what Whisper models expect.
public enum AudioFormat {
    public static let sampleRate: Double = 16_000
    public static let channelCount = 1

    /// 16 kHz mono Float32, non-interleaved.
    public static var pcm: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        )!
    }

    public static func duration(ofSampleCount count: Int) -> Duration {
        .seconds(Double(count) / sampleRate)
    }
}
