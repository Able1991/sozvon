using Sozvon.Audio.Capture;

namespace Sozvon.Audio.Tracks;

/// <summary>The latest state of a track, read by the level timer.</summary>
internal readonly record struct TrackMeter(float Rms, double? LastPacketAt);

/// <summary>
/// One track from start to stop: reads packets on its own thread, places them on the shared clock, fills the time
/// without packets with silence and moves to a new device when the default one changes or disappears.
/// </summary>
internal sealed class TrackRecorder
{
    /// <summary>Packets reach us well within this; only time older than it is known to have no packets.</summary>
    internal const double IdleMarginSeconds = 0.25;

    private const double ReopenIntervalSeconds = 1;
    private const int PollMilliseconds = 10;
    private const int NoReopen = 0;
    private const int ReopenIfChanged = 1;
    private const int ReopenAlways = 2;

    private readonly string _name;
    private readonly int _channels;
    private readonly Func<ICaptureDevices> _devicesFactory;
    private readonly TrackSpool _spool;
    private readonly Action<string> _log;
    private readonly Action<Exception> _failed;
    private readonly Func<double> _clock;
    private readonly bool _settlesAtStart;
    private readonly TrackTimeline _timeline = new(RecordingFormat.SampleRate);
    private StartupSettler? _settler;
    private readonly TaskCompletionSource<EndpointUnavailableException?> _firstOpen = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource _finished = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly object _meterLock = new();

    private ICaptureDevices? _devices;
    private ICaptureEndpoint? _endpoint;
    private float[] _buffer = new float[RecordingFormat.SampleRate];
    private TrackMeter _meter;
    private double _startedAt;
    private double _nextOpenAt;
    private double _stopAt;
    private double _publishedOrigin = double.NaN;
    private string? _lastOpenError;
    private bool _triedOpen;
    private bool _started;
    private int _reopen;
    private volatile bool _stopping;

    public TrackRecorder(string name, int channels, Func<ICaptureDevices> devicesFactory, TrackSpool spool,
        Action<string> log, Action<Exception> failed, Func<double> clock, bool settlesAtStart)
    {
        _settlesAtStart = settlesAtStart;
        _name = name;
        _channels = channels;
        _devicesFactory = devicesFactory;
        _spool = spool;
        _log = log;
        _failed = failed;
        _clock = clock;
    }

    /// <summary>The result of the first attempt to open the device: null when it opened.</summary>
    public Task<EndpointUnavailableException?> FirstOpen => _firstOpen.Task;

    /// <summary>Read from other threads, so published as a single atomic double.</summary>
    public double? Origin
    {
        get
        {
            double origin = Volatile.Read(ref _publishedOrigin);
            return double.IsNaN(origin) ? null : origin;
        }
    }

    public bool IsRaw { get; private set; }

    public TrackMeter Meter
    {
        get
        {
            lock (_meterLock) return _meter;
        }
    }

    public void Start()
    {
        _started = true;
        var thread = new Thread(Run) { IsBackground = true, Name = $"Sozvon {_name}", Priority = ThreadPriority.AboveNormal };
        thread.SetApartmentState(ApartmentState.MTA);
        thread.Start();
    }

    /// <summary>Opens the capture again even on the same device (a source that went silent).</summary>
    public void Recapture() => Interlocked.Exchange(ref _reopen, ReopenAlways);

    /// <summary>Ends the track at a clock time and closes its file.</summary>
    public Task StopAsync(double stopAt)
    {
        if (!_started) return _spool.CloseAsync();
        _stopAt = stopAt;
        _stopping = true;
        return _finished.Task;
    }

    private void Run()
    {
        try
        {
            Prepare();
            while (!_stopping)
            {
                Step();
                Thread.Sleep(PollMilliseconds);
            }
            Finish(_stopAt);
        }
        catch (Exception ex)
        {
            _log($"{_name}: capture thread failed: {ex}");
            _firstOpen.TrySetResult(new EndpointUnavailableException(ex.Message, accessDenied: false, ex));
            _failed(ex);
        }
        finally
        {
            Release();
            _spool.CloseAsync().ContinueWith(_ => _finished.TrySetResult(), TaskScheduler.Default);
        }
    }

