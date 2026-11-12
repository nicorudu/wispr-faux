import Accelerate
import AVFAudio
import Darwin
import os

/// One finished recording, converted to 16 kHz mono.
public struct Recording: Sendable {
    /// 16 kHz mono Float32: what the transcriber takes.
    public var samples: [Float]
    public var device: InputDevice
    public var levels: LevelStats
    /// From the start request (the hotkey going down) to the first sample captured.
    /// Speech in this gap is lost (BUILD_PLAN.md §5, gotcha 10).
    public var firstSampleDelay: Duration?
    /// Creating, preparing and starting the audio engine.
    public var engineStartDuration: Duration
    /// How long `stop` kept the mic on after the release, waiting for the audio up to it.
    public var tailWait: Duration
    /// Stopping the engine and draining the resampler, after the tail wait.
    public var stopDuration: Duration
    /// Frames in the first tap buffer, at the device's sample rate.
    public var tapBufferFrames: Int?
    /// Peak of each input channel before the mix to mono (linear). Tells a quiet mic apart
    /// from channels that cancel out or a dead channel on multi-channel devices.
    public var inputChannelPeaks: [Float]
    /// Reached `MicrophoneRecorder.maximumDuration`; later audio was dropped.
    public var wasTruncated: Bool
    /// The audio setup changed mid-recording (device unplugged, default input switched),
    /// which stops the engine early. The audio up to that point is kept.
    public var wasInterrupted: Bool
    /// Set if a buffer couldn't be converted; the samples stop there.
    public var conversionError: String?

    public var duration: Duration { AudioFormat.duration(ofSampleCount: samples.count) }
}

public enum RecorderError: Error, LocalizedError, Equatable {
    case alreadyRecording
    /// No input device, or it's unplugged, reconnecting or waking up.
    case microphoneUnavailable
    case unsupportedFormat(String)
    case engineFailed(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRecording: "Already recording."
        case .microphoneUnavailable: "The microphone isn't available. If it was just plugged in, try again in a moment."
        case .unsupportedFormat(let format): "The microphone's format isn't supported (\(format))."
        case .engineFailed(let reason): "The microphone didn't start: \(reason)"
        }
    }
}

