using System.Text;
using System.Text.RegularExpressions;
using Sozvon.Core.Calls;

namespace Sozvon.Core.Engine;

/// <summary>How an engine run ended. Stopped: the app ended it.</summary>
public sealed record EngineRunResult(int ExitCode, RunOutcome Outcome, bool Stopped);

/// <summary>An engine run in progress.</summary>
public interface IEngineRun
{
    /// <summary>Never faults: a run that could not start completes with exit code -1.</summary>
    Task<EngineRunResult> Completion { get; }

    /// <summary>Asks the run to stop and returns once it has ended and its working files are gone.</summary>
    Task StopAsync();
}

public interface IEngineRunner
{
    /// <param name="onLine">Called on a background thread, in order, for every output line.</param>
    IEngineRun Start(ProcessingJob job, Action<string>? onLine = null);

    /// <summary><c>bin\trim_call.py</c>: cuts the call to <paramref name="start"/>..<paramref name="end"/> seconds of its timeline.</summary>
    IEngineRun StartTrim(string dir, double start, double end) => throw new NotSupportedException();
}

/// <summary>Runs <c>bin\process_call.py</c> for a call folder with the contract's environment.</summary>
public sealed class EngineSupervisor(EngineLayout layout, Func<EngineOptions> options, TimeSpan? stopGrace = null) : IEngineRunner
{
    public const string Script = "process_call.py";
    public const string LogName = "process.log";

    private readonly TimeSpan _stopGrace = stopGrace ?? TimeSpan.FromSeconds(10);

    public EngineSupervisor(EngineLayout layout, EngineOptions options, TimeSpan? stopGrace = null) : this(layout, () => options, stopGrace)
    {
    }

    public IEngineRun Start(ProcessingJob job, Action<string>? onLine = null)
    {
        List<string> arguments = [job.Dir];
        if (job.Kind == ProcessingKind.SummaryOnly) arguments.Add("--summary-only");
        return Run(Script, job.Dir, arguments, appendLog: false, onLine);
    }

    /// <summary>The cut goes into the call's process.log after the transcription's lines, as on the Mac.</summary>
    public IEngineRun StartTrim(string dir, double start, double end) =>
        Run(Trim.Script, dir, [dir, "--start", Seconds(start), "--end", Seconds(end)], appendLog: true, onLine: null);

    private static string Seconds(double s) => s.ToString("R", System.Globalization.CultureInfo.InvariantCulture);

    private IEngineRun Run(string script, string dir, List<string> scriptArguments, bool appendLog, Action<string>? onLine)
    {
        var log = Path.Combine(dir, LogName);
        if (!layout.IsInstalled) return Refused(log, $"the engine is not installed: {layout.Python}");

        var arguments = new List<string> { layout.Script(script) };
        arguments.AddRange(scriptArguments);
        var stop = new EngineStopEvent(CallFile.CallId(dir));
        var environment = EngineEnvironment.Build(layout, options());
        environment[EngineEnvironment.StopEventVariable] = stop.Name;
        var tracker = new OutputTracker();
        var request = new EngineRunRequest(layout.Python, arguments, environment, layout.Data, log, appendLog);
        try
        {
            var process = EngineProcess.Start(request, line =>
            {
                tracker.Consume(line);
                onLine?.Invoke(line);
            });
            return new EngineRun(process, stop, tracker, dir, _stopGrace);
        }
        catch (EngineStartException e)
        {
            stop.Dispose();
            return Refused(log, $"could not start the engine: {e.Message}");
        }
    }

    private static IEngineRun Refused(string log, string message)
    {
        try
        {
            File.WriteAllText(log, message + "\n", new UTF8Encoding(false));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // The message still reaches the user through the outcome.
        }
        return new RefusedRun(new EngineRunResult(-1, new RunOutcome.Failed(-1, message), Stopped: false));
    }

    private sealed class RefusedRun(EngineRunResult result) : IEngineRun
    {
        public Task<EngineRunResult> Completion { get; } = Task.FromResult(result);
        public Task StopAsync() => Task.CompletedTask;
    }

    private sealed class EngineRun : IEngineRun
    {
        private readonly EngineProcess _process;
        private readonly EngineStopEvent _stop;
        private readonly string _dir;
        private readonly TimeSpan _grace;
        private volatile bool _stopped;

        public Task<EngineRunResult> Completion { get; }

        internal EngineRun(EngineProcess process, EngineStopEvent stop, OutputTracker tracker, string dir, TimeSpan grace)
        {
            (_process, _stop, _dir, _grace) = (process, stop, dir, grace);
            Completion = FinishAsync(tracker);
        }

        public async Task StopAsync()
        {
            _stopped = true;
            _stop.RequestStop();
            try
            {
                await Completion.WaitAsync(_grace);
            }
            catch (TimeoutException)
            {
                _process.Terminate();
                await Completion;
            }
            WorkFiles.Remove(_dir);
        }

        private async Task<EngineRunResult> FinishAsync(OutputTracker tracker)
        {
            var exitCode = await _process.Completion;
            _stop.Dispose();
            return new EngineRunResult(exitCode, RunOutcome.Parse(exitCode, tracker.Result, tracker.LastLine), _stopped);
        }
    }
}

/// <summary>
/// The app's way to ask the engine to stop: a named event in the session's local namespace, its name passed in
/// <c>SOZVON_STOP_EVENT</c>. A GUI app has no console to send CTRL_BREAK through.
/// </summary>
internal sealed partial class EngineStopEvent : IDisposable
{
    private readonly EventWaitHandle _event;
    private bool _disposed;

    internal string Name { get; }

    internal EngineStopEvent(string callId)
    {
        Name = $@"Local\sozvon-stop-{Unsafe().Replace(callId, "_")}-{Guid.NewGuid():N}";
        _event = new EventWaitHandle(false, EventResetMode.ManualReset, Name);
    }

    internal void RequestStop()
    {
        lock (_event)
        {
            if (!_disposed) _event.Set();
        }
    }

    public void Dispose()
    {
        lock (_event)
        {
            _disposed = true;
            _event.Dispose();
        }
    }

    [GeneratedRegex("[^A-Za-z0-9-]")]
    private static partial Regex Unsafe();
}
