using Sozvon.Audio.Tracks;

namespace Sozvon.Audio.Session;

/// <summary>
/// Turns the spooled tracks into the final files, for a stop and for a recovery alike. Nothing is deleted until
/// call.json is written, so it can be interrupted at any point and run again.
/// </summary>
internal static class RecordingFinalizer
{
    private const int MicKilobitsPerSecond = 96;
    private const int SystemKilobitsPerSecond = 128;

    /// <exception cref="IOException">A track could not be encoded or put in place; its audio stays in the session.</exception>
    public static async Task<RecordingResult> FinalizeAsync(SessionFiles files, SessionJournal journal, IEnumerable<double> markClockTimes,
        string ffmpegPath, bool microphoneRaw, CancellationToken cancellationToken)
    {
        var encoder = new AacEncoder(ffmpegPath);
        double micSeconds = Seconds(files.MicWav, RecordingFormat.MicChannels);
        SystemTrack system = OtherSide(files, journal);

        await Task.WhenAll(
            PlaceAsync(encoder, [new EncoderInput(files.MicWav, 0)], files.MicEncoding, files.MicFinal, MicKilobitsPerSecond, micSeconds,
                cancellationToken),
            PlaceAsync(encoder, system.Inputs, files.SystemEncoding, files.SystemFinal, SystemKilobitsPerSecond, system.Seconds,
                cancellationToken))
            .ConfigureAwait(false);

        var audio = new AudioTimes(
            micSeconds > 0 ? journal.MicStart ?? journal.SystemStart ?? 0 : null,
            system.Seconds > 0 ? system.Start : null,
            micSeconds,
            system.Seconds);

        double? earliest = new[] { audio.MicStart, audio.SystemStart }.Min();
        IReadOnlyList<double> marks = CallMarks.Offsets(markClockTimes, earliest);
        await CallFileAudio.WriteAsync(files.CallDirectory, journal.StartedAt, audio, marks, cancellationToken).ConfigureAwait(false);

        Directory.Delete(files.Folder, recursive: true);
        return new RecordingResult(audio, marks, microphoneRaw);
    }

    internal readonly record struct SystemTrack(IReadOnlyList<EncoderInput> Inputs, double Start, double Seconds);

    /// <summary>
    /// The other side: the default output's loopback and, when a call played elsewhere too, the second output's, each
    /// placed at its own start. The second output without a known start (a crash before its first save) is left out.
    /// </summary>
    internal static SystemTrack OtherSide(SessionFiles files, SessionJournal journal)
    {
        var parts = new List<(string Wav, double Start, double Seconds)>();
        double mainSeconds = Seconds(files.SystemWav, RecordingFormat.SystemChannels);
        if (mainSeconds > 0) parts.Add((files.SystemWav, journal.SystemStart ?? journal.MicStart ?? 0, mainSeconds));
        double secondSeconds = Seconds(files.SecondOutputWav, RecordingFormat.SystemChannels);
        if (secondSeconds > 0 && journal.SecondOutputStart is double secondStart) parts.Add((files.SecondOutputWav, secondStart, secondSeconds));
        if (parts.Count == 0) return new SystemTrack([], 0, 0);

        double start = parts.Min(p => p.Start);
        double end = parts.Max(p => p.Start + p.Seconds);
        var inputs = parts
            .Select(p => new EncoderInput(p.Wav, (long)Math.Round((p.Start - start) * RecordingFormat.SampleRate)))
            .ToList();
        return new SystemTrack(inputs, start, end - start);
    }

    private static async Task PlaceAsync(AacEncoder encoder, IReadOnlyList<EncoderInput> inputs, string encoding, string final,
        int kilobitsPerSecond, double seconds, CancellationToken cancellationToken)
    {
        if (seconds <= 0 || File.Exists(final)) return;
        await encoder.EncodeAsync(inputs, encoding, kilobitsPerSecond, seconds, cancellationToken).ConfigureAwait(false);
        if (new FileInfo(encoding).Length == 0) throw new IOException($"ffmpeg wrote an empty {Path.GetFileName(final)}");
        File.Move(encoding, final, overwrite: false);
    }

    private static double Seconds(string wav, int channels)
    {
        if (!File.Exists(wav)) return 0;
        long audioBytes = new FileInfo(wav).Length - TrackSpool.HeaderBytes;
        long frames = Math.Max(0, audioBytes) / (channels * RecordingFormat.BytesPerSample);
        return frames / (double)RecordingFormat.SampleRate;
    }
}
