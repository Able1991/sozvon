using System.Runtime.InteropServices;

namespace Sozvon.Audio.Capture;

/// <summary>A shared-mode capture stream, converted by Windows to the recording's fixed format.</summary>
internal sealed class WasapiEndpoint : ICaptureEndpoint
{
    private const uint ClsctxAll = 23;
    private const int ShareModeShared = 0;
    private const uint StreamFlagLoopback = 0x00020000;
    private const uint StreamFlagAutoConvertPcm = 0x80000000;
    private const uint StreamFlagSrcDefaultQuality = 0x08000000;
    private const int StreamOptionRaw = 1;
    private const uint BufferFlagSilent = 0x2;
    private const uint BufferFlagTimestampError = 0x4;
    private const int BufferEmpty = 0x08890001;
    private const long BufferDuration100Ns = 20_000_000;
    private const double QpcPositionUnitsPerSecond = 10_000_000.0;

    private static Guid s_audioClient2 = new("726778CD-F60A-4EDA-82DE-E47610CD78AA");
    private static Guid s_audioCaptureClient = new("C8ADBD64-E71E-48A0-A4DE-185C395CD317");
    private static readonly Guid s_ieeeFloat = new("00000003-0000-0010-8000-00AA00389B71");

    private readonly IAudioClient2 _client;
    private readonly IAudioCaptureClient _capture;
    private readonly int _channels;
    private bool _disposed;

    public string DeviceId { get; }

    public bool IsRaw { get; }

    private WasapiEndpoint(IAudioClient2 client, IAudioCaptureClient capture, int channels, string deviceId, bool raw)
    {
        _client = client;
        _capture = capture;
        _channels = channels;
        DeviceId = deviceId;
        IsRaw = raw;
    }

    /// <exception cref="COMException">The stream could not be opened.</exception>
    public static WasapiEndpoint Open(IMMDevice device, int channels, bool loopback, bool raw)
    {
        device.GetId(out string id);
        device.Activate(ref s_audioClient2, ClsctxAll, IntPtr.Zero, out object instance);
        var client = (IAudioClient2)instance;
        object? service = null;
        try
        {
            // The category stays "other": "communications" would ask Windows for echo cancellation.
            var properties = new AudioClientProperties
            {
                Size = (uint)Marshal.SizeOf<AudioClientProperties>(),
                Options = raw ? StreamOptionRaw : 0,
            };
            client.SetClientProperties(ref properties);

            var format = FloatFormat(channels);
            uint flags = StreamFlagAutoConvertPcm | StreamFlagSrcDefaultQuality | (loopback ? StreamFlagLoopback : 0);
            client.Initialize(ShareModeShared, flags, BufferDuration100Ns, 0, ref format, IntPtr.Zero);
            client.GetService(ref s_audioCaptureClient, out service);
            client.Start();
            return new WasapiEndpoint(client, (IAudioCaptureClient)service, channels, id, raw);
        }
        catch
        {
            if (service is not null) Marshal.ReleaseComObject(service);
            Marshal.ReleaseComObject(client);
            throw;
        }
    }

    public bool TryRead(ref float[] buffer, out CapturePacket packet)
    {
        packet = default;
        int status = _capture.GetNextPacketSize(out uint waiting);
        Check(status);
        if (waiting == 0) return false;

        status = _capture.GetBuffer(out IntPtr data, out uint frames, out uint flags, out _, out ulong qpc);
        if (status == BufferEmpty) return false;
        Check(status);
        try
        {
            int samples = checked((int)frames * _channels);
            if (buffer.Length < samples) buffer = new float[samples * 2];
            if ((flags & BufferFlagSilent) != 0) Array.Clear(buffer, 0, samples);
            else Marshal.Copy(data, buffer, 0, samples);
            double start = (flags & BufferFlagTimestampError) != 0 || qpc == 0
                ? double.NaN
                : qpc / QpcPositionUnitsPerSecond;
            packet = new CapturePacket((int)frames, start);
            return true;
        }
        finally
        {
            Check(_capture.ReleaseBuffer(frames));
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        try
        {
            _client.Stop();
        }
        catch (COMException)
        {
            // The device is already gone: there is nothing left to stop.
        }
        Marshal.ReleaseComObject(_capture);
        Marshal.ReleaseComObject(_client);
    }

    private static void Check(int status)
    {
        if (status < 0) throw new EndpointLostException($"capture failed, HRESULT 0x{status:X8}", Marshal.GetExceptionForHR(status));
    }

    private static WaveFormatExtensible FloatFormat(int channels)
    {
        const ushort Extensible = 0xFFFE;
        const ushort Bits = 32;
        const uint SpeakerFrontCenter = 0x4;
        const uint SpeakerFrontLeftRight = 0x3;
        ushort block = (ushort)(channels * Bits / 8);
        return new WaveFormatExtensible
        {
            FormatTag = Extensible,
            Channels = (ushort)channels,
            SamplesPerSecond = RecordingFormat.SampleRate,
            AverageBytesPerSecond = RecordingFormat.SampleRate * (uint)block,
            BlockAlign = block,
            BitsPerSample = Bits,
            ExtraSize = 22,
            ValidBitsPerSample = Bits,
            ChannelMask = channels == 1 ? SpeakerFrontCenter : SpeakerFrontLeftRight,
            SubFormat = s_ieeeFloat,
        };
    }
}
