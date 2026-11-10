using Sozvon.Core.Settings;

namespace Sozvon.Core.Tests;

public sealed class DeferredRelaunchTests
{
    [Fact]
    public void RelaunchesAtOnceWhenIdle()
    {
        var relaunch = new DeferredRelaunch();
        Assert.True(relaunch.Request(busy: false));
        Assert.False(relaunch.Waiting);
    }

    [Fact]
    public void WaitsWhileBusyAndGoesWhenTheWorkEnds()
    {
        var relaunch = new DeferredRelaunch();
        Assert.False(relaunch.Request(busy: true));
        Assert.True(relaunch.Waiting);
        // The recording goes on, then the engine takes the call: still not the moment.
        Assert.False(relaunch.Resume(busy: true));
        Assert.True(relaunch.Waiting);
        Assert.True(relaunch.Resume(busy: false));
        Assert.False(relaunch.Waiting);
    }

    [Fact]
    public void GoesOnceOnly()
    {
        var relaunch = new DeferredRelaunch();
        relaunch.Request(busy: true);
        Assert.True(relaunch.Resume(busy: false));
        Assert.False(relaunch.Resume(busy: false));
    }

    [Fact]
    public void NothingHappensWithoutARequest()
    {
        var relaunch = new DeferredRelaunch();
        Assert.False(relaunch.Resume(busy: false));
        Assert.False(relaunch.Resume(busy: true));
        Assert.False(relaunch.Waiting);
    }

    [Fact]
    public void ASecondPressWhileWaitingChangesNothing()
    {
        var relaunch = new DeferredRelaunch();
        relaunch.Request(busy: true);
        Assert.False(relaunch.Request(busy: true));
        Assert.True(relaunch.Waiting);
        Assert.True(relaunch.Resume(busy: false));
    }
}
