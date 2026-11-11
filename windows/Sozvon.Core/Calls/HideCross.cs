namespace Sozvon.Core.Calls;

/// <summary>
/// The capsule's hide button (the cross) at rest. It comes in when the pointer is over the capsule; when the pointer
/// leaves it fades out where it stands and only then leaves the row, so the capsule shrinks after the fade, not before.
/// </summary>
public sealed class HideCross
{
    private bool _fading;

    /// <summary>Drawn at full strength (the pointer is over the capsule).</summary>
    public bool Visible { get; private set; }

    /// <summary>Takes its place in the row: while shown and while fading out.</summary>
    public bool InRow => Visible || _fading;

    /// <summary>The pointer is over the resting capsule or not. True when a fade-out starts now and must be timed.</summary>
    public bool Pointer(bool over)
    {
        if (over)
        {
            Visible = true;
            _fading = false;
            return false;
        }
        if (!Visible)
        {
            return false;
        }
        Visible = false;
        _fading = true;
        return true;
    }

    /// <summary>The fade-out has run its time: the cross leaves the row unless the pointer came back meanwhile.</summary>
    public void Faded() => _fading = false;
}
