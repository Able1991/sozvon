using Sozvon.Core.Settings;

namespace Sozvon.App.Shell;

/// <summary>
/// Restarts the app when asked, but never over a recording or a transcription (<see cref="DeferredRelaunch"/>): then
/// it waits, and the restart comes by itself when the work ends.
/// </summary>
/// <param name="busy">A recording, its stop, the form after a call, or the engine's queue is going on.</param>
/// <param name="restart">Ends this process and starts a new one.</param>
public sealed class Relauncher(Func<bool> busy, Action restart)
{
    private readonly DeferredRelaunch _rule = new();

    /// <summary>The restart is on its way, waiting for the work to end.</summary>
    public bool Waiting => _rule.Waiting;

    public event EventHandler? WaitingChanged;

    /// <summary>"Relaunch Sozvon" pressed.</summary>
    public void Request()
    {
        if (_rule.Request(busy()))
        {
            restart();
        }
        else
        {
            WaitingChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    /// <summary>After every change of the recording or the queue: the waiting restart goes once both are idle.</summary>
    public void Poll()
    {
        if (_rule.Resume(busy()))
        {
            restart();
        }
    }
}
