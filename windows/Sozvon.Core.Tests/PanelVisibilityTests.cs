using Sozvon.Core.Settings;

namespace Sozvon.Core.Tests;

public sealed class PanelVisibilityTests
{
    [Theory]
    // active, counting, panel on, when idle -> shown
    [InlineData(false, false, true, true, true)]   // at rest, shown at rest
    [InlineData(false, false, true, false, false)] // at rest, hidden at rest
    [InlineData(true, false, true, false, true)]   // a recording or a call prompt brings it back
    [InlineData(true, false, false, true, false)]  // the panel turned off: nothing at all...
    [InlineData(false, true, false, false, true)]  // ...but a countdown always shows
    [InlineData(true, true, true, false, true)]
    public void FollowsTheMacsRule(bool active, bool counting, bool panelOn, bool whenIdle, bool shown) =>
        Assert.Equal(shown, PanelVisibility.Shows(active, counting, panelOn, whenIdle));
}
