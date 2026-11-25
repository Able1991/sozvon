using Sozvon.Audio.Capture;
using Sozvon.Audio.Session;
using Sozvon.Audio.Tracks;
using Xunit;

namespace Sozvon.Audio.Tests;

/// <summary>A call heard on another output (Bluetooth Hands-Free, a call app's own speaker) and a track that can't be written.</summary>
public sealed class SecondOutputTests : IDisposable
{
    private const int Rate = RecordingFormat.SampleRate;

    private readonly string _call = Directory.CreateTempSubdirectory("sozvon second output ").FullName;

    public void Dispose() => Directory.Delete(_call, recursive: true);

    [Fact]
    public void TheHandsFreeDeviceACallPlaysToIsChosen()
    {
        Assert.Equal("hands-free", SecondOutputDevices.Choose("stereo", "hands-free", ["hdmi", "hands-free"]));
    }

    [Fact]
    public void ACallAppsOwnSpeakerIsChosenWhenTheCommunicationsDeviceIsQuiet()
    {
        Assert.Equal("usb", SecondOutputDevices.Choose("speakers", "speakers", ["usb"]));
        Assert.Equal("usb", SecondOutputDevices.Choose("speakers", "hands-free", ["usb"]));
    }

    [Fact]
    public void AnIdleOutputIsNeverOpened()
    {
        // A stream of ours on an idle Hands-Free device could itself put the headset into its call mode.
        Assert.Null(SecondOutputDevices.Choose("stereo", "hands-free", []));
        Assert.Null(SecondOutputDevices.Choose("speakers", "speakers", ["speakers"]));
        Assert.Null(SecondOutputDevices.Choose(null, null, []));
    }

    [Fact]
    public void TheRealOutputsAreScannedWithoutOpeningAny()
    {
        using var devices = new SecondOutputDevices();
        string? target = devices.DefaultDeviceId();
        Assert.NotNull(target);
        Assert.NotEqual(target, DefaultOutput());
    }

    private static string? DefaultOutput()
    {
        using var devices = new WasapiDevices(CaptureKind.Loopback);
        return devices.DefaultDeviceId();
    }

    [Fact]
    public void AFailedTrackIsWarnedAtOnce()
    {
        var watch = new RecordingWatch(100);
        var heard = new TrackMeter(0.1f, 100.0);

        RecorderLevels levels = watch.Update(100.1, heard, heard, micFailedAt: null, systemFailedAt: 100.0).Levels;
        Assert.Equal(new TrackWarning(RecordingTrack.System, 0), levels.Warning);

        levels = watch.Update(105.2, heard with { LastPacketAt = 105.2 }, heard with { LastPacketAt = 105.2 }, 103.0, 100.0).Levels;
        Assert.Equal(new TrackWarning(RecordingTrack.Microphone, 2), levels.Warning);
    }

    [Fact]
    public void TheOtherSideIsTheLouderOfItsTwoOutputs()
    {
        var quiet = new TrackMeter(0.001f, 10.0);
        var loud = new TrackMeter(0.1f, 10.0);
        var stale = new TrackMeter(0.5f, 1.0);

        Assert.Equal(loud, RecordingWatch.Louder(quiet, loud, 10.5));
        Assert.Equal(quiet, RecordingWatch.Louder(quiet, stale, 10.5));
        Assert.Equal(new TrackMeter(0, null), RecordingWatch.Louder(new TrackMeter(0, null), new TrackMeter(0, null), 10.5));
    }

    [Fact]
    public async Task BothOutputsArePlacedOnTheSharedClock()
    {
        var files = new SessionFiles(_call);
        files.Create();
        await WriteAsync(files.SystemWav, seconds: 3, value: 0.1f);
        await WriteAsync(files.SecondOutputWav, seconds: 2, value: 0.2f);
        var journal = new SessionJournal(DateTimeOffset.UtcNow, 100.0, 100.5, [], SecondOutputStart: 102.0);

        RecordingFinalizer.SystemTrack track = RecordingFinalizer.OtherSide(files, journal);

        Assert.Equal(100.5, track.Start);
        Assert.Equal(3.5, track.Seconds, 6);
        Assert.Equal(new[] { new EncoderInput(files.SystemWav, 0), new EncoderInput(files.SecondOutputWav, (long)(1.5 * Rate)) }, track.Inputs);
    }

