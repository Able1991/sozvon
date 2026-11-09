using Sozvon.Audio.Capture;
using Sozvon.Audio.Session;
using Sozvon.Audio.Tracks;

namespace Sozvon.Audio;

/// <summary>The recorder over WASAPI: the default microphone (raw where offered) and the loopback of the default output.</summary>
public sealed class WasapiRecorder(RecorderOptions options) : IRecorder
{
    private const int LevelIntervalMilliseconds = 100;
    private static readonly TimeSpan s_stopTimeout = TimeSpan.FromSeconds(15);

    private readonly object _gate = new();
    private readonly List<double> _markTimes = [];
    private readonly Action<string> _log = CreateLog(options.LogPath);

    private Active? _active;
    private bool _busy;

    public event EventHandler<RecorderLevels>? LevelsChanged;

    public event EventHandler<RecorderAlert>? AlertRaised;

    public event EventHandler<Exception>? Failed;

    public bool IsRecording
    {
        get
        {
            lock (_gate) return _active is not null;
        }
    }

    public async Task StartAsync(string callDirectory, CancellationToken cancellationToken = default)
    {
        lock (_gate)
        {
            if (_active is not null || _busy) throw new InvalidOperationException("Already recording.");
            _busy = true;
        }

        try
        {
            var files = new SessionFiles(callDirectory);
            EnsureUnused(files);
            files.Create();
            var active = new Active(files, DateTimeOffset.UtcNow, SharedClock.Now);
            lock (_gate) _markTimes.Clear();
            SaveJournal(active);
            await OpenTracksAsync(active, cancellationToken).ConfigureAwait(false);

            active.Watch = new RecordingWatch(active.StartedClock);
            active.Timer = new Timer(_ => Tick(active), null, LevelIntervalMilliseconds, LevelIntervalMilliseconds);
            lock (_gate) _active = active;
        }
        finally
        {
            lock (_gate) _busy = false;
        }
    }

    public bool Mark()
    {
        Active? active;
        double now = SharedClock.Now;
        lock (_gate)
        {
            active = _active;
            if (active is null) return false;
            if (_markTimes.Count > 0 && now - _markTimes[^1] < CallMarks.MinGapSeconds) return false;
            _markTimes.Add(now);
        }
        SaveJournal(active);
        return true;
    }

    public async Task<RecordingResult> StopAsync(CancellationToken cancellationToken = default)
    {
        Active active;
        double[] marks;
        lock (_gate)
        {
            active = _active ?? throw new InvalidOperationException("Not recording.");
            _active = null;
            marks = _markTimes.ToArray();
        }

        double stopAt = SharedClock.Now;
        await active.Timer!.DisposeAsync().ConfigureAwait(false);
        await Task.WhenAll(active.Mic!.StopAsync(stopAt), active.System!.StopAsync(stopAt))
            .WaitAsync(s_stopTimeout, cancellationToken).ConfigureAwait(false);

        var journal = new SessionJournal(active.StartedWall, active.Mic.Origin, active.System.Origin, marks);
        SaveJournal(active, journal);
        RecordingResult result = await RecordingFinalizer.FinalizeAsync(active.Files, journal, marks, options.FfmpegPath,
            active.Mic.IsRaw, cancellationToken).ConfigureAwait(false);
        _log($"saved {active.Files.CallDirectory}: mic {result.Audio.MicSeconds:F2} s, system {result.Audio.SystemSeconds:F2} s");
        return result;
    }

    /// <summary>A microphone that will not open refuses the start. A missing output only leaves that track silent for now.</summary>
    private async Task OpenTracksAsync(Active active, CancellationToken cancellationToken)
    {
        try
        {
            SessionFiles files = active.Files;
            active.Mic = CreateTrack("microphone", files.MicWav, RecordingFormat.MicChannels, CaptureKind.Microphone);
            active.System = CreateTrack("system", files.SystemWav, RecordingFormat.SystemChannels, CaptureKind.Loopback);
            active.Mic.Start();
            active.System.Start();

            EndpointUnavailableException? micError = await active.Mic.FirstOpen.WaitAsync(cancellationToken).ConfigureAwait(false);
            if (micError is not null) throw new RecorderStartException(micError.Message, micError.AccessDenied, micError);

            EndpointUnavailableException? systemError = await active.System.FirstOpen.WaitAsync(cancellationToken).ConfigureAwait(false);
            if (systemError is not null) _log($"system: not capturing yet, will keep trying: {systemError.Message}");
        }
        catch
        {
            await AbandonAsync(active).ConfigureAwait(false);
            throw;
        }
    }

