namespace WisprFaux.Core.Audio;

public static class Decibels
{
    /// <summary>Anything quieter reads as silence.</summary>
    public const float Floor = -120;

    public static float FromAmplitude(float amplitude) =>
        amplitude > 0 ? Math.Max(Floor, 20 * MathF.Log10(amplitude)) : Floor;

    /// <summary>0 at −60 dBFS or below, 1 at full scale: a scale for level meters.</summary>
    public static float MeterValue(float amplitude) => Math.Clamp((FromAmplitude(amplitude) + 60) / 60, 0, 1);
}

/// <summary>Loudness of a recording, for the silence gate.</summary>
public readonly record struct LevelStats(float Peak, float Rms, float LoudestWindowRms)
{
    public const int SampleRate = 16_000;
    /// <summary>Window used for <see cref="LoudestWindowRms"/>: 30 ms.</summary>
    public const int WindowSamples = SampleRate * 30 / 1000;

    public float LoudestWindowDbfs => Decibels.FromAmplitude(LoudestWindowRms);
    public float PeakDbfs => Decibels.FromAmplitude(Peak);

    public static LevelStats Of(ReadOnlySpan<float> samples)
    {
        if (samples.IsEmpty) return default;
        float peak = 0;
        double sumSquares = 0, windowSum = 0, loudest = 0;
        var inWindow = 0;
        foreach (var s in samples)
        {
            var a = Math.Abs(s);
            if (a > peak) peak = a;
            var sq = (double)s * s;
            sumSquares += sq;
            windowSum += sq;
            if (++inWindow == WindowSamples)
            {
                loudest = Math.Max(loudest, Math.Sqrt(windowSum / inWindow));
                windowSum = 0;
                inWindow = 0;
            }
        }
        if (inWindow > 0) loudest = Math.Max(loudest, Math.Sqrt(windowSum / inWindow));
        return new LevelStats(peak, (float)Math.Sqrt(sumSquares / samples.Length), (float)loudest);
    }
}

public enum GateVerdict { Speech, TooShort, TooQuiet }

/// <summary>
/// Decides whether a recording is worth transcribing. Whisper tends to invent text ("Thank
/// you.") for silence and very short clips.
/// </summary>
public sealed record SpeechGate(TimeSpan MinimumDuration, float MinimumLoudestWindowDbfs)
{
    public static readonly SpeechGate Default = new(TimeSpan.FromMilliseconds(250), -45);

    public GateVerdict Verdict(TimeSpan duration, LevelStats levels)
    {
        if (duration < MinimumDuration) return GateVerdict.TooShort;
        if (levels.LoudestWindowDbfs < MinimumLoudestWindowDbfs) return GateVerdict.TooQuiet;
        return GateVerdict.Speech;
    }
}
