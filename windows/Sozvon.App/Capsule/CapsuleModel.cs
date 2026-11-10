namespace Sozvon.App.Capsule;

public enum CapsulePhase { Idle, Starting, Recording, Saved, Processing, Prompt }

/// <summary>What the middle of the capsule shows instead of the wave while recording.</summary>
public enum CapsuleHint { None, StopCountdown, TellOthers, MicSilent, SystemSilent }

/// <summary>What the capsule shows. It holds no logic: the recorder decides, the window draws.</summary>
public sealed record CapsuleModel(CapsulePhase Phase)
{
    public TimeSpan Elapsed { get; init; }
    public int Marks { get; init; }

    /// <summary>The system-wide shortcut marks the moment right now (<see cref="Sozvon.Core.Calls.MarkShortcut"/>): the button may promise it.</summary>
    public bool MarkShortcutHeld { get; init; }

    public CapsuleHint Hint { get; init; }
    public TimeSpan HintTime { get; init; }
    public int? SavedMinutes { get; init; }
    public string CallApp { get; init; } = "";
    public int? AutoStartSeconds { get; init; }
}
