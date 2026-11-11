import Accelerate

/// Converts between linear amplitude (1.0 = full scale) and dBFS.
public enum Decibels {
    /// Anything quieter reads as silence.
    public static let floor: Float = -120

    public static func fromAmplitude(_ amplitude: Float) -> Float {
        amplitude > 0 ? max(floor, 20 * log10(amplitude)) : floor
    }

    /// 0 at −60 dBFS or below, 1 at full scale: a scale for level meters.
    public static func meterValue(forAmplitude amplitude: Float) -> Float {
        let db = fromAmplitude(amplitude)
        return min(1, max(0, (db + 60) / 60))
    }
}

/// Loudness of a recording, for the silence gate and for spotting clipping.
public struct LevelStats: Sendable, Equatable {
    /// Window used for `loudestWindowRMS`.
    public static let windowDuration: Duration = .milliseconds(30)
    /// Samples at or above this magnitude count as clipped.
    public static let clipThreshold: Float = 0.999

    /// Largest sample magnitude (linear).
    public var peak: Float
    /// RMS over the whole recording (linear). Pauses pull it down.
    public var rms: Float
    /// RMS of the loudest 30 ms window (linear). Speech lifts it even in a mostly quiet clip.
    public var loudestWindowRMS: Float
    public var clippedSampleCount: Int

    public var peakDBFS: Float { Decibels.fromAmplitude(peak) }
    public var rmsDBFS: Float { Decibels.fromAmplitude(rms) }
    public var loudestWindowDBFS: Float { Decibels.fromAmplitude(loudestWindowRMS) }

    public static let silence = LevelStats(peak: 0, rms: 0, loudestWindowRMS: 0, clippedSampleCount: 0)

    public init(peak: Float, rms: Float, loudestWindowRMS: Float, clippedSampleCount: Int) {
        self.peak = peak
        self.rms = rms
        self.loudestWindowRMS = loudestWindowRMS
        self.clippedSampleCount = clippedSampleCount
    }

    public init(samples: [Float], sampleRate: Double = AudioFormat.sampleRate) {
        guard !samples.isEmpty else {
            self = .silence
            return
        }
        peak = vDSP.maximumMagnitude(samples)
        rms = vDSP.rootMeanSquare(samples)
        clippedSampleCount = samples.count { abs($0) >= Self.clipThreshold }

        let window = max(1, Int(sampleRate * (Self.windowDuration / .seconds(1))))
        var loudest: Float = 0
        samples.withUnsafeBufferPointer { all in
            var start = 0
            while start < all.count {
                let slice = UnsafeBufferPointer(rebasing: all[start..<min(start + window, all.count)])
                loudest = max(loudest, vDSP.rootMeanSquare(slice))
                start += window
            }
        }
        loudestWindowRMS = loudest
    }
}

/// Decides whether a recording is worth transcribing. Whisper tends to invent text
/// ("Thank you.") for silence and very short clips (BUILD_PLAN.md §5, gotcha 9).
public struct SpeechGate: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        case speech
        case tooShort
        case tooQuiet
    }

    /// Shorter presses count as accidental.
    public var minimumDuration: Duration
    /// The loudest 30 ms window must reach this. A starting guess: tune it against real
    /// recordings (the Step 4 menu shows each recording's level).
    public var minimumLoudestWindowDBFS: Float

    public init(minimumDuration: Duration = .milliseconds(250), minimumLoudestWindowDBFS: Float = -45) {
        self.minimumDuration = minimumDuration
        self.minimumLoudestWindowDBFS = minimumLoudestWindowDBFS
    }

    public func verdict(duration: Duration, levels: LevelStats) -> Verdict {
        if duration < minimumDuration { return .tooShort }
        if levels.loudestWindowDBFS < minimumLoudestWindowDBFS { return .tooQuiet }
        return .speech
    }
}
