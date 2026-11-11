import AppKit
import AudioKit
import AVFAudio
import Observation
import os

/// Step 4 spike: saves the last recording as a temporary WAV so it can be played back and
/// checked, and reports its length, level and mic start-up delay in the menu. Only the
/// latest recording is kept, and it's deleted when Dictate quits. Dictation itself keeps
/// audio in memory; this goes away once transcription is wired up in Step 6.
@MainActor
@Observable
final class RecordingTester {
    /// e.g. "Last recording: 3.2 s · loudest −18 dBFS · would transcribe".
    private(set) var summary: String?
    /// e.g. "MacBook Air Microphone (built-in, 48 kHz) · first sample 42 ms after the key".
    private(set) var detail: String?
    /// Set while a WAV of the last recording exists.
    private(set) var wavURL: URL?

    static let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("Dictate", isDirectory: true)
        .appendingPathComponent("last-recording.wav")

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private let gate = SpeechGate()
    @ObservationIgnored private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Dictate", category: "Audio")

    func didRecord(_ recording: Recording, heldFor: Duration?) {
        let seconds = Self.seconds(recording.duration)
        let verdict = gate.verdict(duration: recording.duration, levels: recording.levels)

        var parts = ["Last recording: \(seconds) s"]
        if recording.samples.isEmpty {
            parts.append("no audio arrived before release")
        } else {
            parts.append("loudest \(Self.dBFS(recording.levels.loudestWindowDBFS))")
            let gateResult = switch verdict {
            case .speech: "would transcribe"
            case .tooShort: "too short to transcribe"
            case .tooQuiet: "too quiet to transcribe"
            }
            parts.append(gateResult)
        }
        if recording.levels.clippedSampleCount > 0 { parts.append("⚠︎ clipped") }
        if recording.wasTruncated { parts.append("⚠︎ cut off at the length limit") }
        if recording.wasInterrupted { parts.append("⚠︎ mic changed mid-recording") }
        if recording.conversionError != nil { parts.append("⚠︎ conversion failed") }
        summary = parts.joined(separator: " · ")

        let device = recording.device
        var deviceLine = "\(device.name) (\(device.transport.rawValue), \(Self.kilohertz(device.sampleRate)))"
        if device.isBluetooth { deviceLine += " ⚠︎ call-quality audio" }
        if let delay = recording.firstSampleDelay {
            deviceLine += " · first sample \(Self.ms(delay)) ms after the key"
        }
        detail = deviceLine

        let saved = save(recording.samples)

        log.notice("""
            Recorded \(seconds, privacy: .public) s (held \(heldFor.map(Self.ms) ?? -1, privacy: .public) ms): \
            \(recording.samples.count, privacy: .public) samples @ 16 kHz, \
            peak \(Self.dBFS(recording.levels.peakDBFS), privacy: .public), \
            RMS \(Self.dBFS(recording.levels.rmsDBFS), privacy: .public), \
            loudest 30 ms \(Self.dBFS(recording.levels.loudestWindowDBFS), privacy: .public), \
            clipped \(recording.levels.clippedSampleCount, privacy: .public), \
            gate \(String(describing: verdict), privacy: .public). \
            Device \(device.name, privacy: .public) [\(device.transport.rawValue, privacy: .public), \
            \(Int(device.sampleRate), privacy: .public) Hz × \(device.channelCount, privacy: .public) ch, \
            tap \(recording.tapBufferFrames ?? -1, privacy: .public) frames, \
            input channel peaks \(recording.inputChannelPeaks.map { Self.dBFS(Decibels.fromAmplitude($0)) }.joined(separator: " / "), privacy: .public)]. \
            Engine start \(Self.ms(recording.engineStartDuration), privacy: .public) ms, \
            tail wait \(Self.ms(recording.tailWait), privacy: .public) ms, \
            first sample \(recording.firstSampleDelay.map(Self.ms) ?? -1, privacy: .public) ms after key. \
            Truncated \(recording.wasTruncated, privacy: .public), interrupted \(recording.wasInterrupted, privacy: .public), \
            conversion error \(recording.conversionError ?? "none", privacy: .public). \
            WAV: \(saved ? Self.fileURL.path : "not saved", privacy: .public)
            """)
    }

    func didFail(_ message: String) {
        summary = message
        detail = nil
    }

    func play() {
        guard let wavURL else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: wavURL)
            self.player = player
            player.play()
        } catch {
            log.error("Playback failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Called when recording starts, so the mic doesn't pick up the playback.
    func stopPlayback() {
        player?.stop()
        player = nil
    }

    func revealInFinder() {
        guard let wavURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([wavURL])
    }

    /// Called on quit: no audio is left behind.
    func deleteRecording() {
        stopPlayback()
        try? FileManager.default.removeItem(at: Self.fileURL)
        wavURL = nil
    }

    private func save(_ samples: [Float]) -> Bool {
        stopPlayback()
        guard !samples.isEmpty else {
            deleteRecording()
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try WAVEncoder.encode(samples).write(to: Self.fileURL, options: .atomic)
            wavURL = Self.fileURL
            return true
        } catch {
            wavURL = nil
            log.error("Couldn't write the WAV: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Formatting

    nonisolated private static func seconds(_ duration: Duration) -> String {
        (duration / .seconds(1)).formatted(.number.precision(.fractionLength(1)))
    }

    nonisolated private static func ms(_ duration: Duration) -> Int {
        Int((duration / .milliseconds(1)).rounded())
    }

    nonisolated private static func dBFS(_ value: Float) -> String {
        value <= Decibels.floor ? "silent" : "\(Int(value.rounded())) dBFS"
    }

    nonisolated private static func kilohertz(_ hertz: Double) -> String {
        "\((hertz / 1_000).formatted(.number.precision(.fractionLength(0...1)))) kHz"
    }
}
