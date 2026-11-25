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

    /// <summary>Where speed.json lives; null: no time estimates (tests, a run without a data folder).</summary>
    public string? SpeedFolder
    {
        get => _speedFolder;
        init
        {
            _speedFolder = value;
            if (value is not null) _speed = SpeedBook.Load(value);
        }
    }

    private readonly string? _speedFolder;
    private SpeedBook _speed = new();

    /// <summary>When the running transcription started: for the estimate and the speed sample.</summary>
    private DateTimeOffset? _startedAt;

    /// <summary>Folders being cut by trim_call.py now (full paths, as given).</summary>
    private readonly HashSet<string> _trimming = new(StringComparer.OrdinalIgnoreCase);
    private IEngineRun? _run;

    /// <summary>The bookkeeping after the running engine: a quit waits for it, so the call is saved before the app ends.</summary>
    private Task _watch = Task.CompletedTask;
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

    /// <summary>Queued, running or being trimmed: busy for audio cleanup, editing and the like.</summary>
    public bool Contains(string dir)
    {
        lock (_gate) return _queue.Contains(dir) || _trimming.Contains(Key(dir));
    }

    public bool IsTrimming(string dir)
    {
        lock (_gate) return _trimming.Contains(Key(dir));
    }

    private static string Key(string dir) => Path.GetFullPath(dir).TrimEnd(Path.DirectorySeparatorChar);

    /// <summary>
    /// Cuts the call to <paramref name="start"/>..<paramref name="end"/> seconds (<c>bin\trim_call.py</c>). Refused while
    /// the call is queued, running or already being cut. The cut is never stopped halfway, not even by a quit: the engine
    /// finishes it under the call's lock. Queuing the transcription afterwards is the caller's.
    /// </summary>
    public async Task<RunOutcome> TrimAsync(string dir, double start, double end)
    {
        lock (_gate)
        {
            if (_queue.Contains(dir) || !_trimming.Add(Key(dir))) return new RunOutcome.Failed(1, "busy");
        }
        Changed?.Invoke();
        try
        {
            var result = await runner.StartTrim(dir, start, end).Completion.ConfigureAwait(false);
            return result.Outcome;
        }
        finally
        {
            lock (_gate) _trimming.Remove(Key(dir));
            Changed?.Invoke();
        }
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
            // Being cut: a run now would only wait on the call's lock and then read the old tracks.
            if (_trimming.Contains(Key(dir)) || _queue.Admit(dir, kind) != QueueAdmission.Queued) return EnqueueResult.Duplicate;
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

    /// <summary>The app is quitting: the running call goes back in the queue, the waiting ones keep their place.</summary>
    public async Task AbortAllAsync()
    {
        Task watch;
        lock (_gate)
        {
            _quitting = true;
            watch = _watch;
        }
        await StopRunningAsync().ConfigureAwait(false);
        await watch.ConfigureAwait(false);
    }

    private bool Quitting
    {
        get { lock (_gate) return _quitting; }
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
            _startedAt = job.Kind == ProcessingKind.Transcribe ? DateTimeOffset.UtcNow : null;
            var run = runner.Start(job, line => OutputLine?.Invoke(job.Dir, line));
            _run = run;
            _watch = WatchAsync(job, run);
            return;
        }
    }

    private async Task WatchAsync(ProcessingJob job, IEngineRun run)
    {
        var result = await run.Completion.ConfigureAwait(false);
        DateTimeOffset? started;
        lock (_gate) started = _startedAt;
        if (job.Kind == ProcessingKind.Transcribe && result.Outcome.IsOk && !result.Stopped) RecordSpeed(job.Dir, started);
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
        if (result.Stopped && Quitting)
        {
            CallFile.BackToQueue(dir, AheadOfTheWaiting());
            return dir;
        }
        if (!result.Outcome.IsOk)
        {
            CallFile.SetFailedUnlessDone(dir);
            CallFile.ClearRetries(dir);
            return dir;
        }
        CallFile.ClearRetries(dir);
        return Rename(dir);
    }

    /// <summary>A finished transcription of a long call teaches the speed of this computer, as on the Mac.</summary>
    private void RecordSpeed(string dir, DateTimeOffset? started)
    {
        if (_speedFolder is null || started is not { } at) return;
        var call = CallFile.Read(dir);
        if (call.Object("engine")?.Text("model") is not { Length: > 0 } model) return;
        lock (_gate)
        {
            _speed.Record(model, CallSeconds(call), (DateTimeOffset.UtcNow - at).TotalSeconds);
            _speed.Save(_speedFolder);
        }
    }

    private static double CallSeconds(System.Text.Json.Nodes.JsonObject call) => AudioTimes.From(call.Object("audio")).Duration;

    /// <summary>
    /// The time estimate of a call: for the running one its total and how long it has run, for a waiting one its own
    /// total (with the model of the latest sample: the engine picks its model during the run). Null without samples and
    /// for summary runs.
    /// </summary>
    public (double Total, double? Elapsed)? Estimate(string dir)
    {
        lock (_gate)
        {
            if (_speed.LastModel is not { } model) return null;
            if (_queue.Running is { Kind: ProcessingKind.Transcribe } running && SameDir(running.Dir, dir))
            {
                if (_startedAt is not { } at || _speed.Estimate(model, CallSeconds(CallFile.Read(dir))) is not { } total) return null;
                return (total, (DateTimeOffset.UtcNow - at).TotalSeconds);
            }
            if (!_queue.Waiting.Any(j => j.Kind == ProcessingKind.Transcribe && SameDir(j.Dir, dir))) return null;
            return _speed.Estimate(model, CallSeconds(CallFile.Read(dir))) is { } own ? (own, null) : null;
        }
    }

    /// <summary>Seconds for everything in the queue when more than one call waits; null without samples.</summary>
    public double? QueueEstimate()
    {
        lock (_gate)
        {
            if (_queue.Waiting.Count <= 1 || _speed.LastModel is not { } model) return null;
            var total = _queue.Waiting.Where(j => j.Kind == ProcessingKind.Transcribe)
                .Sum(j => _speed.Estimate(model, CallSeconds(CallFile.Read(j.Dir))) ?? 0);
            if (_queue.Running is { Kind: ProcessingKind.Transcribe } running && _startedAt is { } at
                && _speed.Estimate(model, CallSeconds(CallFile.Read(running.Dir))) is { } own)
                total += Math.Max(0, own - (DateTimeOffset.UtcNow - at).TotalSeconds);
            return total > 0 ? total : null;
        }
    }

    private static bool SameDir(string a, string b) => string.Equals(Key(a), Key(b), StringComparison.OrdinalIgnoreCase);

    /// <summary>A queue time just before every waiting call: the run cut short by a quit keeps its turn at the next launch.</summary>
    private DateTimeOffset AheadOfTheWaiting()
    {
        var first = Waiting.Select(j => CallFile.QueuedAt(CallFile.Read(j.Dir))).Where(t => t is not null).Min();
        return first is { } at ? at.AddMilliseconds(-1) : DateTimeOffset.UtcNow;
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
