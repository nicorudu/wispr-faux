import AudioKit
import AVFAudio
import Foundation
import TranscriptionKit

// Benchmarks Whisper models on audio files (BUILD_PLAN.md Step 5).
//
//   swift run -c release dictate-bench models
//   swift run -c release dictate-bench download <model>
//   swift run -c release dictate-bench run <model> <audio file>... [--runs N]
//
// For `run`, a .txt file next to an audio file (same name) is its reference transcript,
// used to report word error rate. Models live where the app finds them
// (~/Library/Application Support/Dictate/Models); `download` is the only command that
// uses the network.

let usage = """
    usage:
      dictate-bench models
      dictate-bench download <model>
      dictate-bench run <model> <audio file>... [--runs N]

    models: \(WhisperModel.all.map(\.id).joined(separator: ", "))
    """

let store = ModelStore.standard
var arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func model(named name: String?) -> WhisperModel {
    guard let name else { fail(usage) }
    // Accept the folder name or an unambiguous part of it, e.g. "small.en" or "turbo_632MB".
    if let exact = WhisperModel.named(name) { return exact }
    let matches = WhisperModel.all.filter { $0.id.hasSuffix(name) }
    guard matches.count == 1 else { fail("Unknown or ambiguous model \"\(name)\".\n\n\(usage)") }
    return matches[0]
}

func seconds(_ duration: Duration) -> String {
    (duration / .seconds(1)).formatted(.number.precision(.fractionLength(2)))
}

/// Reads any audio file and converts it to 16 kHz mono, as the app's recorder does.
func loadAudio(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let resampler = try MonoResampler(inputFormat: file.processingFormat)
    var samples: [Float] = []
    while file.framePosition < file.length {
        let chunk = AVAudioFrameCount(min(Int64(16_384), file.length - file.framePosition))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { break }
        try file.read(into: buffer, frameCount: chunk)
        try resampler.convert(buffer, into: &samples)
    }
    try resampler.finish(into: &samples)
    return samples
}

switch arguments.first {
case "models":
    print("Models in \(store.directory.path):")
    for model in WhisperModel.all {
        let size = ByteCountFormatter.string(fromByteCount: model.downloadSize, countStyle: .file)
        let state = store.isDownloaded(model) ? "downloaded" : "not downloaded (\(size))"
        print("  \(model.id.padding(toLength: 48, withPad: " ", startingAt: 0)) \(state)")
    }

case "download":
    let model = model(named: arguments.dropFirst().first)
    if store.isDownloaded(model) {
        print("\(model.id) is already downloaded.")
        exit(0)
    }
    let size = ByteCountFormatter.string(fromByteCount: model.downloadSize, countStyle: .file)
    print("Downloading \(model.id) (\(size)) into \(store.directory.path)…")
    let started = ContinuousClock.now
    let lastPrinted = LockedPercent()
    do {
        try await store.download(model) { fraction in
            let percent = Int(fraction * 100)
            if lastPrinted.advance(to: percent) { print("  \(percent)%") }
        }
    } catch {
        fail("Download failed: \(error.localizedDescription)")
    }
    print("Done in \(seconds(.now - started)) s.")

case "run":
    arguments.removeFirst()
    var runs = 3
    if let index = arguments.firstIndex(of: "--runs") {
        guard index + 1 < arguments.count, let value = Int(arguments[index + 1]), value > 0 else { fail(usage) }
        runs = value
        arguments.removeSubrange(index...(index + 1))
    }
    let model = model(named: arguments.first)
    let files = arguments.dropFirst().map { URL(fileURLWithPath: $0) }
    guard !files.isEmpty else { fail(usage) }
    guard store.isDownloaded(model) else { fail("\(model.id) isn't downloaded. Run: dictate-bench download \(model.id)") }

    let transcriber = WhisperKitTranscriber(model: model, store: store)
    print("Model \(model.id)")
    do {
        let loadTime = try await transcriber.load()
        print("  load: \(seconds(loadTime)) s")
    } catch {
        fail("Load failed: \(error.localizedDescription)")
    }

    var totalErrors = 0.0
    var totalWords = 0
    for file in files {
        let samples: [Float]
        do {
            samples = try loadAudio(file)
        } catch {
            fail("Couldn't read \(file.path): \(error.localizedDescription)")
        }
        let referenceURL = file.deletingPathExtension().appendingPathExtension("txt")
        let reference = try? String(contentsOf: referenceURL, encoding: .utf8)

        print("\n  \(file.lastPathComponent): \(seconds(AudioFormat.duration(ofSampleCount: samples.count))) s of audio")
        var times: [Duration] = []
        var last: Transcription?
        for _ in 0..<runs {
            do {
                let result = try await transcriber.transcribe(samples)
                times.append(result.processingDuration)
                last = result
            } catch {
                fail("Transcription failed: \(error.localizedDescription)")
            }
        }
        guard let last else { continue }
        let warm = times.dropFirst().min() ?? times[0]
        print("    first run: \(seconds(times[0])) s · best of the rest: \(seconds(warm)) s · \(String(format: "%.2f", warm / last.audioDuration))× real time")
        print("    text: \(last.text)")
        if let reference {
            let wer = WordErrorRate.compute(reference: reference, hypothesis: last.text)
            let words = reference.split(whereSeparator: \.isWhitespace).count
            totalErrors += wer * Double(words)
            totalWords += words
            print("    WER: \(String(format: "%.1f", wer * 100))% of \(words) words")
        }
    }
    if totalWords > 0 {
        print("\n  overall WER: \(String(format: "%.1f", totalErrors / Double(totalWords) * 100))% of \(totalWords) words")
    }

default:
    fail(usage)
}

/// Prints download progress once per 10%, from WhisperKit's callback thread.
final class LockedPercent: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -10

    func advance(to percent: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard percent >= last + 10 else { return false }
        last = percent
        return true
    }
}
