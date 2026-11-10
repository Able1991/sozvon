using Sozvon.Audio.Capture;
using Sozvon.Audio.Tracks;
using Xunit;

namespace Sozvon.Audio.Tests;

public sealed class TrackRecorderTests : IDisposable
{
    private const int Rate = RecordingFormat.SampleRate;

    private readonly string _folder = Directory.CreateTempSubdirectory("sozvon-track-").FullName;
    private readonly FakeDevices _devices = new();
    private readonly List<Exception> _failures = [];
    private double _now = 1000;

    public void Dispose() => Directory.Delete(_folder, recursive: true);

    [Fact]
    public async Task ALoopbackWithNoPacketsStaysContinuousToTheStop()
    {
        var (track, spool, wav) = Create();
        track.Prepare();

        for (int i = 0; i < 100; i++)
        {
            _now += 0.1;
            track.Step();
        }
        track.Finish(_now);
        track.Release();
        await spool.CloseAsync();

        Assert.Equal(1000.0, track.Origin);
        Assert.Equal(10.0, track.WrittenSeconds, 1);
        Assert.All(ReadSamples(wav), s => Assert.Equal(0f, s));
        Assert.Equal((long)Math.Round(track.WrittenSeconds * Rate), ReadSamples(wav).Length);
    }

    [Fact]
    public async Task SilenceBetweenPacketsKeepsLaterAudioInItsPlace()
    {
        var (track, spool, wav) = Create();
        track.Prepare();
        _devices.Endpoint.Enqueue(frames: 4800, start: 1000.0, value: 0.5f);
        _now = 1000.1;
        track.Step();

        _now = 1002.0;
        track.Step();

        _devices.Endpoint.Enqueue(frames: 4800, start: 1002.1, value: 0.25f);
        _now = 1002.2;
        track.Step();
        track.Finish(1002.2);
        track.Release();
        await spool.CloseAsync();

        float[] samples = ReadSamples(wav);
        Assert.Equal(0.5f, samples[0]);
        Assert.Equal(0f, samples[(int)(1.0 * Rate)]);
        Assert.Equal(0.25f, samples[(int)(2.1 * Rate) + 10]);
        Assert.Equal((int)(2.2 * Rate), samples.Length);
    }

    [Fact]
    public async Task AChangeOfDefaultDeviceContinuesTheTrackAndCutsTheOverlap()
    {
        var (track, spool, wav) = Create();
        track.Prepare();
        _devices.Endpoint.Enqueue(frames: Rate, start: 1000.0, value: 0.5f);
        _now = 1001.0;
        track.Step();

        FakeEndpoint first = _devices.Endpoint;
        _devices.SwitchDefault();
        _devices.Endpoint.Enqueue(frames: Rate, start: 1000.8, value: 0.25f);
        _now = 1001.9;
        track.Step();
        track.Finish(1001.9);
        track.Release();
        await spool.CloseAsync();

        Assert.True(first.Disposed);
        float[] samples = ReadSamples(wav);
        Assert.Equal(0.5f, samples[Rate - 1]);
        Assert.Equal(0.25f, samples[Rate]);
        Assert.Equal((int)Math.Round((1.9 - TrackTimeline.HoleSeconds) * Rate), samples.Length);
    }

    [Fact]
    public async Task ANoticeForTheSameDefaultDeviceKeepsTheStream()
    {
        var (track, spool, _) = Create();
        track.Prepare();
        track.Step();
        FakeEndpoint first = _devices.Endpoint;

        _devices.NotifyDefaultChanged();
        _now += 0.1;
        track.Step();
        Assert.Equal(1, first.Opened);
        Assert.False(first.Disposed);
        track.Release();
        await spool.CloseAsync();
    }

    [Fact]
    public async Task ANewDefaultThatWillNotOpenYetKeepsTheOldStreamUntilItDoes()
    {
        var (track, spool, wav) = Create();
        track.Prepare();
        _devices.Endpoint.Enqueue(frames: Rate, start: 1000.0, value: 0.5f);
        _now = 1001.0;
        track.Step();
        FakeEndpoint first = _devices.Endpoint;

        // The new headset is the default now but refuses the stream for a moment (it is still starting up).
        _devices.SwitchDefault();
        _devices.Available = false;
        first.Enqueue(frames: Rate / 2, start: 1001.0, value: 0.25f);
        _now = 1001.5;
        track.Step();
        Assert.False(first.Disposed);

        _devices.Available = true;
        _now = 1002.0;
        track.Step();
        Assert.False(first.Disposed);
        _now = 1002.6;
        track.Step();
        Assert.True(first.Disposed);
        track.Finish(1002.6);
        track.Release();
        await spool.CloseAsync();

        float[] samples = ReadSamples(wav);
        Assert.Equal(0.25f, samples[Rate + 10]);
        Assert.Equal(0f, samples[(int)(1.5 * Rate) + 10]);
    }

