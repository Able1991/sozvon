using Sozvon.Audio.Capture;
using Sozvon.Audio.Sample;
using Xunit;

namespace Sozvon.Audio.Tests;

public sealed class SampleRecorderTests : IDisposable
{
    private readonly string _folder = Directory.CreateTempSubdirectory("sozvon-sample-").FullName;

    public void Dispose() => Directory.Delete(_folder, recursive: true);

    private string FilePath => Path.Combine(_folder, "sample.wav");

    [Fact]
    public void TheWavHeaderDescribesTheSamples()
    {
        using (var wav = new WavWriter(FilePath, 48_000))
        {
            wav.Write([0f, 0.5f, -1f, 2f]);
            wav.WriteSilence(5000);
        }
        var bytes = File.ReadAllBytes(FilePath);
        Assert.Equal(44 + 2 * 5004, bytes.Length);
        Assert.Equal("RIFF", System.Text.Encoding.ASCII.GetString(bytes, 0, 4));
        Assert.Equal(bytes.Length - 8, BitConverter.ToInt32(bytes, 4));
        Assert.Equal(1, BitConverter.ToInt16(bytes, 22));
        Assert.Equal(48_000, BitConverter.ToInt32(bytes, 24));
        Assert.Equal(16, BitConverter.ToInt16(bytes, 34));
        Assert.Equal(2 * 5004, BitConverter.ToInt32(bytes, 40));
        Assert.Equal(16384, BitConverter.ToInt16(bytes, 46));
        Assert.Equal(-short.MaxValue, BitConverter.ToInt16(bytes, 48));
        Assert.Equal(short.MaxValue, BitConverter.ToInt16(bytes, 50));
    }

    [Fact]
    public async Task SilentRecordingIsAsLongAsItRan()
    {
        var recorder = new SampleRecorder(FilePath, silent: true);
        await recorder.StartAsync();
        await Task.Delay(300);
        await recorder.StopAsync();
        var seconds = (new FileInfo(FilePath).Length - 44) / 2.0 / RecordingFormat.SampleRate;
        Assert.InRange(seconds, 0.2, recorder.Elapsed.TotalSeconds + 0.01);
        Assert.Null(recorder.Failure);
    }

    [Fact]
    public async Task PacketsAreWrittenAndGiveALevel()
    {
        var device = new OnePacketDevices(0.5f, 4800);
        var recorder = new SampleRecorder(FilePath, () => device);
        await recorder.StartAsync();
        await Task.Delay(200);
        Assert.Equal(0.5, recorder.TakeRms(), 3);
        Assert.Equal(0, recorder.TakeRms());
        await recorder.StopAsync();
        Assert.Equal(44 + 2 * 4800, new FileInfo(FilePath).Length);
        Assert.True(device.Disposed);
    }

    [Fact]
    public async Task ARefusedMicrophoneSaysSo()
    {
        var recorder = new SampleRecorder(FilePath, () => throw new EndpointUnavailableException("denied", accessDenied: true));
        var error = await Assert.ThrowsAsync<RecorderStartException>(recorder.StartAsync);
        Assert.True(error.AccessDenied);
        await recorder.StopAsync();
    }

    private sealed class OnePacketDevices(float value, int frames) : ICaptureDevices, ICaptureEndpoint
    {
        private bool _sent;

        public event Action? DefaultChanged
        {
            add { }
            remove { }
        }

        public bool Disposed { get; private set; }

        public string DeviceId => "fake";

        public bool IsRaw => false;

        public string? DefaultDeviceId() => DeviceId;

        public ICaptureEndpoint Open() => this;

        public bool TryRead(ref float[] buffer, out CapturePacket packet)
        {
            packet = default;
            if (_sent) return false;
            _sent = true;
            if (buffer.Length < frames) buffer = new float[frames];
            Array.Fill(buffer, value, 0, frames);
            packet = new CapturePacket(frames, 0);
            return true;
        }

        public void Dispose() => Disposed = true;
    }
}
