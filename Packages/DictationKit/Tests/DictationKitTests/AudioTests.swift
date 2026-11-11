import AVFAudio
import Foundation
import Testing
@testable import AudioKit

// MARK: - Helpers

/// Non-interleaved Float32, like an input node's format. Above two channels macOS needs a
/// channel layout, as multi-channel interfaces report.
private func floatFormat(sampleRate: Double, channels: AVAudioChannelCount) -> AVAudioFormat {
    if channels <= 2 {
        return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
    }
    let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)!
    return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
}

/// A sine wave as a non-interleaved Float32 buffer, identical in every channel.
private func sineBuffer(
    frequency: Double, amplitude: Float, sampleRate: Double,
    channels: AVAudioChannelCount, frames: Int, startFrame: Int = 0
) -> AVAudioPCMBuffer {
    let format = floatFormat(sampleRate: sampleRate, channels: channels)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for channel in 0..<Int(channels) {
        let data = buffer.floatChannelData![channel]
        for i in 0..<frames {
            data[i] = amplitude * Float(sin(2 * .pi * frequency * Double(startFrame + i) / sampleRate))
        }
    }
    return buffer
}

/// Feeds `seconds` of a sine through a `MonoResampler` in `chunk`-frame buffers, like a tap.
private func resampledSine(
    sampleRate: Double, channels: AVAudioChannelCount, seconds: Double, chunk: Int,
    frequency: Double = 440, amplitude: Float = 0.5
) throws -> [Float] {
    let resampler = try MonoResampler(
        inputFormat: floatFormat(sampleRate: sampleRate, channels: channels)
    )
    let total = Int(sampleRate * seconds)
    var output: [Float] = []
    var start = 0
    while start < total {
        let frames = min(chunk, total - start)
        let buffer = sineBuffer(
            frequency: frequency, amplitude: amplitude, sampleRate: sampleRate,
            channels: channels, frames: frames, startFrame: start
        )
        try resampler.convert(buffer, into: &output)
        start += frames
    }
    try resampler.finish(into: &output)
    return output
}

private func sine(frequency: Double = 440, amplitude: Float, seconds: Double, sampleRate: Double = 16_000) -> [Float] {
    (0..<Int(sampleRate * seconds)).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
}

