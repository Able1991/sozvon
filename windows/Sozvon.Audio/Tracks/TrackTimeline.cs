namespace Sozvon.Audio.Tracks;

/// <param name="SilenceFrames">Zero frames to write before the packet.</param>
/// <param name="SkipFrames">Frames at the packet's head already covered by what is written.</param>
/// <param name="Slip">+1 to add one frame to the packet, -1 to remove one, 0 to keep it.</param>
internal readonly record struct Placement(long SilenceFrames, int SkipFrames, int Slip);

/// <summary>
/// Keeps a track on the shared clock. A real hole (nothing playing, a lost device) becomes exact silence and a
/// repeated stretch is cut. The slow drift of the device clock is taken out one frame at a time, so it never grows
/// into an audible gap in the middle of speech and the two tracks stay aligned for the echo filter.
/// </summary>
internal sealed class TrackTimeline(int sampleRate)
{
    /// <summary>A difference from the clock this large is a real hole or overlap, not packet jitter.</summary>
    public const double HoleSeconds = 0.05;

    private const double DriftDeadbandSeconds = 0.01;

    private readonly long _holeFrames = (long)(HoleSeconds * sampleRate);
    private readonly long _deadbandFrames = (long)(DriftDeadbandSeconds * sampleRate);

    public double? Origin { get; private set; }

    public long WrittenFrames { get; private set; }

    public double WrittenSeconds => WrittenFrames / (double)sampleRate;

    public void SetOrigin(double seconds) => Origin ??= seconds;

    /// <param name="startSeconds">The packet's clock time, or NaN when the device gave none.</param>
    /// <param name="arrivalSeconds">Used as the origin when the first packet has no time of its own.</param>
    public Placement Place(double startSeconds, int frames, double arrivalSeconds)
    {
        if (double.IsNaN(startSeconds))
        {
            Origin ??= arrivalSeconds;
            WrittenFrames += frames;
            return default;
        }
        if (Origin is null)
        {
            Origin = startSeconds;
            WrittenFrames = frames;
            return default;
        }

        long behind = FrameAt(startSeconds) - WrittenFrames;
        if (behind >= _holeFrames)
        {
            WrittenFrames += behind + frames;
            return new Placement(behind, 0, 0);
        }
        if (-behind >= _holeFrames)
        {
            int skip = (int)Math.Min(-behind, frames);
            WrittenFrames += frames - skip;
            return new Placement(0, skip, 0);
        }

        int slip = frames < 2 || Math.Abs(behind) < _deadbandFrames ? 0 : Math.Sign(behind);
        WrittenFrames += frames + slip;
        return new Placement(0, 0, slip);
    }

    /// <summary>Extends the track with silence up to a clock time and returns how many frames to write.</summary>
    public long FillTo(double seconds)
    {
        if (Origin is null) return 0;
        long missing = FrameAt(seconds) - WrittenFrames;
        if (missing <= 0) return 0;
        WrittenFrames += missing;
        return missing;
    }

    private long FrameAt(double seconds) => (long)Math.Round((seconds - Origin!.Value) * sampleRate);
}

/// <summary>Adds or removes one frame in the middle of a packet.</summary>
internal static class FrameSlip
{
    /// <returns>The new number of frames.</returns>
    public static int Apply(ref float[] samples, int frames, int channels, int slip)
    {
        if (slip == 0) return frames;
        int middle = frames / 2 * channels;
        int total = frames * channels;
        if (slip < 0)
        {
            Array.Copy(samples, middle + channels, samples, middle, total - middle - channels);
            return frames - 1;
        }

        if (samples.Length < total + channels) Array.Resize(ref samples, total + channels);
        Array.Copy(samples, middle, samples, middle + channels, total - middle);
        for (int c = 0; c < channels; c++)
        {
            float before = samples[middle - channels + c];
            float after = samples[middle + channels + c];
            samples[middle + c] = (before + after) / 2;
        }
        return frames + 1;
    }
}
