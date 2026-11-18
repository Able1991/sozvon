using System.Runtime.InteropServices;

namespace Sozvon.Audio.Capture;

/// <summary>
/// The output besides the default one where a call may play: the loopback of the default device misses it. A
/// Bluetooth headset is two devices on Windows, Stereo and Hands-Free; a call that opens its microphone plays to
/// Hands-Free, the default communications device, while the default device stays Stereo and goes quiet. A call app
/// set to a particular speaker plays there too. Only an output some program already plays to is captured: a stream
/// of ours on an idle Hands-Free device could itself switch the headset into its call mode and spoil what the user
/// hears. Nothing to capture: an endpoint that never delivers, so the track closes the stream it had and writes nothing.
/// </summary>
internal sealed class SecondOutputDevices : ICaptureDevices
{
    public const string NoneId = "none";

    private const uint DeviceStateActive = 1;
    private static readonly TimeSpan s_rescan = TimeSpan.FromSeconds(3);

    private readonly IMMDeviceEnumerator _enumerator;
    private readonly WasapiDevices.NotificationClient _notifications;
    private readonly Timer _timer;
    private readonly object _gate = new();
    private readonly int _ownProcess = Environment.ProcessId;
    private string _target = NoneId;
    private bool _disposed;

    public event Action? DefaultChanged;

    public SecondOutputDevices()
    {
        _enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
        _target = SafeScan() ?? NoneId;
        // Windows calls back on its own thread, which must not wait for the session scan.
        _notifications = new WasapiDevices.NotificationClient(EDataFlow.Render, () => ThreadPool.QueueUserWorkItem(_ => Refresh()),
            anyRole: true);
        _enumerator.RegisterEndpointNotificationCallback(_notifications);
        // A call app starts playing without telling anyone: its session shows up within a few seconds.
        _timer = new Timer(_ => Refresh(), null, s_rescan, s_rescan);
    }

    public string? DefaultDeviceId()
    {
        lock (_gate) return _target;
    }

    public ICaptureEndpoint Open()
    {
        string target = DefaultDeviceId() ?? NoneId;
        if (target == NoneId) return new NoEndpoint();
        IMMDevice? device = null;
        try
        {
            _enumerator.GetDevice(target, out device);
            return WasapiEndpoint.Open(device, RecordingFormat.SystemChannels, loopback: true, raw: false);
        }
        catch (COMException ex)
        {
            throw new EndpointUnavailableException($"cannot open the second output: 0x{ex.HResult:X8}", accessDenied: false, ex);
        }
        finally
        {
            if (device is not null) Marshal.ReleaseComObject(device);
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) return;
            _disposed = true;
        }
        _timer.Dispose();
        _enumerator.UnregisterEndpointNotificationCallback(_notifications);
        Marshal.ReleaseComObject(_enumerator);
    }

    /// <summary>
    /// The output to capture besides the default: one a program plays to right now, the communications device first.
    /// Null: nothing besides the default.
    /// </summary>
    /// <param name="playing">Outputs other than the default with a program's sound session running.</param>
    internal static string? Choose(string? defaultId, string? communicationsId, IReadOnlyList<string> playing)
    {
        var others = playing.Where(id => id != defaultId).ToList();
        if (communicationsId is not null && others.Contains(communicationsId)) return communicationsId;
        return others.Count > 0 ? others[0] : null;
    }

    private string? SafeScan()
    {
        try
        {
            return Scan();
        }
        catch (Exception ex) when (ex is COMException or InvalidCastException)
        {
            return null;
        }
    }

    private void Refresh()
    {
        if (SafeScan() is not string target) return;
        bool changed;
        lock (_gate)
        {
            if (_disposed) return;
            changed = target != _target;
            _target = target;
        }
        if (changed) DefaultChanged?.Invoke();
    }

    private string Scan()
    {
        string? defaultId = DefaultId(ERole.Console);
        string? communicationsId = DefaultId(ERole.Communications);
        return Choose(defaultId, communicationsId, Playing(defaultId)) ?? NoneId;
    }

    private string? DefaultId(ERole role)
    {
        try
        {
            _enumerator.GetDefaultAudioEndpoint(EDataFlow.Render, role, out IMMDevice device);
            try
            {
                device.GetId(out string id);
                return id;
            }
            finally
            {
                Marshal.ReleaseComObject(device);
            }
        }
        catch (COMException)
        {
            return null;
        }
    }

    /// <summary>Outputs other than the default where some program other than Sozvon has a running session.</summary>
    private List<string> Playing(string? defaultId)
    {
        var playing = new List<string>();
        IMMDeviceCollection? devices = null;
        try
        {
            _enumerator.EnumAudioEndpoints(EDataFlow.Render, DeviceStateActive, out devices);
            devices.GetCount(out uint count);
            for (uint i = 0; i < count; i++)
            {
                devices.Item(i, out IMMDevice device);
                try
                {
                    device.GetId(out string id);
                    if (id == defaultId) continue;
                    var processes = new HashSet<int>();
                    CaptureSessions.AddActive(device, processes);
                    processes.Remove(_ownProcess);
                    if (processes.Count > 0) playing.Add(id);
                }
                catch (COMException)
                {
                    // An output unplugged in the middle of the scan.
                }
                finally
                {
                    Marshal.ReleaseComObject(device);
                }
            }
        }
        finally
        {
            if (devices is not null) Marshal.ReleaseComObject(devices);
        }
        return playing;
    }

    /// <summary>No second output: a stream that never delivers, so the old one closes and nothing is written.</summary>
    private sealed class NoEndpoint : ICaptureEndpoint
    {
        public string DeviceId => NoneId;

        public bool IsRaw => false;

        public bool TryRead(ref float[] buffer, out CapturePacket packet)
        {
            packet = default;
            return false;
        }

        public void Dispose() { }
    }
}
