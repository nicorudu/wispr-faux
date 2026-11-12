@preconcurrency import AVFoundation
import os

/// The microphone for a dictation session. It runs for the whole session, which is what keeps
/// the app alive in the background (the `audio` background mode). iOS only lets an app *start*
/// recording while it's in the foreground, which is why a session starts in the app.
///
/// Audio is converted to 16 kHz mono as it arrives. Between dictations only the last 0.3 s is
/// kept, in memory, so a press records at once and includes the instant before it. Nothing is
/// written to disk.
final class SessionMicrophone: @unchecked Sendable {
    static let sampleRate: Double = 16_000
    private static let preRollSamples = Int(sampleRate * 0.3)
    private static let maxSamples = Int(sampleRate * 5 * 60)

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private var ring = [Float](repeating: 0, count: SessionMicrophone.preRollSamples)
    private var ringPosition = 0
    private var ringCount = 0
    private var recording: [Float]?
    private var lastBeat = Date.distantPast
    private var lastLevelWrite = Date.distantPast

    /// Called (on the audio thread) with each buffer's peak, 0…1, while recording.
    var onLevel: ((Float) -> Void)?
    /// Called on the audio thread about once a second while audio flows.
    var onHeartbeat: (() -> Void)?

    private let log = Logger(subsystem: "WisprFauxPhone", category: "Audio")

    var isRunning: Bool { engine.isRunning }

    /// Sets up the audio session and starts the microphone. Must be called in the foreground.
    func start() throws {
        let session = AVAudioSession.sharedInstance()
        // Play-and-record mixed with others: music and podcasts keep playing, and keep playing
        // through the speaker or AirPods (Bluetooth headsets aren't switched to their call
        // mode; the iPhone's own microphone is used).
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "WisprFaux", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone is available."])
        }
        converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
        log.notice("Microphone running: \(inputFormat.sampleRate, privacy: .public) Hz × \(inputFormat.channelCount, privacy: .public)")
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.withLock {
            recording = nil
            ringCount = 0
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Restarts after an interruption (a call, Siri). Fails if iOS won't let a background app
    /// restart the microphone; the session then ends.
    func restart() throws {
        try AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning { try engine.start() }
    }

    func beginRecording() {
        lock.withLock {
            var samples = [Float]()
            samples.reserveCapacity(Int(Self.sampleRate) * 10)
            let start = (ringPosition - ringCount + ring.count) % ring.count
            for i in 0..<ringCount { samples.append(ring[(start + i) % ring.count]) }
            ringCount = 0
            recording = samples
        }
    }

    /// Ends the recording and returns its samples. Waits briefly so the end of the last word,
    /// still in the tap's buffer, makes it in.
    func endRecording() async -> [Float] {
        try? await Task.sleep(for: .milliseconds(120))
        return lock.withLock {
            let samples = recording ?? []
            recording = nil
            return samples
        }
    }

    func cancelRecording() {
        lock.withLock { recording = nil }
    }

    // MARK: - Audio thread

    private func process(_ buffer: AVAudioPCMBuffer) {
        let now = Date()
        if now.timeIntervalSince(lastBeat) > 1 {
            lastBeat = now
            onHeartbeat?()
        }
        guard let converter, let mono = convert(buffer, with: converter) else { return }

        var peak: Float = 0
        let isRecording: Bool = lock.withLock {
            if recording != nil {
                if recording!.count < Self.maxSamples { recording!.append(contentsOf: mono) }
                return true
            }
            for sample in mono {
                ring[ringPosition] = sample
                ringPosition = (ringPosition + 1) % ring.count
            }
            ringCount = min(ring.count, ringCount + mono.count)
            return false
        }
        guard isRecording else { return }
        for sample in mono { peak = max(peak, abs(sample)) }
        if now.timeIntervalSince(lastLevelWrite) > 0.08 {
            lastLevelWrite = now
            onLevel?(Self.meterValue(peak))
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> [Float]? {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let data = output.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }

    /// 0 at −60 dBFS or below, 1 at full scale.
    static func meterValue(_ amplitude: Float) -> Float {
        guard amplitude > 0 else { return 0 }
        let db = 20 * log10(amplitude)
        return min(1, max(0, (db + 60) / 60))
    }
}

/// Whether a recording is worth transcribing (Whisper invents text for silence and taps).
enum SpeechGate {
    enum Verdict { case speech, tooShort, tooQuiet }

    /// Loudest 30 ms window, in dBFS.
    static func loudestWindowDBFS(_ samples: [Float]) -> Float {
        let window = Int(SessionMicrophone.sampleRate * 0.03)
        var loudest: Float = 0
        var start = 0
        while start < samples.count {
            let end = min(start + window, samples.count)
            var sum: Float = 0
            for i in start..<end { sum += samples[i] * samples[i] }
            loudest = max(loudest, (sum / Float(end - start)).squareRoot())
            start = end
        }
        return loudest > 0 ? 20 * log10(loudest) : -120
    }

    static func verdict(heldFor held: TimeInterval, samples: [Float]) -> Verdict {
        if held < 0.25 { return .tooShort }
        if loudestWindowDBFS(samples) < -45 { return .tooQuiet }
        return .speech
    }
}
