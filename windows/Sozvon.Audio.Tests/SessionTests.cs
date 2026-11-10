using System.Text.Json.Nodes;
using Sozvon.Audio.Session;
using Sozvon.Audio.Tracks;
using Xunit;

namespace Sozvon.Audio.Tests;

public sealed class SessionTests : IDisposable
{
    private const int Rate = RecordingFormat.SampleRate;

    private readonly string _call = Directory.CreateTempSubdirectory("sozvon call кириллица ").FullName;

    public void Dispose() => Directory.Delete(_call, recursive: true);

    [Fact]
    public async Task CallJsonKeepsOtherFieldsAndGainsTheFacts()
    {
        string path = Path.Combine(_call, "call.json");
        File.WriteAllText(path, """{"id":"x","topic":"запуск","engine":{"v":1}}""");

        var audio = new AudioTimes(3764879.93, 3764879.64, 1755.6, 1755.8);
        await CallFileAudio.WriteAsync(_call, new DateTimeOffset(2026, 11, 4, 9, 0, 0, TimeSpan.Zero), audio, [754.2], default);

        JsonNode call = JsonNode.Parse(File.ReadAllText(path))!;
        Assert.Equal("x", (string?)call["id"]);
        Assert.Equal("запуск", (string?)call["topic"]);
        Assert.Equal(1, (int?)call["engine"]!["v"]);
        Assert.Equal(1, (int?)call["schema"]);
        Assert.Equal("recorded", (string?)call["status"]);
        Assert.Equal("2026-11-04T09:00:00Z", (string?)call["created_at"]);
        Assert.Equal(3764879.93, (double?)call["audio"]!["mic_start"]);
        Assert.Equal(1755.8, (double?)call["audio"]!["system_seconds"]);
        Assert.Equal(754.2, (double?)call["marks"]![0]);
        Assert.Contains("запуск", File.ReadAllText(path));
    }

    [Fact]
    public async Task ATrackWithoutAudioHasNoKeysAndNoMarksMeansNoField()
    {
        await CallFileAudio.WriteAsync(_call, DateTimeOffset.UtcNow, new AudioTimes(null, 5.0, 0, 3.0), [], default);

        JsonNode call = JsonNode.Parse(File.ReadAllText(Path.Combine(_call, "call.json")))!;
        Assert.Null(call["audio"]!["mic_start"]);
        Assert.Null(call["audio"]!["mic_seconds"]);
        Assert.Equal(5.0, (double?)call["audio"]!["system_start"]);
        Assert.Null(call["marks"]);
    }

    [Fact]
    public async Task ACorruptCallJsonIsNeverReplaced()
    {
        string path = Path.Combine(_call, "call.json");
        File.WriteAllText(path, "{broken");

        await Assert.ThrowsAsync<InvalidDataException>(() =>
            CallFileAudio.WriteAsync(_call, DateTimeOffset.UtcNow, new AudioTimes(1, 1, 1, 1), [], default));

        Assert.Equal("{broken", File.ReadAllText(path));
    }

    [Fact]
    public async Task TheWriterWaitsForTheEnginesLock()
    {
        string lockPath = Path.Combine(_call, "call.json.lock");
        var holder = new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.ReadWrite | FileShare.Delete);
        holder.Lock(0, 1);

        Task write = CallFileAudio.WriteAsync(_call, DateTimeOffset.UtcNow, new AudioTimes(1, 1, 1, 1), [], default);
        await Task.Delay(300);
        Assert.False(write.IsCompleted);
        Assert.False(File.Exists(Path.Combine(_call, "call.json")));

