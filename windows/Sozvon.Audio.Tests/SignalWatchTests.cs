using Sozvon.Audio.Session;
using Sozvon.Audio.Tracks;
using Xunit;

namespace Sozvon.Audio.Tests;

public class SignalWatchTests
{
    [Fact]
    public void MicrophoneIsCapturedAgainAtTwoMinutesAndToldHalfAMinuteLater()
    {
        var watch = new SilenceWatch();

        Assert.Equal(SilenceWatch.Action.None, watch.Update(119));
        Assert.Equal(SilenceWatch.Action.Restart, watch.Update(120));
        Assert.Equal(SilenceWatch.Action.None, watch.Update(149));
        Assert.False(watch.Warns(149));
        Assert.Equal(SilenceWatch.Action.Tell, watch.Update(150));
        Assert.True(watch.Warns(150));
        Assert.Equal(SilenceWatch.Action.None, watch.Update(151));
    }

    [Fact]
    public void AnOtherSideThatWasHeardGetsFiveMinutes()
    {
        var watch = new SilenceWatch(patient: true);
        for (int i = 0; i < SilenceWatch.HeardAfterUpdates; i++) watch.Update(0, sound: true);

        Assert.Equal(SilenceWatch.Action.Restart, watch.Update(120));
        Assert.Equal(SilenceWatch.Action.None, watch.Update(299));
        Assert.Equal(SilenceWatch.Action.Tell, watch.Update(300));
    }

    [Fact]
    public void SoundStartsTheWatchOver()
    {
        var watch = new SilenceWatch();
        watch.Update(120);
        watch.Update(0);

        Assert.Equal(SilenceWatch.Action.Restart, watch.Update(120));
    }

    [Fact]
    public void AQuietMicrophoneIsToldOnceAfterThreeMinutes()
    {
        var watch = new QuietMicWatch();

        Assert.False(watch.Update(0.1f, 179));
        Assert.True(watch.Update(0.1f, 180));
        Assert.False(watch.Update(0.1f, 181));
    }

    [Fact]
    public void ANormalVoiceIsNeverCalledQuiet()
    {
        var watch = new QuietMicWatch();
        watch.Update(0.5f, 10);

        Assert.False(watch.Update(0.1f, 200));
    }

    [Theory]
    [InlineData(1f, 1f, 1f)]
    [InlineData(0.056234f, 0.5f, 1f)]
    [InlineData(0.003162f, 0f, 0.5f)]
    [InlineData(0.000001f, 0f, 0f)]
    public void ScalesMatchTheMacApp(float rms, float meter, float display)
    {
        Assert.Equal(meter, Levels.Meter(rms), 2);
        Assert.Equal(display, Levels.Display(rms), 2);
    }

    [Fact]
    public void MissingPacketsWarnAfterEightSeconds()
    {
        var watch = new RecordingWatch(0);
        var noPackets = new TrackMeter(0, null);
        var system = new TrackMeter(0.1f, 7.9);

        Assert.Null(watch.Update(0, noPackets, system).Levels.Warning);
        TrackWarning? warning = watch.Update(8, noPackets, system with { LastPacketAt = 8 }).Levels.Warning;

        Assert.Equal(RecordingTrack.Microphone, warning?.Track);
    }

    [Fact]
    public void AStaleTrackShowsNoLevel()
    {
        var watch = new RecordingWatch(0);

        RecorderLevels levels = watch.Update(10, new TrackMeter(0.5f, 8), new TrackMeter(0.5f, 9.9)).Levels;

        Assert.Equal(0f, levels.Microphone);
        Assert.True(levels.System > 0);
    }

    [Fact]
    public void ASilentOtherSideAsksForARecaptureThenAnAlert()
    {
        var watch = new RecordingWatch(0);
        var mic = new TrackMeter(0.1f, 0);

        Assert.False(watch.Update(0, mic, default).RecaptureSystem);
        Assert.True(watch.Update(120, mic with { LastPacketAt = 120 }, default).RecaptureSystem);
        WatchResult told = watch.Update(150, mic with { LastPacketAt = 150 }, default);

        Assert.Equal(RecorderAlertKind.SystemSilent, Assert.Single(told.Alerts).Kind);
        Assert.Equal(RecordingTrack.System, told.Levels.Warning?.Track);
    }

    [Fact]
    public void MarksAreCountedFromTheEarlierTrackAndKeptApart()
    {
        IReadOnlyList<double> marks = CallMarks.Offsets([100.0, 113.24, 115.0, 99.0], 100.0);

        Assert.Equal(new[] { 0.0, 13.2 }, marks);
    }

    [Fact]
    public void NoAudioMeansNoMarks() => Assert.Empty(CallMarks.Offsets([1.0], null));
}
