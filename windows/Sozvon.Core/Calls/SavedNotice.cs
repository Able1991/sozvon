namespace Sozvon.Core.Calls;

/// <summary>
/// "Recorded · N min" stays on the capsule for a moment after a stop, as on the Mac. The resting capsule is redrawn by
/// other things too (the engine's queue changing, a call prompt); while the notice holds, those redraws wait for it.
/// </summary>
public sealed class SavedNotice
{
    public static readonly TimeSpan ShownFor = TimeSpan.FromSeconds(3);

    private DateTimeOffset _until = DateTimeOffset.MinValue;

    /// <summary>The recording was saved and the capsule says so from <paramref name="now"/>.</summary>
    public void Show(DateTimeOffset now) => _until = now + ShownFor;

    /// <summary>The notice is still to be seen: nothing else should take its place yet.</summary>
    public bool Holds(DateTimeOffset now) => now < _until;

    /// <summary>The capsule moves on, whatever the clock says.</summary>
    public void End() => _until = DateTimeOffset.MinValue;
}
