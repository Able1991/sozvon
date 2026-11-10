using System.Text;

namespace Sozvon.Audio.Sample;

/// <summary>A 16-bit PCM mono WAV file; the sizes in the header are filled in when it is closed.</summary>
internal sealed class WavWriter : IDisposable
{
    private const int HeaderBytes = 44;
    private readonly FileStream _file;
    private readonly int _sampleRate;
    private byte[] _bytes = [];
    private long _dataBytes;
    private bool _closed;

    public WavWriter(string path, int sampleRate)
    {
        _sampleRate = sampleRate;
        _file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read);
        WriteHeader();
    }

    public long Samples => _dataBytes / 2;

    /// <summary>Floats in −1…1, clipped, as 16-bit samples.</summary>
    public void Write(ReadOnlySpan<float> samples)
    {
        if (_bytes.Length < samples.Length * 2) _bytes = new byte[samples.Length * 2];
        for (var i = 0; i < samples.Length; i++)
        {
            var s = (short)Math.Round(Math.Clamp(samples[i], -1f, 1f) * short.MaxValue);
            _bytes[2 * i] = (byte)s;
            _bytes[2 * i + 1] = (byte)(s >> 8);
        }
        _file.Write(_bytes, 0, samples.Length * 2);
        _dataBytes += samples.Length * 2;
    }

    public void WriteSilence(int samples)
    {
        if (samples <= 0) return;
        Span<float> zeros = stackalloc float[Math.Min(samples, 4096)];
        for (var left = samples; left > 0; left -= zeros.Length)
        {
            Write(zeros[..Math.Min(left, zeros.Length)]);
        }
    }

    public void Dispose()
    {
        if (_closed) return;
        _closed = true;
        _file.Position = 0;
        WriteHeader();
        _file.Flush(flushToDisk: true);
        _file.Dispose();
    }

    private void WriteHeader()
    {
        using var w = new BinaryWriter(_file, Encoding.ASCII, leaveOpen: true);
        w.Write("RIFF"u8);
        w.Write((uint)(HeaderBytes - 8 + _dataBytes));
        w.Write("WAVE"u8);
        w.Write("fmt "u8);
        w.Write(16u);
        w.Write((ushort)1);
        w.Write((ushort)1);
        w.Write((uint)_sampleRate);
        w.Write((uint)_sampleRate * 2);
        w.Write((ushort)2);
        w.Write((ushort)16);
        w.Write("data"u8);
        w.Write((uint)_dataBytes);
    }
}