private func rms(_ samples: ArraySlice<Float>) -> Float {
    (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
}

private func zeroCrossings(_ samples: ArraySlice<Float>) -> Int {
    zip(samples, samples.dropFirst()).count { ($0 < 0) != ($1 < 0) }
}

// MARK: - Resampling

struct InputCase: Sendable, CustomTestStringConvertible {
    var sampleRate: Double
    var channels: AVAudioChannelCount
    var chunk: Int
    var testDescription: String { "\(Int(sampleRate)) Hz × \(channels) ch, \(chunk)-frame buffers" }
}

@Suite("MonoResampler")
struct MonoResamplerTests {
    @Test(arguments: [
        InputCase(sampleRate: 48_000, channels: 1, chunk: 4_800),  // built-in mic, typical tap size
        InputCase(sampleRate: 48_000, channels: 1, chunk: 1_024),
        InputCase(sampleRate: 44_100, channels: 2, chunk: 4_410),  // USB / stereo interface
        InputCase(sampleRate: 24_000, channels: 1, chunk: 512),    // AirPods in call mode
        InputCase(sampleRate: 16_000, channels: 1, chunk: 1_600),  // already the target rate
        InputCase(sampleRate: 96_000, channels: 4, chunk: 960),
    ])
    func convertsToSixteenKilohertzMono(_ input: InputCase) throws {
        let seconds = 1.0
        let output = try resampledSine(
            sampleRate: input.sampleRate, channels: input.channels, seconds: seconds, chunk: input.chunk
        )

        // Length: one second at 16 kHz, give or take the filter's edges.
        #expect(abs(output.count - 16_000) <= 32, "got \(output.count) samples")

        // Away from the edges: same loudness (downmix averages, it doesn't sum) and pitch.
        let middle = output[1_600..<(output.count - 1_600)]
        let expectedRMS = Float(0.5 / 2.0.squareRoot())
        #expect(abs(rms(middle) - expectedRMS) < 0.01, "RMS \(rms(middle))")
        let expectedCrossings = 2 * 440 * Double(middle.count) / 16_000
        #expect(abs(Double(zeroCrossings(middle)) - expectedCrossings) <= 2)
    }

    /// Streaming must not glitch at buffer boundaries: small buffers give the same audio as
    /// one big one. (Ending the stream after every buffer would reset the filter each time.)
    @Test func bufferBoundariesAreSeamless() throws {
        let whole = try resampledSine(sampleRate: 48_000, channels: 1, seconds: 1, chunk: 48_000)
        let chunked = try resampledSine(sampleRate: 48_000, channels: 1, seconds: 1, chunk: 480)
        #expect(whole.count == chunked.count)
        let largestDifference = zip(whole, chunked).map { abs($0 - $1) }.max() ?? 0
        #expect(largestDifference < 1e-4)
    }

    @Test func finishIsIdempotent() throws {
        let resampler = try MonoResampler(inputFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!)
        var output: [Float] = []
        try resampler.convert(sineBuffer(frequency: 440, amplitude: 0.5, sampleRate: 48_000, channels: 1, frames: 4_800), into: &output)
        try resampler.finish(into: &output)
        let count = output.count
        try resampler.finish(into: &output)
        try resampler.convert(sineBuffer(frequency: 440, amplitude: 0.5, sampleRate: 48_000, channels: 1, frames: 4_800), into: &output)
        #expect(output.count == count)
    }
}

// MARK: - Capture buffer

@Suite("CaptureBuffer")
struct CaptureBufferTests {
    @Test func collectsSamplesAndTracksLevel() throws {
        let meter = LevelMeter()
        let capture = try CaptureBuffer(
            inputFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!,
            maximumSamples: 16_000 * 10, meter: meter
        )
        for i in 0..<10 {
            let buffer = sineBuffer(frequency: 440, amplitude: 0.5, sampleRate: 48_000, channels: 1, frames: 4_800, startFrame: i * 4_800)
            capture.append(buffer, at: AVAudioTime(hostTime: 1_000 + UInt64(i)))
        }
        // −9 dBFS reads as 0.85 on the 60 dB meter.
        #expect(abs(meter.value - 0.85) < 0.02)

        let result = capture.finish()
        #expect(abs(result.samples.count - 16_000) <= 32)
        #expect(result.firstHostTime == 1_000)
        #expect(result.tapBufferFrames == 4_800)
        #expect(result.inputChannelPeaks.count == 1 && abs(result.inputChannelPeaks[0] - 0.5) < 0.001)
        #expect(!result.wasTruncated && !result.wasInterrupted && result.conversionError == nil)
        #expect(meter.value == 0)

        // Late buffers after finish are ignored.
        capture.append(sineBuffer(frequency: 440, amplitude: 0.5, sampleRate: 48_000, channels: 1, frames: 4_800), at: AVAudioTime(hostTime: 9))
        #expect(capture.finish().samples.count == result.samples.count)
    }

    @Test func stopsAtTheMaximumLength() throws {
        let capture = try CaptureBuffer(
            inputFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!,
            maximumSamples: 8_000, meter: LevelMeter()
        )
        for i in 0..<10 {
            capture.append(
                sineBuffer(frequency: 440, amplitude: 0.5, sampleRate: 48_000, channels: 1, frames: 4_800, startFrame: i * 4_800),
                at: AVAudioTime(hostTime: 1)
            )
        }
        let result = capture.finish()
        #expect(result.samples.count == 8_000)
        #expect(result.wasTruncated)
    }

    /// `MicrophoneRecorder.stop` waits on this so the last buffer before the release isn't lost.
    @Test func knowsHowFarTheAudioHasArrived() throws {
        let capture = try CaptureBuffer(
            inputFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!,
            maximumSamples: 16_000 * 10, meter: LevelMeter()
        )
        let start: UInt64 = 1_000_000_000
        let ms = { (milliseconds: Double) in AVAudioTime.hostTime(forSeconds: milliseconds / 1_000) }
        #expect(!capture.hasAudio(through: start))

        // One 100 ms buffer starting at `start`.
        capture.append(sineBuffer(frequency: 440, amplitude: 0.5, sampleRate: 48_000, channels: 1, frames: 4_800), at: AVAudioTime(hostTime: start))
        #expect(capture.hasAudio(through: start + ms(50)))
        #expect(capture.hasAudio(through: start + ms(99)))
        #expect(!capture.hasAudio(through: start + ms(150)))

        // An interrupted engine sends nothing more, so there's nothing to wait for.
        capture.markInterrupted()
        #expect(capture.hasAudio(through: start + ms(10_000)))
    }

    @Test func recordsInterruptions() throws {
        let capture = try CaptureBuffer(
            inputFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!,
            maximumSamples: 16_000, meter: LevelMeter()
        )
        capture.markInterrupted()
        #expect(capture.finish().wasInterrupted)
    }
}

// MARK: - Levels and the speech gate

@Suite("Levels")
struct LevelTests {
    @Test func silence() {
        let stats = LevelStats(samples: [Float](repeating: 0, count: 16_000))
        #expect(stats.peak == 0 && stats.rms == 0 && stats.loudestWindowRMS == 0)
        #expect(stats.peakDBFS == Decibels.floor)
        #expect(LevelStats(samples: []) == .silence)
    }

    @Test func sineLevels() {
        let stats = LevelStats(samples: sine(amplitude: 0.5, seconds: 1))
        #expect(abs(stats.peak - 0.5) < 0.001)
        #expect(abs(stats.rms - 0.3536) < 0.001)
        #expect(abs(stats.rmsDBFS - -9.03) < 0.05)
        #expect(stats.clippedSampleCount == 0)
    }

    @Test func countsClippedSamples() {
        let samples: [Float] = [0.2, 1.0, -1.0, 0.9995, 0.5]
        #expect(LevelStats(samples: samples).clippedSampleCount == 3)
    }

    @Test func loudestWindowFindsAShortBurst() {
        // Two seconds of silence with 60 ms of speech-level sine in the middle.
        var samples = [Float](repeating: 0, count: 32_000)
        let burst = sine(amplitude: 0.5, seconds: 0.06)
        samples.replaceSubrange(16_000..<(16_000 + burst.count), with: burst)
        let stats = LevelStats(samples: samples)
        #expect(stats.loudestWindowRMS > 0.3)
        #expect(stats.rms < 0.1)
    }

    @Test func meterScale() {
        #expect(Decibels.meterValue(forAmplitude: 1) == 1)
        #expect(Decibels.meterValue(forAmplitude: 0.001) < 0.001)   // −60 dBFS
        #expect(abs(Decibels.meterValue(forAmplitude: 0.0316) - 0.5) < 0.01) // −30 dBFS
        #expect(Decibels.meterValue(forAmplitude: 0) == 0)
    }

    @Test func speechGate() {
        let gate = SpeechGate()
        let loud = LevelStats(samples: sine(amplitude: 0.1, seconds: 1))
        let roomNoise = LevelStats(samples: sine(amplitude: 0.001, seconds: 1)) // −63 dBFS RMS

        #expect(gate.verdict(duration: .milliseconds(200), levels: loud) == .tooShort)
        #expect(gate.verdict(duration: .milliseconds(250), levels: loud) == .speech)
        #expect(gate.verdict(duration: .seconds(1), levels: roomNoise) == .tooQuiet)
        #expect(gate.verdict(duration: .seconds(1), levels: .silence) == .tooQuiet)
    }
}

// MARK: - WAV

@Suite("WAVEncoder")
struct WAVEncoderTests {
    @Test func header() {
        let data = WAVEncoder.encode([0, 0.5, -0.5])
        #expect(data.count == 44 + 6)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        #expect(String(decoding: data[36..<40], as: UTF8.self) == "data")

        func uint32(at offset: Int) -> UInt32 {
            data[offset..<(offset + 4)].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) }
        }
        func uint16(at offset: Int) -> UInt16 {
            UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
        }
        #expect(uint32(at: 4) == 36 + 6)      // RIFF size
        #expect(uint16(at: 20) == 1)          // PCM
        #expect(uint16(at: 22) == 1)          // mono
        #expect(uint32(at: 24) == 16_000)     // sample rate
        #expect(uint32(at: 28) == 32_000)     // byte rate
        #expect(uint16(at: 34) == 16)         // bits per sample
        #expect(uint32(at: 40) == 6)          // data size
    }

    @Test func quantization() {
        #expect(WAVEncoder.int16(0) == 0)
        #expect(WAVEncoder.int16(1) == 32_767)
        #expect(WAVEncoder.int16(-1) == -32_767)
        #expect(WAVEncoder.int16(3) == 32_767)
        #expect(WAVEncoder.int16(-3) == -32_767)
        #expect(WAVEncoder.int16(.nan) == 0)
    }

    /// Apple's own reader opens the file as 16 kHz mono with the same samples.
    @Test func roundTripsThroughAVAudioFile() throws {
        let samples = sine(amplitude: 0.5, seconds: 0.5)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try WAVEncoder.encode(samples).write(to: url)

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.length == AVAudioFramePosition(samples.count))

        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let read = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        let largestError = zip(samples, read).map { abs($0 - $1) }.max() ?? 1
        #expect(largestError < 1.0 / 32_000)
    }
}

// MARK: - Objective-C exceptions

@Suite("ObjCException")
struct ObjCExceptionTests {
    /// AVAudioEngine raises these (e.g. "Input HW format is invalid" while a USB mic is
    /// reconnecting); they must become errors, not abort the app.
    @Test func turnsAnExceptionIntoAnError() {
        #expect {
            try ObjCException.catching {
                NSException(name: .internalInconsistencyException, reason: "Input HW format is invalid").raise()
            }
        } throws: { error in
            error.localizedDescription == "Input HW format is invalid"
        }
    }

    @Test func passesValuesAndSwiftErrorsThrough() throws {
        #expect(try ObjCException.catching { 42 } == 42)

        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try ObjCException.catching { throw Boom() }
        }
    }
}
