namespace Sozvon.Audio.Capture;

/// <summary>A device that opens and never delivers a packet: the track becomes silence (<see cref="RecorderOptions.SilentCapture"/>).</summary>
internal sealed class SilentDevices(CaptureKind kind) : ICaptureDevices
{
    public event Action? DefaultChanged
    {
        add { }
        remove { }
    }

    public string? DefaultDeviceId() => $"silent-{kind}";

    public ICaptureEndpoint Open() => new Endpoint($"silent-{kind}");

    public void Dispose() { }

    private sealed class Endpoint(string id) : ICaptureEndpoint
    {
        public string DeviceId { get; } = id;

        public bool IsRaw => false;

        public bool TryRead(ref float[] buffer, out CapturePacket packet)
        {
            packet = default;
            return false;
        }

        public void Dispose() { }
    }
}
