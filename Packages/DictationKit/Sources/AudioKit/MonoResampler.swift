import Accelerate
import AVFAudio

/// Converts audio from the input device's format (often 48 kHz, sometimes several
/// channels) to `AudioFormat.pcm`: 16 kHz mono Float32.
///
/// Multi-channel input is averaged to mono here rather than by `AVAudioConverter`, whose
/// downmix outputs silence for discrete channel layouts (as multi-channel interfaces and
/// aggregate devices report). The converter then only changes the sample rate.
///
/// Streaming: call `convert(_:into:)` for each buffer as it arrives, then `finish(into:)`
/// once to drain what the resampling filter is still holding. Not thread-safe: use it from
/// one thread at a time (`MicrophoneRecorder` calls it under a lock from the tap thread).
public final class MonoResampler {
    public enum ResamplerError: Error, Equatable {
        case unsupportedFormat(String)
        case conversionFailed(String)
    }

    public let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    /// Mono at the input rate, when channels are averaged here before resampling.
    private let mixFormat: AVAudioFormat?
    /// Reused between calls so the steady state doesn't allocate.
    private var outputBuffer: AVAudioPCMBuffer?
    private var mixBuffer: AVAudioPCMBuffer?
    private var isFinished = false

    public init(inputFormat: AVAudioFormat) throws {
        let outputFormat = AudioFormat.pcm
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw ResamplerError.unsupportedFormat(inputFormat.description)
        }
        // Input nodes deliver non-interleaved Float32; other multi-channel formats are rare
        // and left to the converter's own downmix.
        let mixesChannels = inputFormat.channelCount > 1
            && inputFormat.commonFormat == .pcmFormatFloat32
            && !inputFormat.isInterleaved
        let mixFormat = mixesChannels
            ? AVAudioFormat(standardFormatWithSampleRate: inputFormat.sampleRate, channels: 1)
            : nil
        guard let converter = AVAudioConverter(from: mixFormat ?? inputFormat, to: outputFormat) else {
            throw ResamplerError.unsupportedFormat(inputFormat.description)
        }
        converter.downmix = true
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.mixFormat = mixFormat
        self.converter = converter
    }

    /// Converts `buffer` and appends the result to `samples`.
    public func convert(_ buffer: AVAudioPCMBuffer, into samples: inout [Float]) throws {
        guard buffer.frameLength > 0, !isFinished else { return }
        var pending: AVAudioPCMBuffer? = try mixFormat == nil ? buffer : averagedToMono(buffer)
        try run(into: &samples, inputFrames: buffer.frameLength) { _, status in
            guard let next = pending else {
                // `.noDataNow`, not `.endOfStream`: the filter keeps its state for the next buffer.
                status.pointee = .noDataNow
                return nil
            }
            pending = nil
            status.pointee = .haveData
            return next
        }
    }

    /// Flushes the filter's tail into `samples`. Later calls do nothing.
    public func finish(into samples: inout [Float]) throws {
        guard !isFinished else { return }
        isFinished = true
        try run(into: &samples, inputFrames: 0) { _, status in
            status.pointee = .endOfStream
            return nil
        }
    }

    private func run(
        into samples: inout [Float],
        inputFrames: AVAudioFrameCount,
        input: @escaping AVAudioConverterInputBlock
    ) throws {
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        // Room for this buffer plus what the filter may still be holding back.
        let capacity = AVAudioFrameCount((Double(inputFrames) * ratio).rounded(.up)) + 512
        let output = try reusableOutputBuffer(capacity: capacity)

        while true {
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error, withInputFrom: input)
            let produced = Int(output.frameLength)
            if produced > 0, let channel = output.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: produced))
            }
            switch status {
            case .haveData where produced > 0:
                continue // The output filled up; more is waiting.
            case .haveData, .inputRanDry, .endOfStream:
                return
            case .error:
                throw ResamplerError.conversionFailed(error?.localizedDescription ?? "unknown error")
            @unknown default:
                return
            }
        }
    }

    /// The mean of all channels, in a reused buffer. `run` drains the converter before
    /// returning, so the buffer is free again by the next call.
    private func averagedToMono(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let mixFormat, let channels = buffer.floatChannelData else {
            throw ResamplerError.conversionFailed("expected non-interleaved Float32 input")
        }
        let frames = buffer.frameLength
        if mixBuffer.map({ $0.frameCapacity < frames }) ?? true {
            mixBuffer = AVAudioPCMBuffer(pcmFormat: mixFormat, frameCapacity: frames)
        }
        guard let mono = mixBuffer, let out = mono.floatChannelData?[0] else {
            throw ResamplerError.conversionFailed("couldn't allocate a \(frames)-frame buffer")
        }
        mono.frameLength = frames

        let count = vDSP_Length(frames)
        let channelCount = Int(buffer.format.channelCount)
        out.update(from: channels[0], count: Int(frames))
        for channel in 1..<channelCount {
            vDSP_vadd(out, 1, channels[channel], 1, out, 1, count)
        }
        var scale = 1 / Float(channelCount)
        vDSP_vsmul(out, 1, &scale, out, 1, count)
        return mono
    }

    private func reusableOutputBuffer(capacity: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        if let outputBuffer, outputBuffer.frameCapacity >= capacity {
            return outputBuffer
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw ResamplerError.conversionFailed("couldn't allocate a \(capacity)-frame buffer")
        }
        outputBuffer = buffer
        return buffer
    }
}
