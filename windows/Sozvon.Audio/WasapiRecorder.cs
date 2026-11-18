using Sozvon.Audio.Capture;
using Sozvon.Audio.Session;
using Sozvon.Audio.Tracks;

namespace Sozvon.Audio;

/// <summary>
/// The recorder over WASAPI: the microphone the call uses (<see cref="MicrophoneDevices"/>, raw where offered), the
/// loopback of the default output and of a second output where a call plays (<see cref="SecondOutputDevices"/>),
/// mixed into the other side's track at the end.
/// </summary>
public sealed class WasapiRecorder(RecorderOptions options) : IRecorder
{
    private const int LevelIntervalMilliseconds = 100;
    private const string MicName = "microphone", SystemName = "system", SecondName = "system 2";
    private static readonly TimeSpan s_stopTimeout = TimeSpan.FromSeconds(15);

    private readonly object _gate = new();
    private readonly List<double> _markTimes = [];
    private readonly Dictionary<string, double> _failedAt = [];
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
            lock (_gate)
            {
                _markTimes.Clear();
                _failedAt.Clear();
            }
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
        await Task.WhenAll(active.Tracks.Select(t => t.StopAsync(stopAt)))
            .WaitAsync(s_stopTimeout, cancellationToken).ConfigureAwait(false);

        SessionJournal journal = Journal(active, marks);
        SaveJournal(active, journal);
        RecordingResult result = await RecordingFinalizer.FinalizeAsync(active.Files, journal, marks, options.FfmpegPath,
            active.Mic!.IsRaw, cancellationToken).ConfigureAwait(false);
        _log($"saved {active.Files.CallDirectory}: mic {result.Audio.MicSeconds:F2} s, system {result.Audio.SystemSeconds:F2} s");
        return result;
    }

    /// <summary>
    /// Only a microphone Windows refuses to this app stops the start: it will not come back without the user. A missing
    /// or busy microphone or output leaves that track silent until one opens, and the capsule says so.
    /// </summary>
    private async Task OpenTracksAsync(Active active, CancellationToken cancellationToken)
    {
        try
        {
            SessionFiles files = active.Files;
            bool silent = options.SilentCapture;
            active.Mic = CreateTrack(MicName, files.MicWav, RecordingFormat.MicChannels,
                silent ? () => new SilentDevices(CaptureKind.Microphone) : () => new MicrophoneDevices(),
                settlesAtStart: true);
            active.System = CreateTrack(SystemName, files.SystemWav, RecordingFormat.SystemChannels,
                silent ? () => new SilentDevices(CaptureKind.Loopback) : () => new WasapiDevices(CaptureKind.Loopback));
            if (!silent)
            {
                active.Second = CreateTrack(SecondName, files.SecondOutputWav, RecordingFormat.SystemChannels,
                    () => new SecondOutputDevices(), anchorsAtStart: false);
            }
            foreach (TrackRecorder track in active.Tracks) track.Start();

            EndpointUnavailableException? micError = await active.Mic.FirstOpen.WaitAsync(cancellationToken).ConfigureAwait(false);
            if (micError is { AccessDenied: true }) throw new RecorderStartException(micError.Message, accessDenied: true, micError);
            if (micError is not null) _log($"microphone: not capturing yet, will keep trying: {micError.Message}");

            EndpointUnavailableException? systemError = await active.System.FirstOpen.WaitAsync(cancellationToken).ConfigureAwait(false);
            if (systemError is not null) _log($"system: not capturing yet, will keep trying: {systemError.Message}");
        }
        catch
        {
            await AbandonAsync(active).ConfigureAwait(false);
            throw;
        }
    }

    private TrackRecorder CreateTrack(string name, string wav, int channels, Func<ICaptureDevices> devices,
        bool settlesAtStart = false, bool anchorsAtStart = true)
    {
        var spool = new TrackSpool(wav, RecordingFormat.SampleRate, channels, error => ReportFailure(name, error));
        return new TrackRecorder(name, channels, devices, spool, _log, error => ReportFailure(name, error), () => SharedClock.Now,
            settlesAtStart, anchorsAtStart);
    }

    /// <summary>
    /// A track that can no longer be written is said at once and the others go on. Only when neither the user's voice
    /// nor the other side is written any more does the recording have to stop.
    /// </summary>
    private void ReportFailure(string track, Exception error)
    {
        bool bothLost;
        lock (_gate)
        {
            if (!_failedAt.TryAdd(track, SharedClock.Now)) return;
            bothLost = _failedAt.ContainsKey(MicName) && _failedAt.ContainsKey(SystemName);
        }
        _log($"{track}: cannot be written: {error.Message}");
        try
        {
            AlertRaised?.Invoke(this, new RecorderAlert(
                track == MicName ? RecorderAlertKind.MicrophoneNotWritten : RecorderAlertKind.SystemNotWritten, 0));
            if (bothLost) Failed?.Invoke(this, error);
        }
        catch (Exception ex)
        {
            _log($"telling about the failure failed: {ex}");
        }
    }

    private double? FailedAt(params string[] tracks)
    {
        lock (_gate)
        {
            foreach (string track in tracks)
            {
                if (_failedAt.TryGetValue(track, out double at)) return at;
            }
            return null;
        }
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
        // The second output's start is known only at its first packet: without it a crash could not place its sound.
        if (active.Second?.Origin is double secondOrigin && secondOrigin != active.SavedSecondOrigin)
        {
            active.SavedSecondOrigin = secondOrigin;
            SaveJournal(active);
        }

        double now = SharedClock.Now;
        TrackMeter system = active.Second is null
            ? active.System!.Meter
            : RecordingWatch.Louder(active.System!.Meter, active.Second.Meter, now);
        WatchResult result = active.Watch!.Update(now, active.Mic!.Meter, system, FailedAt(MicName), FailedAt(SystemName, SecondName));
        if (result.RecaptureMic)
        {
            _log("microphone: silent for two minutes, capturing again");
            active.Mic.Recapture();
        }
        if (result.RecaptureSystem)
        {
            _log("system: silent for two minutes, capturing again");
            active.System.Recapture();
            active.Second?.Recapture();
        }
        foreach (RecorderAlert alert in result.Alerts) AlertRaised?.Invoke(this, alert);
        LevelsChanged?.Invoke(this, result.Levels);
    }

    private void SaveJournal(Active active)
    {
        double[] marks;
        lock (_gate) marks = _markTimes.ToArray();
        SaveJournal(active, Journal(active, marks));
    }

    private static SessionJournal Journal(Active active, double[] marks) =>
        new(active.StartedWall, active.Mic?.Origin, active.System?.Origin, marks, active.Second?.Origin);

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
            await Task.WhenAll(active.Tracks.Select(t => t.StopAsync(now))).WaitAsync(s_stopTimeout).ConfigureAwait(false);
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
        public TrackRecorder? Second { get; set; }
        public double? SavedSecondOrigin { get; set; }
        public RecordingWatch? Watch { get; set; }
        public Timer? Timer { get; set; }
        public bool JournalStale { get; set; } = true;

        public IEnumerable<TrackRecorder> Tracks => new[] { Mic, System, Second }.OfType<TrackRecorder>();
    }
}