        await holder.DisposeAsync();
        await write;
        Assert.True(File.Exists(Path.Combine(_call, "call.json")));
    }

    [Fact]
    public void JournalRoundTrips()
    {
        string path = Path.Combine(_call, "session.json");
        var journal = new SessionJournal(new DateTimeOffset(2026, 1, 2, 3, 4, 5, TimeSpan.Zero), 10.5, null, [11.0, 20.0]);

        journal.Save(path);
        SessionJournal? loaded = SessionJournal.Load(path);

        Assert.Equal(journal.StartedAt, loaded!.StartedAt);
        Assert.Equal(10.5, loaded.MicStart);
        Assert.Null(loaded.SystemStart);
        Assert.Equal(new[] { 11.0, 20.0 }, loaded.Marks);
    }

    [Fact]
    public void ABrokenJournalLoadsAsNothing()
    {
        string path = Path.Combine(_call, "session.json");
        File.WriteAllText(path, "{");

        Assert.Null(SessionJournal.Load(path));
    }

    [FfmpegFact]
    public async Task SilentCaptureRecordsSilenceWithoutTouchingTheDevices()
    {
        var recorder = new WasapiRecorder(new RecorderOptions(TestFfmpeg.Path!, null) { SilentCapture = true });
        TrackWarning? warning = null;
        recorder.LevelsChanged += (_, l) => warning ??= l.Warning;

        await recorder.StartAsync(_call);
        await Task.Delay(TimeSpan.FromSeconds(9));
        RecordingResult result = await recorder.StopAsync();

        Assert.InRange(result.Audio.MicSeconds, 8.5, 9.5);
        Assert.InRange(result.Audio.SystemSeconds, 8.5, 9.5);
        Assert.All(TestFfmpeg.DecodeMono(Path.Combine(_call, "mic.m4a")), s => Assert.Equal(0f, s));
        Assert.Equal(RecordingTrack.Microphone, warning?.Track);
    }

    [FfmpegFact]
    public async Task TheStreamingWavDecodesToTheEndOfTheFile()
    {
        string wav = Path.Combine(_call, "t.wav");
        var spool = new TrackSpool(wav, Rate, 1, ex => throw ex);
        spool.Write(new float[Rate / 2]);
        spool.WriteSilence(Rate / 2);
        await spool.CloseAsync();

        Assert.Equal(Rate, TestFfmpeg.DecodeMono(wav).Length);
    }

    [FfmpegFact]
    public async Task EncodingKeepsAClickWhereItWas()
    {
        const int ClickAt = 2 * Rate;
        string wav = Path.Combine(_call, "t.wav");
        var spool = new TrackSpool(wav, Rate, 1, ex => throw ex);
        var samples = new float[3 * Rate];
        for (int i = 0; i < 480; i++) samples[ClickAt + i] = 0.8f * MathF.Sin(i * 0.3f);
        spool.Write(samples);
        await spool.CloseAsync();

        string m4a = Path.Combine(_call, "t.m4a");
        await new AacEncoder(TestFfmpeg.Path!).EncodeAsync(wav, m4a, 96, 3, default);

        float[] decoded = TestFfmpeg.DecodeMono(m4a);
        int first = Array.FindIndex(decoded, s => Math.Abs(s) > 0.1f);
        Assert.InRange(first, ClickAt - 48, ClickAt + 48);
        Assert.InRange(decoded.Length, 3 * Rate - 48, 3 * Rate + 1100);
    }

    [FfmpegFact]
    public async Task AnInterruptedRecordingIsRecovered()
    {
        var files = new SessionFiles(_call);
        files.Create();
        new SessionJournal(DateTimeOffset.UtcNow, 100.0, 99.5, [110.0]).Save(files.Journal);
        await WriteToneAsync(files.MicWav, RecordingFormat.MicChannels, 2);
        await WriteToneAsync(files.SystemWav, RecordingFormat.SystemChannels, 3);
        await using (var torn = new FileStream(files.MicWav, FileMode.Append)) await torn.WriteAsync(new byte[] { 1, 2 });

        string root = Path.GetDirectoryName(_call)!;
        Assert.Contains(_call, RecordingRecovery.FindInterrupted(root));
        RecordingResult result = await RecordingRecovery.RecoverAsync(_call, TestFfmpeg.Path!);

        Assert.Equal(2.0, result.Audio.MicSeconds, 3);
        Assert.Equal(3.0, result.Audio.SystemSeconds, 3);
        Assert.Equal(new[] { 10.5 }, result.Marks);
        Assert.False(Directory.Exists(files.Folder));
        Assert.InRange(TestFfmpeg.DecodeMono(files.MicFinal).Length, 2 * Rate - 48, 2 * Rate + 1100);
        JsonNode call = JsonNode.Parse(File.ReadAllText(Path.Combine(_call, "call.json")))!;
        Assert.Equal(99.5, (double?)call["audio"]!["system_start"]);
    }

    [FfmpegFact]
    public async Task ASecondRecoveryAfterAFailureFinishesTheJob()
    {
        var files = new SessionFiles(_call);
        files.Create();
        new SessionJournal(DateTimeOffset.UtcNow, 1.0, 1.0, []).Save(files.Journal);
        await WriteToneAsync(files.MicWav, RecordingFormat.MicChannels, 1);
        await WriteToneAsync(files.SystemWav, RecordingFormat.SystemChannels, 1);

        await Assert.ThrowsAsync<IOException>(() => RecordingRecovery.RecoverAsync(_call, @"C:\nowhere\ffmpeg.exe"));
        Assert.True(File.Exists(files.MicWav));
        Assert.False(File.Exists(files.MicFinal));

        await RecordingRecovery.RecoverAsync(_call, TestFfmpeg.Path!);
        Assert.True(File.Exists(files.MicFinal));
        Assert.True(File.Exists(files.SystemFinal));
    }

    [Fact]
    public async Task ARecordingInProgressIsNotOfferedForRecovery()
    {
        var files = new SessionFiles(_call);
        files.Create();
        var spool = new TrackSpool(files.MicWav, Rate, 1, ex => throw ex);

        Assert.DoesNotContain(_call, RecordingRecovery.FindInterrupted(Path.GetDirectoryName(_call)!));

        await spool.CloseAsync();
        Directory.Delete(files.Folder, recursive: true);
    }

    private static async Task WriteToneAsync(string path, int channels, int seconds)
    {
        var spool = new TrackSpool(path, Rate, channels, ex => throw ex);
        var samples = new float[seconds * Rate * channels];
        for (int i = 0; i < samples.Length; i++) samples[i] = 0.2f * MathF.Sin(i * 0.05f);
        spool.Write(samples);
        await spool.CloseAsync();
    }
}
