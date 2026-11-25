using System.Buffers;
using System.Buffers.Binary;
using System.Runtime.InteropServices;
using System.Threading.Channels;
using Microsoft.Win32.SafeHandles;

namespace Sozvon.Audio.Tracks;

/// <summary>Writes bytes at an offset of the spool file; replaced in tests to make the disk fail.</summary>
internal delegate void SpoolWrite(SafeFileHandle file, ReadOnlySpan<byte> bytes, long offset);

/// <summary>
/// The track as a float WAV, written while recording so a crash loses at most the last second. The capture thread
/// only queues: a slow disk must never make it miss packets. The header gives the streaming size 0xFFFFFFFF, which
/// decoders read as "until the end of the file": it needs no fixing after a crash and has no 4 GB limit.
/// <para>
/// Every block goes to its own place in the file, as on the Mac (TrackWriter): a write that fails (a full disk, a drive
/// that went away for a moment) loses that block only, and the writer goes on trying. What could not be written stays
/// a hole of silence (Windows reads a part of a file never written as zeros), so everything after it keeps its time and
/// the tracks stay in step. Silence itself is never written: the file is extended over it.
/// </para>
/// </summary>
internal sealed class TrackSpool
{
    public const int HeaderBytes = 44;

    private const int BatchBytes = 256 * 1024;
    private static readonly TimeSpan s_batchInterval = TimeSpan.FromSeconds(0.5);
    private static readonly TimeSpan s_flushInterval = TimeSpan.FromSeconds(5);

    private readonly Channel<Chunk> _chunks = Channel.CreateUnbounded<Chunk>(new UnboundedChannelOptions { SingleReader = true });
    private readonly SafeFileHandle _file;
    private readonly Action<Exception?> _written;
    private readonly SpoolWrite _write;
    private readonly Task _writer;
    private readonly int _channels;
    private readonly byte[] _batch = new byte[BatchBytes];
    private int _batchCount;

    /// <summary>Where the batch goes in the file, and the end of everything queued so far.</summary>
    private long _batchOffset = HeaderBytes;

    private long _end = HeaderBytes;
    private bool _failing;

    /// <param name="written">
    /// Told only when writing changes: the error of the first write that fails, then null at the first that works
    /// again. Called on the writer's thread.
    /// </param>
    public TrackSpool(string path, int sampleRate, int channels, Action<Exception?> written)
        : this(path, sampleRate, channels, written, RandomAccess.Write)
    {
    }

    internal TrackSpool(string path, int sampleRate, int channels, Action<Exception?> written, SpoolWrite write)
    {
        _channels = channels;
        _written = written;
        _write = write;
        _file = File.OpenHandle(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read);
        Span<byte> header = stackalloc byte[HeaderBytes];
        FillHeader(header, sampleRate, channels);
        Attempt(header, 0);
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
        DateTime nextBatch = DateTime.UtcNow + s_batchInterval;
        DateTime nextFlush = DateTime.UtcNow + s_flushInterval;
        await foreach (Chunk chunk in _chunks.Reader.ReadAllAsync().ConfigureAwait(false))
        {
            Store(chunk);
            DateTime now = DateTime.UtcNow;
            if (now >= nextBatch)
            {
                WriteBatch();
                nextBatch = now + s_batchInterval;
            }
            if (now >= nextFlush)
            {
                Guarded(() => RandomAccess.FlushToDisk(_file));
                nextFlush = now + s_flushInterval;
            }
        }
        WriteBatch();
        // Silence at the very end was never written: the file reaches the end of the track all the same.
        Guarded(() => RandomAccess.SetLength(_file, _end));
        Guarded(() => RandomAccess.FlushToDisk(_file));
        _file.Dispose();
    }

    private void Store(Chunk chunk)
    {
        long bytes = chunk.Count * RecordingFormat.BytesPerSample;
        if (chunk.Samples is null)
        {
            WriteBatch();
            _end += bytes;
            _batchOffset = _end;
            return;
        }
        ReadOnlySpan<byte> data = MemoryMarshal.AsBytes(chunk.Samples.AsSpan(0, (int)chunk.Count));
        while (!data.IsEmpty)
        {
            int n = Math.Min(data.Length, _batch.Length - _batchCount);
            data[..n].CopyTo(_batch.AsSpan(_batchCount));
            _batchCount += n;
            _end += n;
            data = data[n..];
            if (_batchCount == _batch.Length) WriteBatch();
        }
        ArrayPool<float>.Shared.Return(chunk.Samples);
    }

    /// <summary>The batch goes to its place; when that fails it is lost and becomes silence, and the next one is tried.</summary>
    private void WriteBatch()
    {
        if (_batchCount > 0) Attempt(_batch.AsSpan(0, _batchCount), _batchOffset);
        _batchCount = 0;
        _batchOffset = _end;
    }

    private void Attempt(ReadOnlySpan<byte> bytes, long offset)
    {
        try
        {
            _write(_file, bytes, offset);
            Succeeded();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Fail(ex);
        }
    }

    private void Guarded(Action action)
    {
        try
        {
            action();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Fail(ex);
        }
    }

    private void Succeeded()
    {
        if (!_failing) return;
        _failing = false;
        Tell(null);
    }

    private void Fail(Exception ex)
    {
        if (_failing) return;
        _failing = true;
        Tell(ex);
    }

    private void Tell(Exception? error)
    {
        try
        {
            _written(error);
        }
        catch (Exception)
        {
            // The listener's problem must not end the writing.
        }
    }

    /// <summary>True: no space left on the drive (ERROR_DISK_FULL, ERROR_HANDLE_DISK_FULL).</summary>
    internal static bool IsDiskFull(Exception error) => (error.HResult & 0xFFFF) is 112 or 39;

    private readonly record struct Chunk(float[]? Samples, long Count);
}
