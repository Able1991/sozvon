namespace Sozvon.Audio.Capture;

/// <param name="Frames">Frames copied into the caller's buffer.</param>
/// <param name="StartSeconds">Shared clock time of the first frame, or NaN when the device gave no valid one.</param>
internal readonly record struct CapturePacket(int Frames, double StartSeconds);

/// <summary>An open stream on one device. Used from the track's capture thread only.</summary>
internal interface ICaptureEndpoint : IDisposable
{
    string DeviceId { get; }

    bool IsRaw { get; }

    /// <summary>Copies the next packet as interleaved floats, growing the buffer if needed. False when none waits.</summary>
    /// <exception cref="EndpointLostException">The device is gone; open a new endpoint.</exception>
    bool TryRead(ref float[] buffer, out CapturePacket packet);
}

/// <summary>The default device of one direction. Created and disposed on the track's capture thread.</summary>
internal interface ICaptureDevices : IDisposable
{
    /// <summary>The default device changed. May fire on any thread and must return at once.</summary>
    event Action? DefaultChanged;

    string? DefaultDeviceId();

    /// <exception cref="EndpointUnavailableException">No stream could be opened right now.</exception>
    ICaptureEndpoint Open();
}

internal sealed class EndpointLostException(string message, Exception? inner = null) : Exception(message, inner);

internal sealed class EndpointUnavailableException(string message, bool accessDenied, Exception? inner = null)
    : Exception(message, inner)
{
    public bool AccessDenied { get; } = accessDenied;
}
