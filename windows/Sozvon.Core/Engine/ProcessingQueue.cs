namespace Sozvon.Core.Engine;

public enum ProcessingKind
{
    Transcribe,

    /// <summary>A new summary from the existing transcript (<c>process_call.py --summary-only</c>).</summary>
    SummaryOnly,
}

/// <summary>A queued engine run. Two spellings of one folder are one job.</summary>
public sealed class ProcessingJob(string dir, ProcessingKind kind) : IEquatable<ProcessingJob>
{
    public string Dir { get; } = dir;
    public ProcessingKind Kind { get; } = kind;

    public static string Key(string dir) =>
        Path.TrimEndingDirectorySeparator(Path.GetFullPath(dir)).ToUpperInvariant();

    public bool Equals(ProcessingJob? other) => other is not null && Key(Dir) == Key(other.Dir) && Kind == other.Kind;
    public override bool Equals(object? obj) => Equals(obj as ProcessingJob);
    public override int GetHashCode() => HashCode.Combine(Key(Dir), Kind);
    public override string ToString() => $"{Kind}: {Dir}";
}

public enum QueueAdmission
{
    Queued,

    /// <summary>This folder is already being transcribed or is waiting.</summary>
    Duplicate,
}

/// <summary>At most one engine run at a time, the rest first in, first out. Holds no files: see CallFile.Queue.</summary>
public sealed class ProcessingQueue
{
    private readonly List<ProcessingJob> _waiting = [];

    public ProcessingJob? Running { get; private set; }
    public IReadOnlyList<ProcessingJob> Waiting => _waiting;

    /// <summary>An engine environment update is running: nothing starts.</summary>
    public bool EngineUpdating { get; private set; }

    public bool IsEmpty => Running is null && _waiting.Count == 0;

    /// <summary>Nothing runs and something waits: worth asking whether a recording or a call holds the queue.</summary>
    public bool CanStartNext => Running is null && !EngineUpdating && _waiting.Count > 0;

    public bool Contains(string dir) => IsRunning(dir) || IsWaiting(dir);

    public bool IsRunning(string dir) => Running is { } job && ProcessingJob.Key(job.Dir) == ProcessingJob.Key(dir);

    public bool IsWaiting(string dir) => _waiting.Any(j => ProcessingJob.Key(j.Dir) == ProcessingJob.Key(dir));

    public QueueAdmission Admit(string dir, ProcessingKind kind = ProcessingKind.Transcribe)
    {
        if (Contains(dir)) return QueueAdmission.Duplicate;
        _waiting.Add(new ProcessingJob(dir, kind));
        return QueueAdmission.Queued;
    }

    /// <summary>The next job, moved to running. Held: a recording or a call app would suffer from the load.</summary>
    public ProcessingJob? StartNext(bool held)
    {
        if (!CanStartNext || held) return null;
        Running = _waiting[0];
        _waiting.RemoveAt(0);
        return Running;
    }

    /// <summary>A run finished, successfully or not.</summary>
    public void Finish(string dir)
    {
        if (IsRunning(dir)) Running = null;
    }

    /// <summary>Takes a waiting folder out of the queue. A running job stays.</summary>
    public bool Remove(string dir)
    {
        var key = ProcessingJob.Key(dir);
        return _waiting.RemoveAll(j => ProcessingJob.Key(j.Dir) == key) > 0;
    }

    public bool BeginEngineUpdate()
    {
        if (EngineUpdating) return false;
        EngineUpdating = true;
        return true;
    }

    public void EndEngineUpdate() => EngineUpdating = false;
}
