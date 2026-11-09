namespace Sozvon.Core.Calls;

/// <summary>A recording in progress: folder, start time and what has already been said about the call.</summary>
public sealed record RecordingSession(string Dir, DateTimeOffset StartedAt, CallInfo Info)
{
    /// <summary>"12:34" or "1:02:03" since the recording started.</summary>
    public string Elapsed(DateTimeOffset now) => Call.Clock(Math.Max(0, (int)(now - StartedAt).TotalSeconds), "0:00");
}

/// <summary>
/// idle, begin, starting, started, recording, stop, stopping, finalized, saved, dismiss, idle. From starting a failure
/// goes back to idle; from saved a new recording may begin while the prompt is still open.
/// </summary>
public abstract record RecordingState
{
    public sealed record Idle : RecordingState;

    public sealed record Starting(string Dir) : RecordingState;

    public sealed record Recording(RecordingSession Session) : RecordingState;

    /// <summary>Files are being closed. App quit and capture failure wait on the task.</summary>
    public sealed record Stopping(RecordingSession Session, Task Finalize) : RecordingState;

    public sealed record Saved(string Dir) : RecordingState;

    public bool IsRecording => this is Recording;
    public bool IsStarting => this is Starting;
    public bool IsStopping => this is Stopping;
    public bool CanBegin => this is Idle or Saved;
    public bool IsCapturing => IsRecording || IsStopping;

    public RecordingSession? ActiveSession => this switch
    {
        Recording r => r.Session,
        Stopping s => s.Session,
        _ => null,
    };

    public string? Folder => this switch
    {
        Starting s => s.Dir,
        Saved s => s.Dir,
        _ => ActiveSession?.Dir,
    };

    public Task? FinalizeTask => (this as Stopping)?.Finalize;

    /// <summary>Short state name for logs.</summary>
    public string Name => GetType().Name.ToLowerInvariant();
}

/// <summary>State transitions. Each method checks that the transition is allowed and returns false if not.</summary>
public sealed class RecordingMachine
{
    public RecordingState State { get; private set; } = new RecordingState.Idle();

    public bool Begin(string dir)
    {
        if (!State.CanBegin) return false;
        State = new RecordingState.Starting(dir);
        return true;
    }

    public bool Started(RecordingSession session)
    {
        if (State is not RecordingState.Starting starting || starting.Dir != session.Dir) return false;
        State = new RecordingState.Recording(session);
        return true;
    }

    public bool StartFailed()
    {
        if (!State.IsStarting) return false;
        State = new RecordingState.Idle();
        return true;
    }

    public bool UpdateInfo(CallInfo info)
    {
        if (State is not RecordingState.Recording recording) return false;
        State = new RecordingState.Recording(recording.Session with { Info = info });
        return true;
    }

    /// <summary>Stop: the finalize task finishes writing the files from here. Returns the session.</summary>
    public RecordingSession? Stop(Task finalize)
    {
        if (State is not RecordingState.Recording recording) return null;
        State = new RecordingState.Stopping(recording.Session, finalize);
        return recording.Session;
    }

    public bool Finalized()
    {
        if (State is not RecordingState.Stopping stopping) return false;
        State = new RecordingState.Saved(stopping.Session.Dir);
        return true;
    }

    /// <summary>The call prompt was answered. If a new recording has already started, nothing changes.</summary>
    public bool DismissSaved(string dir)
    {
        if (State is not RecordingState.Saved saved || saved.Dir != dir) return false;
        State = new RecordingState.Idle();
        return true;
    }
}
