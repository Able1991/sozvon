using System.Buffers;
using System.Buffers.Binary;
using System.Runtime.InteropServices;
using System.Threading.Channels;

namespace Sozvon.Audio.Tracks;

/// <summary>
/// The track as a float WAV, written while recording so a crash loses at most the last seconds. The capture thread
/// only queues: a slow disk must never make it miss packets. The header gives the streaming size 0xFFFFFFFF, which
/// decoders read as "until the end of the file": it needs no fixing after a crash and has no 4 GB limit.
/// </summary>
internal sealed class TrackSpool
{
    public const int HeaderBytes = 44;

    private static readonly TimeSpan s_flushInterval = TimeSpan.FromSeconds(5);
    private static readonly byte[] s_zeros = new byte[64 * 1024];

    private readonly Channel<Chunk> _chunks = Channel.CreateUnbounded<Chunk>(new UnboundedChannelOptions { SingleReader = true });
    private readonly FileStream _file;
    private readonly Action<Exception> _failed;
    private readonly Task _writer;
    private readonly int _channels;
    private bool _faulted;

    public TrackSpool(string path, int sampleRate, int channels, Action<Exception> failed)
    {
        _channels = channels;
        _failed = failed;
        _file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read, bufferSize: 1 << 20);
        Span<byte> header = stackalloc byte[HeaderBytes];
        FillHeader(header, sampleRate, channels);
        _file.Write(header);
        _writer = Task.Run(WriteLoopAsync);
    }

    /// <summary>Called from the capture thread.</summary>
    public void Write(ReadOnlySpan<float> samples)
    {
        if (samples.IsEmpty) return;
        float[] copy = ArrayPool<float>.Shared.Rent(samples.Length);
        samples.CopyTo(copy);
        _chunks.Writer.TryWrite(new Chunk(copy, samples.Length));
    }

    /// <summary>Called from the capture thread.</summary>
    public void WriteSilence(long frames)
    {
        if (frames > 0) _chunks.Writer.TryWrite(new Chunk(null, frames * _channels));
    }

    /// <summary>Writes what is queued and closes the file.</summary>
    public async Task CloseAsync()
    {
        _chunks.Writer.TryComplete();
        await _writer.ConfigureAwait(false);
    }

    internal static void FillHeader(Span<byte> h, int sampleRate, int channels)
    {
        const ushort IeeeFloat = 3;
        const ushort Bits = 32;
        const uint StreamingSize = 0xFFFFFFFF;
        int blockAlign = channels * RecordingFormat.BytesPerSample;

        "RIFF"u8.CopyTo(h);
        BinaryPrimitives.WriteUInt32LittleEndian(h[4..], StreamingSize);
        "WAVEfmt "u8.CopyTo(h[8..]);
        BinaryPrimitives.WriteUInt32LittleEndian(h[16..], 16);
        BinaryPrimitives.WriteUInt16LittleEndian(h[20..], IeeeFloat);
        BinaryPrimitives.WriteUInt16LittleEndian(h[22..], (ushort)channels);
        BinaryPrimitives.WriteUInt32LittleEndian(h[24..], (uint)sampleRate);
        BinaryPrimitives.WriteUInt32LittleEndian(h[28..], (uint)(sampleRate * blockAlign));
        BinaryPrimitives.WriteUInt16LittleEndian(h[32..], (ushort)blockAlign);
        BinaryPrimitives.WriteUInt16LittleEndian(h[34..], Bits);
        "data"u8.CopyTo(h[36..]);
        BinaryPrimitives.WriteUInt32LittleEndian(h[40..], StreamingSize);
    }

    private async Task WriteLoopAsync()
    {
        DateTime nextFlush = DateTime.UtcNow + s_flushInterval;
        await foreach (Chunk chunk in _chunks.Reader.ReadAllAsync().ConfigureAwait(false))
        {
            Store(chunk);
            if (DateTime.UtcNow >= nextFlush)
            {
                Guarded(() => _file.Flush(flushToDisk: true));
                nextFlush = DateTime.UtcNow + s_flushInterval;
            }
        }
        Guarded(() => _file.Flush(flushToDisk: true));
        Guarded(_file.Dispose);
    }

    private void Store(Chunk chunk)
    {
        if (chunk.Samples is null)
        {
            Guarded(() => WriteZeros(chunk.Count * RecordingFormat.BytesPerSample));
            return;
        }
        Guarded(() => _file.Write(MemoryMarshal.AsBytes(chunk.Samples.AsSpan(0, (int)chunk.Count))));
        ArrayPool<float>.Shared.Return(chunk.Samples);
    }

    private void WriteZeros(long bytes)
    {
        while (bytes > 0)
        {
            int n = (int)Math.Min(bytes, s_zeros.Length);
            _file.Write(s_zeros, 0, n);
            bytes -= n;
        }
    }

    private void Guarded(Action action)
    {
        if (_faulted) return;
        try
        {
            action();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ObjectDisposedException)
        {
            _faulted = true;
            _failed(ex);
        }
    }

    private readonly record struct Chunk(float[]? Samples, long Count);
}
