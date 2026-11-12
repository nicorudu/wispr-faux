import Foundation

/// Writes 16-bit PCM WAV files, which `afplay`, QuickTime and Whisper tools all read.
/// Only for checking recordings by ear during development; dictation keeps audio in memory.
public enum WAVEncoder {
    public static let headerSize = 44

    /// Mono 16-bit little-endian PCM. Samples are clamped to −1…1.
    public static func encode(_ samples: [Float], sampleRate: Int = Int(AudioFormat.sampleRate)) -> Data {
        let channels = 1
        let bytesPerSample = 2
        let dataSize = samples.count * channels * bytesPerSample

        var data = Data(capacity: headerSize + dataSize)
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLittleEndian(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))

        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLittleEndian(UInt32(16))                                     // chunk size
        data.appendLittleEndian(UInt16(1))                                      // PCM
        data.appendLittleEndian(UInt16(channels))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(sampleRate * channels * bytesPerSample)) // byte rate
        data.appendLittleEndian(UInt16(channels * bytesPerSample))              // block align
        data.appendLittleEndian(UInt16(bytesPerSample * 8))                     // bits per sample

        data.append(contentsOf: Array("data".utf8))
        data.appendLittleEndian(UInt32(dataSize))
        let pcm = samples.map { int16($0).littleEndian }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    static func int16(_ sample: Float) -> Int16 {
        let clamped = sample.isNaN ? 0 : min(1, max(-1, sample))
        return Int16((clamped * Float(Int16.max)).rounded())
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
