using Sozvon.Core.Calls;
using Sozvon.Core.Foundation;

namespace Sozvon.Core.Engine;

public enum EnqueueResult
{
    Accepted,
    Duplicate,

    /// <summary>The run goes on, but its place in the queue was not saved: a restart would forget it.</summary>
    NotSaved,
}

/// <summary>A run ended. <paramref name="Dir"/> is the folder after any rename; Stopped: the app ended it.</summary>
public sealed record CallRunFinished(string Dir, ProcessingKind Kind, RunOutcome Outcome, bool Stopped);

/// <summary>
/// Drives the queue: one engine run at a time, saved in call.json so it survives a restart. The UI layer listens to
/// the events, which arrive on background threads.
/// </summary>
public sealed class CallProcessor(Func<string> callsFolder, IEngineRunner runner, Func<IReadOnlyList<Project>> projects)
{
    public CallProcessor(string callsRoot, IEngineRunner runner, Func<IReadOnlyList<Project>> projects) : this(() => callsRoot, runner, projects)
    {
    }

    /// <summary>The calls folder of this moment: it can change in Settings between runs.</summary>
    private string CallsRoot => callsFolder();

    private readonly ProcessingQueue _queue = new();
    private readonly object _gate = new();
    private IEngineRun? _run;
    private bool _quitting;

    /// <summary>Asked before each start: a recording is going on, or a call app holds the microphone.</summary>
    public Func<bool> HoldsQueue { get; set; } = () => false;

    public event Action? Changed;
    public event Action<CallRunFinished>? RunFinished;
    public event Action<string, string>? OutputLine;

    public ProcessingJob? Running { get { lock (_gate) return _queue.Running; } }
    public IReadOnlyList<ProcessingJob> Waiting { get { lock (_gate) return _queue.Waiting.ToList(); } }
    public bool HasWork { get { lock (_gate) return !_queue.IsEmpty; } }
    public bool IsEngineUpdating { get { lock (_gate) return _queue.EngineUpdating; } }

    public bool Contains(string dir)
    {
        lock (_gate) return _queue.Contains(dir);
    }

    /// <summary>Writes the answers to call.json and queues the call: the engine reads them from there.</summary>
    public EnqueueResult Transcribe(string dir, CallInfo info)
    {
        if (!CallFile.WriteInfo(dir, info)) return EnqueueResult.NotSaved;
        if (CallFile.Read(dir).ContainsKey(CallFile.PendingKey)) CallFile.SetInfoPending(dir, false);
        return Enqueue(dir, ProcessingKind.Transcribe);
    }

    public EnqueueResult Resummarize(string dir) => Enqueue(dir, ProcessingKind.SummaryOnly);

    public EnqueueResult Enqueue(string dir, ProcessingKind kind)
    {
        var result = EnqueueResult.Accepted;
        lock (_gate)
        {
            if (_queue.Admit(dir, kind) != QueueAdmission.Queued) return EnqueueResult.Duplicate;
            CallFile.ClearRetries(dir); // asked for by the user: a later crash gets its retry again
            StartNextLocked();
            if (_queue.IsWaiting(dir) && !CallFile.SetQueued(dir, DateTimeOffset.UtcNow, kind == ProcessingKind.SummaryOnly))
                result = EnqueueResult.NotSaved;
        }
        Changed?.Invoke();
        return result;
    }

    /// <summary>At launch: the waiting calls and the one a crash interrupted go back in the queue. Their folders are returned for the .work sweep.</summary>
    public IReadOnlyList<string> RestoreQueue()
    {
        var jobs = CallFile.RecoverQueue(CallsRoot);
        lock (_gate)
        {
            foreach (var job in jobs) _queue.Admit(job.Dir, job.Kind);
            StartNextLocked();
        }
        Changed?.Invoke();
        return jobs.Select(j => j.Dir).ToList();
    }

    /// <summary>Takes a waiting call out of the queue, back to how it was. An interrupted one ends failed.</summary>
    public bool RemoveFromQueue(string dir)
    {
        lock (_gate)
        {
            if (!_queue.Remove(dir)) return false;
        }
        CallFile.SetQueued(dir, null);
        if (CallFile.Read(dir).ContainsKey(CallFile.RetriesKey)) CallFile.SetStatus(dir, CallStatus.Failed);
        CallFile.ClearRetries(dir);
        Changed?.Invoke();
        return true;
    }

    /// <summary>A recording ended, a call app released the microphone, or an update finished: the queue may go on.</summary>
    public void StartNext()
    {
        lock (_gate) StartNextLocked();
        Changed?.Invoke();
    }

    public bool BeginEngineUpdate()
    {
        bool started;
        lock (_gate) started = _queue.BeginEngineUpdate();
        Changed?.Invoke();
        return started;
    }

    public void EndEngineUpdate()
    {
        lock (_gate)
        {
            _queue.EndEngineUpdate();
            StartNextLocked();
        }
        Changed?.Invoke();
    }

    /// <summary>Ends the running engine; the next waiting call follows.</summary>
    public Task StopRunningAsync()
    {
        IEngineRun? run;
        lock (_gate) run = _run;
        return run?.StopAsync() ?? Task.CompletedTask;
    }

    /// <summary>The app is quitting: the running call ends as a crash would, the waiting ones keep their place.</summary>
    public Task AbortAllAsync()
    {
        lock (_gate) _quitting = true;
        return StopRunningAsync();
    }

    private void StartNextLocked()
    {
        while (!_quitting && _queue.StartNext(HoldsQueue()) is { } job)
        {
            if (!Directory.Exists(job.Dir))
            {
                _queue.Finish(job.Dir); // deleted while waiting
                continue;
            }
            CallFile.SetQueued(job.Dir, null);
            var run = runner.Start(job, line => OutputLine?.Invoke(job.Dir, line));
            _run = run;
            _ = WatchAsync(job, run);
            return;
        }
    }

    private async Task WatchAsync(ProcessingJob job, IEngineRun run)
    {
        var result = await run.Completion.ConfigureAwait(false);
        var dir = job.Dir;
        if (job.Kind == ProcessingKind.Transcribe) dir = FinishCall(job.Dir, result);
        lock (_gate)
        {
            _queue.Finish(job.Dir);
            _run = null;
            StartNextLocked();
        }
        Changed?.Invoke();
        RunFinished?.Invoke(new CallRunFinished(dir, job.Kind, result.Outcome, result.Stopped));
    }

    private string FinishCall(string dir, EngineRunResult result)
    {
        if (!result.Outcome.IsOk)
        {
            CallFile.SetFailedUnlessDone(dir);
            CallFile.ClearRetries(dir);
            return dir;
        }
        CallFile.ClearRetries(dir);
        return Rename(dir);
    }

    /// <summary>The readable folder name, only after success: while the engine writes to the folder, it stays put.</summary>
    private string Rename(string dir)
    {
        var call = CallFile.Read(dir);
        var name = CallFolderName.Build(Path.GetFileName(dir), CallFile.Info(call), projects(), CallParticipants.List(call), CallsRoot);
        if (name == Path.GetFileName(dir)) return dir;
        var target = Path.Combine(Path.GetDirectoryName(dir)!, name);
        if (Directory.Exists(target)) return dir;
        try
        {
            BusyRetry.Run(() => Directory.Move(dir, target));
            return target;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return dir;
        }
    }
}
