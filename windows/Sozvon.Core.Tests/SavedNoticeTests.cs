using Sozvon.Core.Calls;

namespace Sozvon.Core.Tests;

public sealed class SavedNoticeTests
{
    private static readonly DateTimeOffset At = new(2026, 11, 10, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void HoldsNothingBeforeAStop()
    {
        var notice = new SavedNotice();
        Assert.False(notice.Holds(At));
    }

    [Fact]
    public void KeepsTheCapsuleForThreeSecondsAfterAStop()
    {
        var notice = new SavedNotice();
        notice.Show(At);
        // The engine's queue reports a change right after the stop: the capsule still says "Recorded".
        Assert.True(notice.Holds(At));
        Assert.True(notice.Holds(At + TimeSpan.FromSeconds(2.9)));
        Assert.False(notice.Holds(At + SavedNotice.ShownFor));
    }

    [Fact]
    public void EndsWhenTheCapsuleMovesOn()
    {
        var notice = new SavedNotice();
        notice.Show(At);
        notice.End();
        Assert.False(notice.Holds(At + TimeSpan.FromSeconds(1)));
    }
}
