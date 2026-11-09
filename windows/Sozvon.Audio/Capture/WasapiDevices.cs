using System.Runtime.InteropServices;

namespace Sozvon.Audio.Capture;

internal enum CaptureKind { Microphone, Loopback }

/// <summary>The default console device of one direction, followed through its changes.</summary>
internal sealed class WasapiDevices : ICaptureDevices
{
    private const int EAccessDenied = unchecked((int)0x80070005);
    private const uint StgmRead = 0;

    // System.Devices.AudioDevice.RawProcessingSupported
    private static PropertyKey s_rawSupported = new(new Guid("8943B373-388C-4395-B557-BC6DBAFFAFDB"), 2);

    private readonly CaptureKind _kind;
    private readonly EDataFlow _flow;
    private readonly IMMDeviceEnumerator _enumerator;
    private readonly NotificationClient _notifications;

    public event Action? DefaultChanged;

    public WasapiDevices(CaptureKind kind)
    {
        _kind = kind;
        _flow = kind == CaptureKind.Microphone ? EDataFlow.Capture : EDataFlow.Render;
        _enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
        _notifications = new NotificationClient(_flow, () => DefaultChanged?.Invoke());
        _enumerator.RegisterEndpointNotificationCallback(_notifications);
    }

    public string? DefaultDeviceId()
    {
        try
        {
            _enumerator.GetDefaultAudioEndpoint(_flow, ERole.Console, out IMMDevice device);
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

    public ICaptureEndpoint Open()
    {
        IMMDevice? device = null;
        try
        {
            _enumerator.GetDefaultAudioEndpoint(_flow, ERole.Console, out device);
            bool loopback = _kind == CaptureKind.Loopback;
            int channels = loopback ? RecordingFormat.SystemChannels : RecordingFormat.MicChannels;
            if (!loopback && RawSupported(device))
            {
                try
                {
                    return WasapiEndpoint.Open(device, channels, loopback: false, raw: true);
                }
                catch (COMException)
                {
                    // Advertised but refused for this format: a processed microphone beats none.
                }
            }
            return WasapiEndpoint.Open(device, channels, loopback, raw: false);
        }
        catch (COMException ex)
        {
            throw new EndpointUnavailableException($"cannot open the {_kind} device: 0x{ex.HResult:X8}",
                ex.HResult == EAccessDenied, ex);
        }
        finally
        {
            if (device is not null) Marshal.ReleaseComObject(device);
        }
    }

    public void Dispose()
    {
        _enumerator.UnregisterEndpointNotificationCallback(_notifications);
        Marshal.ReleaseComObject(_enumerator);
    }

    private static bool RawSupported(IMMDevice device)
    {
        IPropertyStore? store = null;
        try
        {
            device.OpenPropertyStore(StgmRead, out store);
            store.GetValue(ref s_rawSupported, out PropVariant value);
            return value.ValueType == PropVariant.VtBool && value.BoolValue != 0;
        }
        catch (COMException)
        {
            return false;
        }
        finally
        {
            if (store is not null) Marshal.ReleaseComObject(store);
        }
    }

    /// <summary>Windows calls this on its own thread and must not be held up: it only passes the news on.</summary>
    internal sealed class NotificationClient(EDataFlow flow, Action changed) : IMMNotificationClient
    {
        public void OnDefaultDeviceChanged(EDataFlow changedFlow, ERole role, string? id)
        {
            if (changedFlow == flow && role == ERole.Console) changed();
        }

        public void OnDeviceStateChanged(string id, uint state) { }

        public void OnDeviceAdded(string id) { }

        public void OnDeviceRemoved(string id) { }

        public void OnPropertyValueChanged(string id, PropertyKey key) { }
    }
}
