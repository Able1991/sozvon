namespace Sozvon.Core.Settings;

/// <summary>
/// A relaunch (after a change of the interface language) never cuts a recording or the engine's work short: asked for
/// while either goes on, it waits and happens by itself once both are over, as the Mac quits only after its work is done.
/// </summary>
public sealed class DeferredRelaunch
{
    /// <summary>Asked for during work: the restart comes when the recording and the processing end.</summary>
    public bool Waiting { get; private set; }

    /// <summary>The button was pressed. True: relaunch right now. False: it waits for idle.</summary>
    public bool Request(bool busy)
    {
        Waiting = busy;
        return !busy;
    }

    /// <summary>The recording or the queue changed. True once, the moment the wait is over.</summary>
    public bool Resume(bool busy)
    {
        if (!Waiting || busy)
        {
            return false;
        }
        Waiting = false;
        return true;
    }
}
