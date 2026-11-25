namespace Sozvon.Core.Calls;

/// <summary>
/// The waveform of a whole call for the trim panel, as on the Mac (Waveform.swift): the loudest sample in each of a
/// fixed number of bins, normalized to the loudest bin. The app decodes the tracks at a low rate and feeds them here at
/// their offsets, a chunk at a time, so a long call never sits in memory as samples.
/// </summary>
public sealed class WaveformEnvelope
{
    private readonly float[] _raw;
    private readonly double _scale;

    public WaveformEnvelope(int bins, double duration)
    {
        Bins = Math.Max(0, bins);
        Duration = duration;
        _raw = new float[Bins];
        _scale = duration > 0 ? Bins / duration : 0;
    }

    public int Bins { get; }
    public double Duration { get; }

    /// <summary>Samples at <paramref name="rate"/> per second from <paramref name="start"/> seconds on the call's timeline; those outside the call are left out.</summary>
    public void Add(ReadOnlySpan<float> samples, double start, double rate)
    {
        if (Bins == 0 || Duration <= 0 || rate <= 0) return;
        for (var i = 0; i < samples.Length; i++)
        {
            var t = start + i / rate;
            if (t < 0 || t >= Duration) continue;
            var bin = Math.Min(Bins - 1, (int)(t * _scale));
            var v = Math.Abs(samples[i]);
            if (v > _raw[bin]) _raw[bin] = v;
        }
    }

    /// <summary>Normalized to the loudest bin; all zeros when nothing was heard.</summary>
    public float[] Peaks()
    {
        var top = _raw.Length == 0 ? 0 : _raw.Max();
        return top > 0 ? _raw.Select(v => v / top).ToArray() : (float[])_raw.Clone();
    }

    /// <summary>The peaks of samples that are the whole call, one sample per time unit.</summary>
    public static float[] Peaks(ReadOnlySpan<float> samples, int bins)
    {
        var e = new WaveformEnvelope(bins, samples.Length);
        e.Add(samples, 0, 1);
        return e.Peaks();
    }
}
