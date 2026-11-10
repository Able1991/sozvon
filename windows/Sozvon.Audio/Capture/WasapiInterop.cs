using System.Runtime.InteropServices;

namespace Sozvon.Audio.Capture;

internal enum EDataFlow { Render = 0, Capture = 1 }

internal enum ERole { Console = 0, Multimedia = 1, Communications = 2 }

[StructLayout(LayoutKind.Sequential)]
internal struct PropertyKey(Guid formatId, uint propertyId)
{
    public Guid FormatId = formatId;
    public uint PropertyId = propertyId;
}

[StructLayout(LayoutKind.Explicit, Size = 24)]
internal struct PropVariant
{
    public const ushort VtBool = 11;

    [FieldOffset(0)] public ushort ValueType;
    [FieldOffset(8)] public short BoolValue;
}

[StructLayout(LayoutKind.Sequential)]
internal struct AudioClientProperties
{
    public uint Size;
    public int IsOffload;
    public int Category;
    public int Options;
}

[StructLayout(LayoutKind.Sequential, Pack = 1)]
internal struct WaveFormatExtensible
{
    public ushort FormatTag;
    public ushort Channels;
    public uint SamplesPerSecond;
    public uint AverageBytesPerSecond;
    public ushort BlockAlign;
    public ushort BitsPerSample;
    public ushort ExtraSize;
    public ushort ValidBitsPerSample;
    public uint ChannelMask;
    public Guid SubFormat;
}

[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
internal class MMDeviceEnumeratorComObject;

[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMMDeviceEnumerator
{
    void EnumAudioEndpoints(EDataFlow flow, uint stateMask, out IMMDeviceCollection devices);

    void GetDefaultAudioEndpoint(EDataFlow flow, ERole role, out IMMDevice device);

    void GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);

    void RegisterEndpointNotificationCallback(IMMNotificationClient client);

    void UnregisterEndpointNotificationCallback(IMMNotificationClient client);
}

[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMMDevice
{
    void Activate(ref Guid iid, uint context, IntPtr parameters, [MarshalAs(UnmanagedType.IUnknown)] out object instance);

    void OpenPropertyStore(uint access, out IPropertyStore properties);

    void GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);

    void GetState(out uint state);
}

[ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IPropertyStore
{
    void GetCount(out uint count);

    void GetAt(uint index, out PropertyKey key);

    void GetValue(ref PropertyKey key, out PropVariant value);
}

[ComImport, Guid("7991EEC9-7E89-4D85-8390-6C703CEC60C0"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMMNotificationClient
{
    void OnDeviceStateChanged([MarshalAs(UnmanagedType.LPWStr)] string id, uint state);

    void OnDeviceAdded([MarshalAs(UnmanagedType.LPWStr)] string id);

    void OnDeviceRemoved([MarshalAs(UnmanagedType.LPWStr)] string id);

    void OnDefaultDeviceChanged(EDataFlow flow, ERole role, [MarshalAs(UnmanagedType.LPWStr)] string? id);

    void OnPropertyValueChanged([MarshalAs(UnmanagedType.LPWStr)] string id, PropertyKey key);
}

[ComImport, Guid("726778CD-F60A-4EDA-82DE-E47610CD78AA"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAudioClient2
{
    void Initialize(int shareMode, uint streamFlags, long bufferDuration, long periodicity,
        ref WaveFormatExtensible format, IntPtr sessionGuid);

    void GetBufferSize(out uint frames);

    void GetStreamLatency(out long latency);

    void GetCurrentPadding(out uint frames);

    void IsFormatSupported(int shareMode, IntPtr format, out IntPtr closest);

    void GetMixFormat(out IntPtr format);

    void GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);

    void Start();

    void Stop();

    void Reset();

    void SetEventHandle(IntPtr handle);

    void GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object service);

    void IsOffloadCapable(int category, out int capable);

    void SetClientProperties(ref AudioClientProperties properties);
}

[ComImport, Guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAudioCaptureClient
{
    [PreserveSig]
    int GetBuffer(out IntPtr data, out uint frames, out uint flags, out ulong devicePosition, out ulong qpcPosition);

    [PreserveSig]
    int ReleaseBuffer(uint frames);

    [PreserveSig]
    int GetNextPacketSize(out uint frames);
}

[ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMMDeviceCollection
{
    void GetCount(out uint count);

    void Item(uint index, out IMMDevice device);
}

[ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAudioSessionManager2
{
    void GetAudioSessionControl(IntPtr sessionGuid, uint flags, out IntPtr control);

    void GetSimpleAudioVolume(IntPtr sessionGuid, uint flags, out IntPtr volume);

    void GetSessionEnumerator(out IAudioSessionEnumerator sessions);
}

[ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAudioSessionEnumerator
{
    void GetCount(out int count);

    void GetSession(int index, [MarshalAs(UnmanagedType.IUnknown)] out object session);
}

/// <summary>IAudioSessionControl and its extension in one: COM interop needs the base methods listed first.</summary>
[ComImport, Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAudioSessionControl2
{
    void GetState(out int state);

    void GetDisplayName(IntPtr name);

    void SetDisplayName(IntPtr name, IntPtr context);

    void GetIconPath(IntPtr path);

    void SetIconPath(IntPtr path, IntPtr context);

    void GetGroupingParam(IntPtr grouping);

    void SetGroupingParam(IntPtr grouping, IntPtr context);

    void RegisterAudioSessionNotification(IntPtr events);

    void UnregisterAudioSessionNotification(IntPtr events);

    void GetSessionIdentifier(IntPtr id);

    void GetSessionInstanceIdentifier(IntPtr id);

    /// <summary>AUDCLNT_S_NO_SINGLE_PROCESS (a success code) still gives the process that created the session.</summary>
    [PreserveSig]
    int GetProcessId(out uint processId);

    /// <summary>S_OK for the system sounds session, S_FALSE otherwise.</summary>
    [PreserveSig]
    int IsSystemSoundsSession();
}
