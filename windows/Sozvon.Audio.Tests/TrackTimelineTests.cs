using Sozvon.Audio.Tracks;
using Xunit;

namespace Sozvon.Audio.Tests;

public class TrackTimelineTests
{
    private const int Rate = 48_000;
    private const int Packet = 480;

    [Fact]
    public void FirstPacketSetsTheOrigin()
    {
        var timeline = new TrackTimeline(Rate);

        Assert.Equal(default, timeline.Place(100.0, Packet, 100.01));

        Assert.Equal(100.0, timeline.Origin);
        Assert.Equal(Packet, timeline.WrittenFrames);
    }

    [Fact]
    public void ContiguousPacketsNeedNothing()
    {
        var timeline = new TrackTimeline(Rate);
        double t = 10.0;
        for (int i = 0; i < 1000; i++, t += Packet / (double)Rate)
        {
            Assert.Equal(default, timeline.Place(t, Packet, t));
        }
        Assert.Equal(1000 * Packet, timeline.WrittenFrames);
    }

    [Fact]
    public void ARealHoleBecomesExactSilence()
    {
        var timeline = new TrackTimeline(Rate);
        timeline.Place(10.0, Packet, 10.0);

        Placement placement = timeline.Place(13.01, Packet, 13.01);

        Assert.Equal(3 * Rate, placement.SilenceFrames);
        Assert.Equal(Packet + 3 * Rate + Packet, timeline.WrittenFrames);
    }

    [Fact]
    public void AnOverlapFromTheNewDeviceIsCut()
    {
        var timeline = new TrackTimeline(Rate);
        timeline.Place(10.0, Rate, 10.0);

        Placement placement = timeline.Place(10.9, Rate, 11.0);

        Assert.Equal((int)(0.1 * Rate), placement.SkipFrames);
        Assert.Equal(Rate + Rate - (int)(0.1 * Rate), timeline.WrittenFrames);
    }

    [Fact]
    public void APacketEntirelyInThePastWritesNothing()
    {
        var timeline = new TrackTimeline(Rate);
        timeline.Place(10.0, Rate, 10.0);

        Placement placement = timeline.Place(10.0, Packet, 11.0);

        Assert.Equal(Packet, placement.SkipFrames);
        Assert.Equal(Rate, timeline.WrittenFrames);
    }

    [Theory]
    [InlineData(1.0002, 1)]
    [InlineData(0.9998, -1)]
    public void DriftIsCorrectedAFrameAtATimeAndStaysBounded(double clockRatePerDeviceSecond, int expectedSlip)
    {
        var timeline = new TrackTimeline(Rate);
        const int Packets = 180_000;
        var slips = 0;
        for (int i = 0; i < Packets; i++)
        {
            double t = 10.0 + i * (Packet / (double)Rate) * clockRatePerDeviceSecond;
            Placement placement = timeline.Place(t, Packet, t);
            Assert.Equal(0, placement.SilenceFrames);
            Assert.Equal(0, placement.SkipFrames);
            Assert.Contains(placement.Slip, new[] { 0, expectedSlip });
            slips += Math.Abs(placement.Slip);
        }
        double end = 10.0 + Packets * (Packet / (double)Rate) * clockRatePerDeviceSecond;
        double error = Math.Abs(end - timeline.Origin!.Value - timeline.WrittenSeconds);
        Assert.True(error < 0.012, $"error {error}");
        Assert.True(slips > 0);
    }

    [Fact]
    public void JitterInsideTheDeadbandChangesNothing()
    {
        var timeline = new TrackTimeline(Rate);
        var random = new Random(7);
        for (int i = 0; i < 5000; i++)
        {
            double jitter = (random.NextDouble() - 0.5) * 0.008;
            double t = 10.0 + i * (Packet / (double)Rate) + jitter;
            Assert.Equal(default, timeline.Place(t, Packet, t));
        }
    }

    [Fact]
    public void APacketWithoutATimestampIsTreatedAsContiguous()
    {
        var timeline = new TrackTimeline(Rate);
        timeline.Place(double.NaN, Packet, 20.0);

        Assert.Equal(20.0, timeline.Origin);
        Assert.Equal(default, timeline.Place(double.NaN, Packet, 99.0));
        Assert.Equal(2 * Packet, timeline.WrittenFrames);
    }

    [Fact]
    public void FillToExtendsOnlyForward()
    {
        var timeline = new TrackTimeline(Rate);
        Assert.Equal(0, timeline.FillTo(50));
        timeline.SetOrigin(10.0);

        Assert.Equal(Rate, timeline.FillTo(11.0));
        Assert.Equal(0, timeline.FillTo(10.5));
        Assert.Equal(Rate, timeline.WrittenFrames);
    }

    [Fact]
    public void SlipAddsAFrameInTheMiddle()
    {
        float[] samples = [1, 10, 2, 20, 3, 30, 4, 40];

        int frames = FrameSlip.Apply(ref samples, 4, 2, 1);

        Assert.Equal(5, frames);
        Assert.Equal(new float[] { 1, 10, 2, 20, 2.5f, 25, 3, 30, 4, 40 }, samples[..10]);
    }

    [Fact]
    public void SlipRemovesAFrameInTheMiddle()
    {
        float[] samples = [1, 2, 3, 4];

        int frames = FrameSlip.Apply(ref samples, 4, 1, -1);

        Assert.Equal(3, frames);
        Assert.Equal(new float[] { 1, 2, 4 }, samples[..3]);
    }
}