    private TrackRecorder CreateTrack(string name, string wav, int channels, CaptureKind kind)
    {
        var spool = new TrackSpool(wav, RecordingFormat.SampleRate, channels, ReportFailure);
        return new TrackRecorder(name, channels, () => new WasapiDevices(kind), spool, _log, ReportFailure, () => SharedClock.Now,
            settlesAtStart: kind == CaptureKind.Microphone);
    }

    private void ReportFailure(Exception error)
    {
        _log($"recording failed: {error.Message}");
        Failed?.Invoke(this, error);
    }

    /// <summary>A subscriber's exception on this timer thread would end the process and the recording with it.</summary>
    private void Tick(Active active)
    {
        try
        {
            Watch(active);
        }
        catch (Exception ex)
        {
            _log($"level update failed: {ex}");
        }
    }

    private void Watch(Active active)
    {
        if (active.JournalStale && active.Mic!.Origin is not null && active.System!.Origin is not null)
        {
            active.JournalStale = false;
            SaveJournal(active);
        }

        WatchResult result = active.Watch!.Update(SharedClock.Now, active.Mic!.Meter, active.System!.Meter);
        if (result.RecaptureMic)
        {
            _log("microphone: silent for two minutes, capturing again");
            active.Mic.Recapture();
        }
        if (result.RecaptureSystem)
        {
            _log("system: silent for two minutes, capturing again");
            active.System.Recapture();
        }
        foreach (RecorderAlert alert in result.Alerts) AlertRaised?.Invoke(this, alert);
        LevelsChanged?.Invoke(this, result.Levels);
    }

    private void SaveJournal(Active active)
    {
        double[] marks;
        lock (_gate) marks = _markTimes.ToArray();
        SaveJournal(active, new SessionJournal(active.StartedWall, active.Mic?.Origin, active.System?.Origin, marks));
    }

    /// <summary>A journal that fails to save costs only the offsets of a crashed recording, never the recording.</summary>
    private void SaveJournal(Active active, SessionJournal journal)
    {
        lock (active)
        {
            try
            {
                journal.Save(active.Files.Journal);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                _log($"cannot save the session journal: {ex.Message}");
            }
        }
    }

    /// <summary>A start that failed leaves no session behind. Its own failure is only logged: the caller has the real one.</summary>
    private async Task AbandonAsync(Active active)
    {
        try
        {
            double now = SharedClock.Now;
            var stopping = new[] { active.Mic?.StopAsync(now), active.System?.StopAsync(now) };
            await Task.WhenAll(stopping.OfType<Task>()).WaitAsync(s_stopTimeout).ConfigureAwait(false);
            Directory.Delete(active.Files.Folder, recursive: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or TimeoutException)
        {
            _log($"cannot clear the failed start: {ex.Message}");
        }
    }

    private static void EnsureUnused(SessionFiles files)
    {
        if (!Directory.Exists(files.CallDirectory)) throw new DirectoryNotFoundException(files.CallDirectory);
        if (File.Exists(files.MicFinal) || File.Exists(files.SystemFinal) || Directory.Exists(files.Folder))
        {
            throw new InvalidOperationException($"{files.CallDirectory} already holds a recording.");
        }
    }

    private static Action<string> CreateLog(string? path)
    {
        if (path is null) return _ => { };
        object gate = new();
        return message =>
        {
            lock (gate)
            {
                try
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                    File.AppendAllText(path, $"{DateTimeOffset.Now:O} {message}{Environment.NewLine}");
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    // The log is only a diagnostic: a recording must never fail because of it.
                }
            }
        };
    }

    private sealed class Active(SessionFiles files, DateTimeOffset startedWall, double startedClock)
    {
        public SessionFiles Files { get; } = files;
        public DateTimeOffset StartedWall { get; } = startedWall;
        public double StartedClock { get; } = startedClock;
        public TrackRecorder? Mic { get; set; }
        public TrackRecorder? System { get; set; }
        public RecordingWatch? Watch { get; set; }
        public Timer? Timer { get; set; }
        public bool JournalStale { get; set; } = true;
    }
}
