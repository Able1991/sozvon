namespace Sozvon.Core.Foundation;

/// <summary>
/// Keeps the computer from idle sleep while a call is recorded or a transcription is queued or running, as on the Mac
/// (SleepGuard.swift). A sleep the user asks for (the lid, the Start menu) still happens: the recording is saved before
/// it. The hold itself is the app's: on Windows SetThreadExecutionState on the UI thread, which lives as long as the app.
/// </summary>
public sealed class SleepGuard(Action hold, Action release, Action<string>? log = null)
{
    private readonly object _gate = new();
    private bool _held;

    public bool IsHeld
    {
        get { lock (_gate) return _held; }
    }

    /// <summary>Takes the hold when recording or work is pending, gives it back when neither is. Safe on every state change.</summary>
    public void Update(bool recording, bool hasWork)
    {
        lock (_gate)
        {
            var needed = recording || hasWork;
            if (needed == _held) return;
            if (needed) hold();
            else release();
            _held = needed;
            log?.Invoke(needed ? $"sleep guard: taken (recording={recording}, work={hasWork})" : "sleep guard: released");
        }
    }
}