    [Fact]
    public async Task ALostDeviceIsReopenedAndTheHoleIsFilled()
    {
        var (track, spool, wav) = Create();
        track.Prepare();
        _devices.Endpoint.Enqueue(frames: Rate, start: 1000.0, value: 0.5f);
        _now = 1001.0;
        track.Step();

        FakeEndpoint lost = _devices.Endpoint;
        lost.Lose = true;
        _devices.Available = false;
        _now = 1001.5;
        track.Step();
        Assert.True(lost.Disposed);

        _now = 1002.0;
        track.Step();

        _devices.Available = true;
        _devices.NewEndpoint();
        _now = 1003.0;
        track.Step();
        _devices.Endpoint.Enqueue(frames: Rate, start: 1003.0, value: 0.25f);
        _now = 1004.0;
        track.Step();
        track.Finish(1004.0);
        track.Release();
        await spool.CloseAsync();

        float[] samples = ReadSamples(wav);
        Assert.Equal(0f, samples[(int)(1.5 * Rate)]);
        Assert.Equal(0.25f, samples[3 * Rate + 10]);
        Assert.Equal(4 * Rate, samples.Length);
    }

    [Fact]
    public async Task FirstOpenReportsAnUnavailableDevice()
    {
        var (track, spool, _) = Create();
        _devices.Available = false;
        track.Prepare();
        track.Step();
        track.Release();
        await spool.CloseAsync();

        EndpointUnavailableException? error = await track.FirstOpen;
        Assert.NotNull(error);
        Assert.True(error.AccessDenied);
    }

    [Fact]
    public async Task RecaptureOpensTheSameDeviceAgain()
    {
        var (track, spool, _) = Create();
        track.Prepare();
        track.Step();
        FakeEndpoint first = _devices.Endpoint;

        _devices.NewEndpoint(sameId: true);
        track.Recapture();
        _now += 0.1;
        track.Step();
        track.Release();
        await spool.CloseAsync();

        Assert.True(first.Disposed);
    }

    [Fact]
    public async Task BunchedTimestampsAtTheStartLeaveNoGap()
    {
        var (track, spool, wav) = Create(settlesAtStart: true);
        track.Prepare();
        double[] starts = [1000.000, 1000.047, 1000.079, 1000.126, 1000.143, 1000.153, 1000.163, 1000.173, 1000.183];
        foreach (double start in starts) _devices.Endpoint.Enqueue(frames: 480, start: start, value: 0.5f);
        _now = 1000.2;
        track.Step();
        track.Finish(1000.2);
        track.Release();
        await spool.CloseAsync();

        Assert.Equal(1000.173, track.Origin);
        float[] samples = ReadSamples(wav);
        Assert.Equal(960, samples.Length);
        Assert.All(samples, s => Assert.Equal(0.5f, s));
    }

    private (TrackRecorder Track, TrackSpool Spool, string Wav) Create(bool settlesAtStart = false)
    {
        string wav = Path.Combine(_folder, $"{Guid.NewGuid():N}.wav");
        var spool = new TrackSpool(wav, Rate, 1, _failures.Add);
        var track = new TrackRecorder("test", 1, () => _devices, spool, _ => { }, _failures.Add, () => _now, settlesAtStart);
        return (track, spool, wav);
    }

    private static float[] ReadSamples(string wav)
    {
        byte[] bytes = File.ReadAllBytes(wav);
        var samples = new float[(bytes.Length - TrackSpool.HeaderBytes) / sizeof(float)];
        Buffer.BlockCopy(bytes, TrackSpool.HeaderBytes, samples, 0, samples.Length * sizeof(float));
        return samples;
    }

    private sealed class FakeDevices : ICaptureDevices
    {
        private int _serial;

        public FakeDevices() => NewEndpoint();

        public event Action? DefaultChanged;

        public FakeEndpoint Endpoint { get; private set; } = null!;

        public bool Available { get; set; } = true;

        public void NewEndpoint(bool sameId = false)
        {
            if (!sameId) _serial++;
            Endpoint = new FakeEndpoint($"device-{_serial}");
        }

        public void SwitchDefault()
        {
            NewEndpoint();
            DefaultChanged?.Invoke();
        }

        /// <summary>Windows says the default changed although it is the same device (a role or format change).</summary>
        public void NotifyDefaultChanged() => DefaultChanged?.Invoke();

        public string? DefaultDeviceId() => Available ? Endpoint.DeviceId : null;

        public ICaptureEndpoint Open()
        {
            if (!Available) throw new EndpointUnavailableException("no device", accessDenied: true);
            Endpoint.Opened++;
            return Endpoint;
        }

        public void Dispose() { }
    }

    private sealed class FakeEndpoint(string id) : ICaptureEndpoint
    {
        private readonly Queue<(int Frames, double Start, float Value)> _packets = new();

        public string DeviceId { get; } = id;

        public bool IsRaw => false;

        public bool Disposed { get; private set; }

        public bool Lose { get; set; }

        public int Opened { get; set; }

        public void Enqueue(int frames, double start, float value) => _packets.Enqueue((frames, start, value));

        public bool TryRead(ref float[] buffer, out CapturePacket packet)
        {
            if (Lose) throw new EndpointLostException("gone");
            packet = default;
            if (!_packets.TryDequeue(out var next)) return false;
            if (buffer.Length < next.Frames) buffer = new float[next.Frames];
            Array.Fill(buffer, next.Value, 0, next.Frames);
            packet = new CapturePacket(next.Frames, next.Start);
            return true;
        }

        public void Dispose() => Disposed = true;
    }
}
