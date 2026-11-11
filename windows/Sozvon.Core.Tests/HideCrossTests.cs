using Sozvon.Core.Calls;

namespace Sozvon.Core.Tests;

public sealed class HideCrossTests
{
    [Fact]
    public void IsNotInTheRowAtRest()
    {
        var cross = new HideCross();
        Assert.False(cross.InRow);
        Assert.False(cross.Visible);
    }

    [Fact]
    public void ComesInWhenThePointerEnters()
    {
        var cross = new HideCross();
        cross.Pointer(over: true);
        Assert.True(cross.InRow);
        Assert.True(cross.Visible);
    }

    [Fact]
    public void FadesOutInPlaceWhenThePointerLeavesAndLeavesTheRowAfterwards()
    {
        var cross = new HideCross();
        cross.Pointer(over: true);
        Assert.True(cross.Pointer(over: false));
        // The capsule keeps its width while the cross fades: it leaves the row only once it is gone.
        Assert.True(cross.InRow);
        Assert.False(cross.Visible);
        cross.Faded();
        Assert.False(cross.InRow);
    }

    [Fact]
    public void ComingBackDuringTheFadeKeepsItInTheRow()
    {
        var cross = new HideCross();
        cross.Pointer(over: true);
        cross.Pointer(over: false);
        Assert.False(cross.Pointer(over: true));
        Assert.True(cross.InRow);
        Assert.True(cross.Visible);
        // A fade that had already been asked for ends without taking it away.
        cross.Faded();
        Assert.True(cross.InRow);
    }

    [Fact]
    public void LeavingWhenItWasNeverShownStartsNoFade()
    {
        var cross = new HideCross();
        Assert.False(cross.Pointer(over: false));
        Assert.False(cross.InRow);
    }
}
