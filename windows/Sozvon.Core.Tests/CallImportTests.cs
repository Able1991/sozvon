using Sozvon.Core.Calls;

namespace Sozvon.Core.Tests;

/// <summary>Importing a recording: which files, which date, and a real conversion with the engine's ffmpeg.</summary>
public class CallImportTests : TempFolders
{
    private static readonly DateTimeOffset Now = new(2026, 11, 10, 12, 0, 0, TimeSpan.Zero);

    private static string Ffmpeg => Path.Combine(RealEngine.Install, ".venv", "Scripts", "ffmpeg.exe");

    [Fact]
    public void AcceptsAudioAndVideoByExtension()
    {
        Assert.True(CallImport.IsSupported(@"C:\a\Звонок.M4A"));
        Assert.True(CallImport.IsSupported("meeting.webm"));
        Assert.False(CallImport.IsSupported("notes.txt"));
        Assert.False(CallImport.IsSupported("no-extension"));
    }

    [Fact]
    public void ParsesTheDatesRecordersWrite()
    {
        Assert.Equal(new DateTimeOffset(2026, 11, 4, 15, 1, 2, TimeSpan.Zero), CallImport.ParseDate("2026-11-04T15:01:02Z"));
        Assert.Equal(new DateTimeOffset(2026, 11, 4, 15, 1, 2, TimeSpan.Zero), CallImport.ParseDate("2026-11-04T15:01:02.000000Z"));
        Assert.Equal(new DateTimeOffset(2026, 11, 4, 12, 1, 2, TimeSpan.Zero), CallImport.ParseDate("2026-11-04T15:01:02+0300"));
        Assert.Equal(new DateTimeOffset(2026, 11, 4, 0, 0, 0, TimeSpan.Zero), CallImport.ParseDate("2026-11-04"));
        Assert.Null(CallImport.ParseDate("yesterday"));
    }

    [Fact]
    public void ImplausibleDatesAreIgnored()
    {
        Assert.Null(CallImport.Plausible(new DateTimeOffset(1904, 1, 1, 0, 0, 0, TimeSpan.Zero), Now));
        Assert.Null(CallImport.Plausible(new DateTimeOffset(1970, 1, 1, 0, 0, 0, TimeSpan.Zero), Now));
        Assert.Null(CallImport.Plausible(Now.AddDays(3), Now));
        Assert.Equal(Now.AddDays(-1), CallImport.Plausible(Now.AddDays(-1), Now));
    }

    [Fact]
    public void ReadsLengthAndCreationDateFromFfmpeg()
    {
        const string output = """
            Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'call.m4a':
              Metadata:
                creation_time   : 1970-01-01T00:00:00.000000Z
                creation_time   : 2026-11-04T15:01:02.000000Z
              Duration: 01:02:03.50, start: 0.000000, bitrate: 96 kb/s
            """;
        var (seconds, recorded) = CallImport.Probe(output, Now);
        Assert.Equal(3723.5, seconds);
        Assert.Equal(new DateTimeOffset(2026, 11, 4, 15, 1, 2, TimeSpan.Zero), recorded);
    }

    [Fact]
    public async Task ImportsAWavAsTheSystemTrack()
    {
        if (!File.Exists(Ffmpeg)) Assert.Skip($"no ffmpeg at {Ffmpeg}");
        var wav = Path.Combine(Root, "запись.wav");
        WriteSilence(wav, seconds: 3);
        File.SetCreationTimeUtc(wav, new DateTime(2026, 11, 4, 12, 1, 0, DateTimeKind.Utc));
        var reports = new List<double>();
        var dir = await CallImport.ImportAsync(wav, Calls, Ffmpeg, new Progress<double>(reports.Add), TestContext.Current.CancellationToken);
        Assert.Equal(CallFolder.BaseId(new DateTimeOffset(2026, 11, 4, 12, 1, 0, TimeSpan.Zero)), Path.GetFileName(dir));
        Assert.True(new FileInfo(Path.Combine(dir, "system.m4a")).Length > 1024);
        Assert.Empty(Directory.GetFiles(dir, CallImport.TempPrefix + "*"));
        var call = Json(dir);
        Assert.Equal("recorded", call["status"]!.GetValue<string>());
        Assert.Equal(3, call["audio"]!["system_seconds"]!.GetValue<double>(), 1);
        Assert.Equal(0, call["audio"]!["system_start"]!.GetValue<double>());
    }

    [Fact]
    public async Task AFileWithoutAudioLeavesNothingBehind()
    {
        if (!File.Exists(Ffmpeg)) Assert.Skip($"no ffmpeg at {Ffmpeg}");
        var text = Path.Combine(Root, "not-audio.mp3");
        WriteText(text, "this is not audio");
        await Assert.ThrowsAnyAsync<IOException>(() => CallImport.ImportAsync(text, Calls, Ffmpeg, cancellationToken: TestContext.Current.CancellationToken));
        Assert.Empty(Directory.GetDirectories(Calls));
    }

    /// <summary>16-bit mono PCM, 16 kHz, silence.</summary>
    private static void WriteSilence(string path, int seconds)
    {
        const int rate = 16000;
        var data = rate * 2 * seconds;
        using var writer = new BinaryWriter(File.Create(path));
        writer.Write("RIFF"u8);
        writer.Write(36 + data);
        writer.Write("WAVEfmt "u8);
        writer.Write(16);
        writer.Write((short)1);
        writer.Write((short)1);
        writer.Write(rate);
        writer.Write(rate * 2);
        writer.Write((short)2);
        writer.Write((short)16);
        writer.Write("data"u8);
        writer.Write(data);
        writer.Write(new byte[data]);
    }
}
