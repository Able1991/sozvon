namespace Sozvon.Core.Calls;

/// <summary>
/// The system-wide shortcut for "Mark as important" (Ctrl+Alt+I on Windows, the Mac's ⌃⌥I): what the app may promise
/// about it. The keys are asked for at the start of each recording and given back at its end, as on the Mac, so other
/// programs keep them in between. Another program may hold the same keys; then the press would do nothing, so the
/// app must say so instead of promising the shortcut.
/// </summary>
public sealed class MarkShortcut
{
    public const string Keys = "Ctrl+Alt+I";

    /// <summary>The keys are ours right now: a press anywhere marks the moment.</summary>
    public bool Held { get; private set; }

    /// <summary>The last registration failed: another program has the keys. Stays known after the recording ends.</summary>
    public bool Taken { get; private set; }

    public event Action? Changed;

    /// <summary>The recording started and the keys were asked for.</summary>
    public void Registered(bool success)
    {
        Held = success;
        Taken = !success;
        Changed?.Invoke();
    }

    /// <summary>The recording ended: the keys are given back. A failure stays known until the next success.</summary>
    public void Released()
    {
        Held = false;
        Changed?.Invoke();
    }

    /// <summary>The mark button's tooltip: the keys are promised only while they really work.</summary>
    public static string Tooltip(string mark, bool held) => held ? $"{mark} ({Keys})" : mark;
}