    [Fact]
    public async Task AnUnusedSecondOutputLeavesTheOtherSideAsItWas()
    {
        var files = new SessionFiles(_call);
        files.Create();
        await WriteAsync(files.SystemWav, seconds: 1, value: 0.1f);
        await WriteAsync(files.SecondOutputWav, seconds: 0, value: 0);

        RecordingFinalizer.SystemTrack track = RecordingFinalizer.OtherSide(files, new SessionJournal(DateTimeOffset.UtcNow, 5.0, 5.0, []));

        Assert.Equal(new[] { new EncoderInput(files.SystemWav, 0) }, track.Inputs);
        Assert.Equal(
            ["-hide_banner", "-nostdin", "-v", "error", "-y", "-i", files.SystemWav,
             "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", "-f", "mp4", "out.m4a"],
            AacEncoder.Arguments(track.Inputs, "out.m4a", 128));
    }

    [Fact]
    public async Task OnlyTheSecondOutputHadSound()
    {
        var files = new SessionFiles(_call);
        files.Create();
        await WriteAsync(files.SecondOutputWav, seconds: 2, value: 0.2f);

        RecordingFinalizer.SystemTrack track = RecordingFinalizer.OtherSide(files, new SessionJournal(DateTimeOffset.UtcNow, 5.0, null, [], 7.0));

        Assert.Equal(7.0, track.Start);
        Assert.Equal(2.0, track.Seconds, 6);
    }

    [Fact]
    public void AJournalFromBeforeTheSecondOutputStillLoads()
    {
        string path = Path.Combine(_call, "session.json");
        File.WriteAllText(path, """{"started_at":"2026-01-02T03:04:05+00:00","mic_start":1.5,"system_start":2.5,"marks":[]}""");

        SessionJournal? loaded = SessionJournal.Load(path);

        Assert.Equal(2.5, loaded!.SystemStart);
        Assert.Null(loaded.SecondOutputStart);
        new SessionJournal(loaded.StartedAt, 1.5, 2.5, [], 4.25).Save(path);
        Assert.Equal(4.25, SessionJournal.Load(path)!.SecondOutputStart);
    }

    [FfmpegFact]
    public async Task TheCallOnHandsFreeIsMixedIntoTheOtherSidesFile()
    {
        var files = new SessionFiles(_call);
        files.Create();
        new SessionJournal(DateTimeOffset.UtcNow, 10.0, 10.0, [], SecondOutputStart: 12.0).Save(files.Journal);
        await WriteAsync(files.MicWav, seconds: 4, value: 0, channels: RecordingFormat.MicChannels);
        await WriteToneAsync(files.SystemWav, seconds: 1);
        await WriteToneAsync(files.SecondOutputWav, seconds: 1);

        RecordingResult result = await RecordingRecovery.RecoverAsync(_call, TestFfmpeg.Path!);

        Assert.Equal(10.0, result.Audio.SystemStart);
        Assert.Equal(3.0, result.Audio.SystemSeconds, 3);
        float[] decoded = TestFfmpeg.DecodeMono(files.SystemFinal);
        Assert.True(Loud(decoded, 0.2, 0.8));
        Assert.False(Loud(decoded, 1.3, 1.8));
        Assert.True(Loud(decoded, 2.2, 2.8));
        Assert.False(File.Exists(files.SecondOutputWav));
    }

    private static bool Loud(float[] samples, double from, double to)
    {
        double sum = 0;
        int a = (int)(from * Rate), b = (int)(to * Rate);
        for (int i = a; i < b; i++) sum += samples[i] * samples[i];
        return Math.Sqrt(sum / (b - a)) > 0.05;
    }

    private static async Task WriteAsync(string path, int seconds, float value, int channels = RecordingFormat.SystemChannels)
    {
        var spool = new TrackSpool(path, Rate, channels, _ => { });
        var samples = new float[seconds * Rate * channels];
        Array.Fill(samples, value);
        spool.Write(samples);
        await spool.CloseAsync();
    }

    private static async Task WriteToneAsync(string path, int seconds)
    {
        var spool = new TrackSpool(path, Rate, RecordingFormat.SystemChannels, _ => { });
        var samples = new float[seconds * Rate * RecordingFormat.SystemChannels];
        for (int i = 0; i < samples.Length; i++) samples[i] = 0.3f * MathF.Sin(i / 2 * 0.06f);
        spool.Write(samples);
        await spool.CloseAsync();
    }
}