    internal void Prepare()
    {
        _devices = _devicesFactory();
        _devices.DefaultChanged += () => Interlocked.CompareExchange(ref _reopen, ReopenIfChanged, NoReopen);
        _startedAt = _clock();
    }

    internal void Step()
    {
        double now = _clock();
        EnsureEndpoint(now);
        Drain(now);
        if (now - _startedAt >= IdleMarginSeconds) _timeline.SetOrigin(_startedAt);
        _spool.WriteSilence(_timeline.FillTo(now - IdleMarginSeconds));
        PublishOrigin();
    }

    internal void Finish(double stopAt)
    {
        Drain(_clock());
        _timeline.SetOrigin(_startedAt);
        _spool.WriteSilence(_timeline.FillTo(stopAt - TrackTimeline.HoleSeconds));
        PublishOrigin();
        _endpoint?.Dispose();
        _endpoint = null;
    }

    private void PublishOrigin()
    {
        if (_timeline.Origin is double origin) Volatile.Write(ref _publishedOrigin, origin);
    }

    internal void Release()
    {
        _endpoint?.Dispose();
        _endpoint = null;
        _devices?.Dispose();
        _devices = null;
    }

    internal double WrittenSeconds => _timeline.WrittenSeconds;

    private void EnsureEndpoint(double now)
    {
        int reopen = Interlocked.Exchange(ref _reopen, NoReopen);
        if (_endpoint is not null && reopen == NoReopen) return;
        if (_endpoint is not null && reopen == ReopenIfChanged && _devices!.DefaultDeviceId() == _endpoint.DeviceId) return;
        if (now < _nextOpenAt)
        {
            Interlocked.CompareExchange(ref _reopen, reopen, NoReopen);
            return;
        }

        try
        {
            ICaptureEndpoint fresh = _devices!.Open();
            if (_endpoint is not null)
            {
                // The new stream runs before the old one closes, so a slow open loses nothing; the overlap is cut.
                Drain(now);
                _endpoint.Dispose();
            }
            _endpoint = fresh;
            _settler = _settlesAtStart ? new StartupSettler(RecordingFormat.SampleRate) : null;
            IsRaw = fresh.IsRaw;
            _lastOpenError = null;
            _log($"{_name}: capturing {fresh.DeviceId}, raw {fresh.IsRaw}");
            ReportFirstOpen(null);
        }
        catch (EndpointUnavailableException ex)
        {
            _nextOpenAt = now + ReopenIntervalSeconds;
            Interlocked.CompareExchange(ref _reopen, reopen, NoReopen);
            if (ex.Message != _lastOpenError) _log($"{_name}: {ex.Message}");
            _lastOpenError = ex.Message;
            ReportFirstOpen(ex);
        }
    }

    private void ReportFirstOpen(EndpointUnavailableException? error)
    {
        if (_triedOpen) return;
        _triedOpen = true;
        _firstOpen.TrySetResult(error);
    }

    private void Drain(double now)
    {
        if (_endpoint is null) return;
        try
        {
            while (_endpoint.TryRead(ref _buffer, out CapturePacket packet))
            {
                if (packet.Frames > 0 && (_settler?.Accept(packet.StartSeconds, packet.Frames) ?? true)) Store(packet, now);
            }
        }
        catch (EndpointLostException ex)
        {
            _log($"{_name}: device lost: {ex.Message}");
            _endpoint.Dispose();
            _endpoint = null;
            _nextOpenAt = now;
        }
    }

    private void Store(CapturePacket packet, double now)
    {
        Placement placement = _timeline.Place(packet.StartSeconds, packet.Frames, now);
        _spool.WriteSilence(placement.SilenceFrames);

        int frames = FrameSlip.Apply(ref _buffer, packet.Frames, _channels, placement.Slip);
        var samples = new ReadOnlySpan<float>(_buffer, 0, frames * _channels);
        _spool.Write(samples[(placement.SkipFrames * _channels)..]);

        float rms = Rms(samples);
        lock (_meterLock) _meter = new TrackMeter(rms, now);
    }

    private static float Rms(ReadOnlySpan<float> samples)
    {
        double sum = 0;
        foreach (float s in samples) sum += s * s;
        return (float)Math.Sqrt(sum / samples.Length);
    }
}
