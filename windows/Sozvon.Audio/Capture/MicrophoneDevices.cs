using System.Runtime.InteropServices;

namespace Sozvon.Audio.Capture;

/// <summary>
/// The microphone the call uses, which need not be the default one: a call app set to a particular microphone, or the
/// default communications microphone when it differs from the default. Windows tells which programs capture from
/// which microphone (their sound sessions), so the track follows the microphone another program captures from right
/// now. The default wins whenever another program uses it too. Once the call has been followed to a microphone, the
/// track stays on it while the call app pauses its capture (some stop it while muted), as long as it is plugged in.
/// </summary>
internal sealed class MicrophoneDevices : ICaptureDevices
{
    private const uint DeviceStateActive = 1;
    private static readonly TimeSpan s_rescan = TimeSpan.FromSeconds(3);

    private readonly IMMDeviceEnumerator _enumerator;
    private readonly WasapiDevices.NotificationClient _notifications;
    private readonly Timer _timer;
    private readonly object _gate = new();
    private readonly int _ownProcess = Environment.ProcessId;
    private string? _target;
    private string? _followed;
    private bool _disposed;

    public event Action? DefaultChanged;

    public MicrophoneDevices()
    {
        _enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
        (_target, _followed) = SafeScan(followed: null);
        // Windows calls back on its own thread, which must not wait for the session scan.
        _notifications = new WasapiDevices.NotificationClient(EDataFlow.Capture, () => ThreadPool.QueueUserWorkItem(_ => Refresh()),
            anyRole: true);
        _enumerator.RegisterEndpointNotificationCallback(_notifications);
        // A call app opens its microphone without telling anyone: its session shows up within a few seconds.
        _timer = new Timer(_ => Refresh(), null, s_rescan, s_rescan);
    }

    public string? DefaultDeviceId()
    {
        lock (_gate) return _target;
    }

    public ICaptureEndpoint Open()
    {
        string? target = DefaultDeviceId();
        IMMDevice? device = null;
        try
        {
            if (target is null) _enumerator.GetDefaultAudioEndpoint(EDataFlow.Capture, ERole.Console, out device);
            else _enumerator.GetDevice(target, out device);
            return WasapiDevices.OpenMicrophone(device);
        }
        catch (COMException ex)
        {
            throw new EndpointUnavailableException($"cannot open the microphone: 0x{ex.HResult:X8}",
                ex.HResult == WasapiDevices.EAccessDenied, ex);
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

    /// <summary>The microphone to record; null: the default, whatever it is when the stream opens.</summary>
    /// <param name="capturing">Microphones another program captures from right now.</param>
    /// <param name="present">Microphones that are plugged in and on.</param>
    /// <param name="followed">The microphone other than the default the call was last followed to.</param>
    internal static string? Choose(string? defaultId, string? communicationsId, IReadOnlyList<string> capturing,
        IReadOnlyCollection<string> present, string? followed)
    {
        if (defaultId is not null && capturing.Contains(defaultId)) return defaultId;
        if (communicationsId is not null && capturing.Contains(communicationsId)) return communicationsId;
        if (capturing.Count > 0) return capturing[0];
        if (followed is not null && present.Contains(followed)) return followed;
        return defaultId;
    }

    /// <returns>The microphone to record, and the one other than the default it follows the call to.</returns>
    private (string? Target, string? Followed) SafeScan(string? followed)
    {
        try
        {
            return Scan(followed);
        }
        catch (Exception ex) when (ex is COMException or InvalidCastException)
        {
            lock (_gate) return (_target, followed);
        }
    }

    private void Refresh()
    {
        string? followed;
        lock (_gate) followed = _followed;
        (string? target, followed) = SafeScan(followed);
        bool changed;
        lock (_gate)
        {
            if (_disposed) return;
            changed = target != _target;
            _target = target;
            _followed = followed;
        }
        if (changed) DefaultChanged?.Invoke();
    }

    private (string? Target, string? Followed) Scan(string? followed)
    {
        var present = new List<string>();
        var capturing = new List<string>();
        IMMDeviceCollection? devices = null;
        try
        {
            _enumerator.EnumAudioEndpoints(EDataFlow.Capture, DeviceStateActive, out devices);
            devices.GetCount(out uint count);
            for (uint i = 0; i < count; i++)
            {
                devices.Item(i, out IMMDevice device);
                try
                {
                    device.GetId(out string id);
                    present.Add(id);
                    var processes = new HashSet<int>();
                    CaptureSessions.AddActive(device, processes);
                    processes.Remove(_ownProcess);
                    if (processes.Count > 0) capturing.Add(id);
                }
                catch (COMException)
                {
                    // A microphone unplugged in the middle of the scan.
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
        string? defaultId = DefaultId(ERole.Console);
        string? target = Choose(defaultId, DefaultId(ERole.Communications), capturing, present, followed);
        return (target, target != defaultId ? target : null);
    }

    private string? DefaultId(ERole role)
    {
        try
        {
            _enumerator.GetDefaultAudioEndpoint(EDataFlow.Capture, role, out IMMDevice device);
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
}
