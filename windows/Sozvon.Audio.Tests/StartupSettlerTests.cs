using Sozvon.Audio.Tracks;
using Xunit;

namespace Sozvon.Audio.Tests;

public class StartupSettlerTests
{
    private const int Rate = 48_000;
    private const int Packet = 480;

    [Fact]
    public void EvenPacketsAreAcceptedAfterThreeContiguousOnes()
    {
        var settler = new StartupSettler(Rate);

        Assert.False(settler.Accept(10.00, Packet));
        Assert.False(settler.Accept(10.01, Packet));
        Assert.False(settler.Accept(10.02, Packet));
        Assert.True(settler.Accept(10.03, Packet));
        Assert.True(settler.Accept(10.04, Packet));
    }

    [Fact]
    public void BunchedStampsRestartTheCount()
    {
        var settler = new StartupSettler(Rate);

        Assert.False(settler.Accept(10.000, Packet));
        Assert.False(settler.Accept(10.047, Packet));
        Assert.False(settler.Accept(10.079, Packet));
        Assert.False(settler.Accept(10.126, Packet));
        Assert.False(settler.Accept(10.136, Packet));
        Assert.False(settler.Accept(10.146, Packet));
        Assert.True(settler.Accept(10.156, Packet));
    }

    [Fact]
    public void ADeviceWithoutTimestampsIsNotHeldBack()
    {
        Assert.True(new StartupSettler(Rate).Accept(double.NaN, Packet));
    }

    [Fact]
    public void ADeviceThatNeverSettlesIsAcceptedInTheEnd()
    {
        var settler = new StartupSettler(Rate);
        bool accepted = false;
        for (int i = 0; i < 100; i++) accepted = settler.Accept(10.0 + i * 0.05, Packet);

        Assert.True(accepted);
    }
}
