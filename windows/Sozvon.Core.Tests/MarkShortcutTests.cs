using Sozvon.Core.Calls;

namespace Sozvon.Core.Tests;

public sealed class MarkShortcutTests
{
    [Fact]
    public void PromisesTheKeysOnlyWhileTheyAreHeld()
    {
        Assert.Equal("Mark (Ctrl+Alt+I)", MarkShortcut.Tooltip("Mark", held: true));
        Assert.Equal("Mark", MarkShortcut.Tooltip("Mark", held: false));
    }

    [Fact]
    public void StartsWithoutTheKeysAndWithoutAComplaint()
    {
        var shortcut = new MarkShortcut();
        Assert.False(shortcut.Held);
        Assert.False(shortcut.Taken);
    }

    [Fact]
    public void ARegistrationThatWorkedHoldsTheKeys()
    {
        var shortcut = new MarkShortcut();
        shortcut.Registered(success: true);
        Assert.True(shortcut.Held);
        Assert.False(shortcut.Taken);
        shortcut.Released();
        Assert.False(shortcut.Held);
        Assert.False(shortcut.Taken);
    }

    [Fact]
    public void AFailedRegistrationIsRememberedUntilTheNextSuccess()
    {
        var shortcut = new MarkShortcut();
        shortcut.Registered(success: false);
        Assert.False(shortcut.Held);
        Assert.True(shortcut.Taken);
        // The recording ends: Settings keeps explaining the silent shortcut.
        shortcut.Released();
        Assert.True(shortcut.Taken);
        shortcut.Registered(success: true);
        Assert.False(shortcut.Taken);
    }

    [Fact]
    public void TellsAboutEveryChange()
    {
        var shortcut = new MarkShortcut();
        var changes = 0;
        shortcut.Changed += () => changes++;
        shortcut.Registered(success: false);
        shortcut.Released();
        shortcut.Registered(success: true);
        Assert.Equal(3, changes);
    }
}