/// Records the default microphone with `AVAudioEngine` and converts it to 16 kHz mono
/// (BUILD_PLAN.md §1, "Audio").
///
/// A new engine is built on every `start()` and torn down on `stop()`, so the mic (and
/// macOS's orange privacy dot) is on only while recording, and a change of default input
/// applies to the next recording.
///
/// Runs on its own serial queue: starting the engine blocks for a while and shouldn't
/// hold up the main thread.
public actor MicrophoneRecorder {
    public nonisolated let maximumDuration: Duration
    /// The longest `stop` keeps the mic on waiting for the last buffer.
    public static let tailTimeout: Duration = .milliseconds(300)

    private nonisolated let queue = DispatchSerialQueue(label: "WisprFaux.MicrophoneRecorder", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private nonisolated let meter = LevelMeter()
    private var session: Session?

    public init(maximumDuration: Duration = .seconds(300)) {
        self.maximumDuration = maximumDuration
    }

    /// Live input level from 0 (−60 dBFS or quieter) to 1 (full scale), for meters.
    /// Callable from any thread; 0 when not recording.
    public nonisolated var level: Float { meter.value }

    public var isRecording: Bool { session != nil }

    /// Starts recording from the default input. `requestedAt` (a `mach_absolute_time()`)
    /// is the moment the user asked, used to measure `Recording.firstSampleDelay`; the
    /// default is taken at the call site, before the hop onto this actor.
    @discardableResult
    public func start(requestedAt: UInt64 = mach_absolute_time()) throws -> InputDevice {
        guard session == nil else { throw RecorderError.alreadyRecording }
        let began = ContinuousClock.now

        // AVAudioEngine raises Objective-C exceptions for some device problems; uncaught,
        // they'd abort the app. `ObjCException.catching` turns them into errors.
        let engine = AVAudioEngine()
        let node: (input: AVAudioInputNode, hardware: AVAudioFormat, output: AVAudioFormat)
        do {
            node = try ObjCException.catching {
                let input = engine.inputNode
                return (input, input.inputFormat(forBus: 0), input.outputFormat(forBus: 0))
            }
        } catch {
            throw RecorderError.engineFailed(error.localizedDescription)
        }
        let input = node.input
        let format = node.output
        // While a USB mic is unplugged or reconnecting, the hardware side reads 0 Hz even
        // when the node's output format still looks fine, and installing a tap then raises
        // "Input HW format is invalid".
        guard node.hardware.sampleRate > 0, node.hardware.channelCount > 0,
              format.sampleRate > 0, format.channelCount > 0
        else {
            throw RecorderError.microphoneUnavailable
        }
        let device = InputDevice.systemDefault(sampleRate: format.sampleRate, channelCount: Int(format.channelCount))

        let capture: CaptureBuffer
        do {
            let maximumSamples = Int(AudioFormat.sampleRate * (maximumDuration / .seconds(1)))
            capture = try CaptureBuffer(inputFormat: format, maximumSamples: maximumSamples, meter: meter)
        } catch {
            throw RecorderError.unsupportedFormat(format.description)
        }

        // `@Sendable` keeps these closures off this actor: AVAudioEngine and
        // NotificationCenter call them on their own threads.
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { @Sendable _ in
            capture.markInterrupted()
        }
        do {
            try ObjCException.catching {
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable (buffer, time) in
                    capture.append(buffer, at: time)
                }
                engine.prepare()
                try engine.start()
            }
        } catch {
            Session.stop(engine)
            NotificationCenter.default.removeObserver(observer)
            throw RecorderError.engineFailed(error.localizedDescription)
        }

        session = Session(
            engine: engine,
            capture: capture,
            observer: observer,
            device: device,
            requestedAt: requestedAt,
            engineStartDuration: .now - began
        )
        return device
    }

    /// Stops the microphone and returns what was recorded, or nil if not recording.
    ///
    /// Tap buffers arrive whole (100 ms each on many devices) once they're full, so
    /// stopping straight away would drop the end of the last word. `stop` first waits,
    /// up to `tailTimeout`, for the buffer that covers `releasedAt` (a `mach_absolute_time()`).
    public func stop(releasedAt: UInt64 = mach_absolute_time()) async -> Recording? {
        guard let session else { return nil }
        self.session = nil

        let waitStarted = ContinuousClock.now
        while !session.capture.hasAudio(through: releasedAt), ContinuousClock.now - waitStarted < Self.tailTimeout {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let tailWait = ContinuousClock.now - waitStarted
        let stopStarted = ContinuousClock.now
        session.tearDown()
        let captured = session.capture.finish()
        let stopDuration = ContinuousClock.now - stopStarted

        let firstSampleDelay = captured.firstHostTime.map { first in
            Duration.seconds(AVAudioTime.seconds(forHostTime: first) - AVAudioTime.seconds(forHostTime: session.requestedAt))
        }
        return Recording(
            samples: captured.samples,
            device: session.device,
            levels: LevelStats(samples: captured.samples),
            firstSampleDelay: firstSampleDelay,
            engineStartDuration: session.engineStartDuration,
            tailWait: tailWait,
            stopDuration: stopDuration,
            tapBufferFrames: captured.tapBufferFrames,
            inputChannelPeaks: captured.inputChannelPeaks,
            wasTruncated: captured.wasTruncated,
            wasInterrupted: captured.wasInterrupted,
            conversionError: captured.conversionError
        )
    }

    /// Stops the microphone and throws the audio away.
    public func cancel() {
        guard let session else { return }
        self.session = nil
        session.tearDown()
        _ = session.capture.finish()
    }

    private struct Session {
        let engine: AVAudioEngine
        let capture: CaptureBuffer
        let observer: any NSObjectProtocol
        let device: InputDevice
        let requestedAt: UInt64
        let engineStartDuration: Duration

        func tearDown() {
            Self.stop(engine)
            NotificationCenter.default.removeObserver(observer)
        }

        /// Removes the tap and stops the engine, even if the device has gone away.
        static func stop(_ engine: AVAudioEngine) {
            _ = try? ObjCException.catching {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
        }
    }
}

/// Collects converted samples on AVAudioEngine's tap thread. Tap blocks don't run on the
/// real-time I/O thread, so converting there under a short, uncontended lock is fine.
final class CaptureBuffer: @unchecked Sendable {
    struct Result {
        var samples: [Float]
        var firstHostTime: UInt64?
        var tapBufferFrames: Int?
        var inputChannelPeaks: [Float]
        var wasTruncated: Bool
        var wasInterrupted: Bool
        var conversionError: String?
    }

    private let lock = OSAllocatedUnfairLock()
    private let meter: LevelMeter
    private let maximumSamples: Int
    private let hostTicksPerFrame: Double
    // Everything below is guarded by `lock`.
    private let resampler: MonoResampler
    private var samples: [Float] = []
    private var firstHostTime: UInt64?
    /// Host time just past the last sample received.
    private var receivedThroughHostTime: UInt64?
    private var tapBufferFrames: Int?
    private var inputChannelPeaks: [Float]
    private var wasTruncated = false
    private var wasInterrupted = false
    private var conversionError: String?
    private var isClosed = false

    init(inputFormat: AVAudioFormat, maximumSamples: Int, meter: LevelMeter) throws {
        resampler = try MonoResampler(inputFormat: inputFormat)
        self.maximumSamples = maximumSamples
        self.meter = meter
        hostTicksPerFrame = Double(AVAudioTime.hostTime(forSeconds: 1)) / inputFormat.sampleRate
        inputChannelPeaks = Array(repeating: 0, count: Int(inputFormat.channelCount))
        // A minute up front, so typical dictations never reallocate on the tap thread.
        samples.reserveCapacity(min(maximumSamples, Int(AudioFormat.sampleRate) * 60))
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }

        if tapBufferFrames == nil {
            tapBufferFrames = Int(buffer.frameLength)
            // The host time of the buffer's first sample.
            firstHostTime = time.isHostTimeValid ? time.hostTime : nil
        }
        if time.isHostTimeValid {
            receivedThroughHostTime = time.hostTime + UInt64(Double(buffer.frameLength) * hostTicksPerFrame)
        }
        guard !wasTruncated, conversionError == nil else { return }

        if let channels = buffer.floatChannelData, !buffer.format.isInterleaved {
            for channel in inputChannelPeaks.indices {
                let peak = vDSP.maximumMagnitude(UnsafeBufferPointer(start: channels[channel], count: Int(buffer.frameLength)))
                inputChannelPeaks[channel] = max(inputChannelPeaks[channel], peak)
            }
        }

        let before = samples.count
        do {
            try resampler.convert(buffer, into: &samples)
        } catch {
            conversionError = String(describing: error)
            return
        }
        clampToMaximum()

        if samples.count > before {
            let rms = samples.withUnsafeBufferPointer {
                vDSP.rootMeanSquare(UnsafeBufferPointer(rebasing: $0[before...]))
            }
            meter.set(Decibels.meterValue(forAmplitude: rms))
        }
    }

    /// Whether the audio up to `hostTime` has arrived, or none will (interrupted, finished).
    func hasAudio(through hostTime: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isClosed || wasInterrupted { return true }
        return receivedThroughHostTime.map { $0 >= hostTime } ?? false
    }

    func markInterrupted() {
        lock.lock()
        defer { lock.unlock() }
        if !isClosed { wasInterrupted = true }
    }

    /// Drains the resampler and hands the samples over. Later buffers are ignored.
    func finish() -> Result {
        lock.lock()
        defer { lock.unlock() }
        if !isClosed {
            isClosed = true
            if !wasTruncated, conversionError == nil {
                try? resampler.finish(into: &samples)
                clampToMaximum()
            }
            meter.set(0)
        }
        return Result(
            samples: samples,
            firstHostTime: firstHostTime,
            tapBufferFrames: tapBufferFrames,
            inputChannelPeaks: inputChannelPeaks,
            wasTruncated: wasTruncated,
            wasInterrupted: wasInterrupted,
            conversionError: conversionError
        )
    }

    private func clampToMaximum() {
        guard samples.count > maximumSamples else { return }
        samples.removeSubrange(maximumSamples...)
        wasTruncated = true
    }
}

/// The latest input level, written by the tap thread and read by the UI.
final class LevelMeter: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: Float(0))

    var value: Float { state.withLock { $0 } }

    func set(_ value: Float) {
        state.withLock { $0 = value }
    }
}
