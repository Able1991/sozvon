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
        double systemSeconds = Seconds(files.SystemWav, RecordingFormat.SystemChannels);

        await Task.WhenAll(
            PlaceAsync(encoder, files.MicWav, files.MicEncoding, files.MicFinal, MicKilobitsPerSecond, micSeconds, cancellationToken),
            PlaceAsync(encoder, files.SystemWav, files.SystemEncoding, files.SystemFinal, SystemKilobitsPerSecond, systemSeconds, cancellationToken))
            .ConfigureAwait(false);

        var audio = new AudioTimes(
            micSeconds > 0 ? journal.MicStart ?? journal.SystemStart ?? 0 : null,
            systemSeconds > 0 ? journal.SystemStart ?? journal.MicStart ?? 0 : null,
            micSeconds,
            systemSeconds);

        double? earliest = new[] { audio.MicStart, audio.SystemStart }.Min();
        IReadOnlyList<double> marks = CallMarks.Offsets(markClockTimes, earliest);
        await CallFileAudio.WriteAsync(files.CallDirectory, journal.StartedAt, audio, marks, cancellationToken).ConfigureAwait(false);

        Directory.Delete(files.Folder, recursive: true);
        return new RecordingResult(audio, marks, microphoneRaw);
    }

    private static async Task PlaceAsync(AacEncoder encoder, string wav, string encoding, string final, int kilobitsPerSecond,
        double seconds, CancellationToken cancellationToken)
    {
        if (seconds <= 0 || File.Exists(final)) return;
        await encoder.EncodeAsync(wav, encoding, kilobitsPerSecond, seconds, cancellationToken).ConfigureAwait(false);
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
