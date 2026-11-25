using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using Sozvon.Audio.Tracks;
using Xunit;

namespace Sozvon.Audio.Tests;

/// <summary>The spool on a disk that refuses writes for a while, as a full disk does: the recording goes on, in time.</summary>
public sealed class TrackSpoolTests : IDisposable
{
    private const int Rate = 1000;

    private readonly string _folder = Directory.CreateTempSubdirectory("sozvon spool ").FullName;
    private readonly List<Exception?> _told = [];

    public void Dispose() => Directory.Delete(_folder, recursive: true);

    [Fact]
    public async Task SilenceIsTheFileExtendedNotWritten()
    {
        string wav = Path.Combine(_folder, "silence.wav");
        var writes = new List<(long Offset, int Bytes)>();
        var spool = new TrackSpool(wav, Rate, 1, _told.Add, (file, bytes, offset) =>
        {
            writes.Add((offset, bytes.Length));
            RandomAccess.Write(file, bytes, offset);
        });
        spool.Write(Fill(100, 0.5f));
        spool.WriteSilence(1000);
        spool.Write(Fill(100, 0.25f));
        spool.WriteSilence(500);
        await spool.CloseAsync();

        float[] samples = Samples(wav);
        Assert.Equal(1700, samples.Length);
        Assert.Equal(0.5f, samples[99]);
        Assert.Equal(0f, samples[600]);
        Assert.Equal(0.25f, samples[1100]);
        Assert.Equal(0f, samples[1699]);
        Assert.Equal([(0L, TrackSpool.HeaderBytes), (TrackSpool.HeaderBytes, 400), (TrackSpool.HeaderBytes + 4400L, 400)], writes);
        Assert.Empty(_told);
    }

    [Fact]
    public async Task AFailedWriteIsAHoleAndWhatFollowsKeepsItsTime()
    {
        string wav = Path.Combine(_folder, "full.wav");
        bool full = false;
        var spool = new TrackSpool(wav, Rate, 1, _told.Add, (file, bytes, offset) =>
        {
            if (full) throw new IOException("There is not enough space on the disk.", unchecked((int)0x80070070));
            RandomAccess.Write(file, bytes, offset);
        });
        spool.Write(Fill(100, 0.5f));
        spool.WriteSilence(100); // a silence makes the spool write what it holds: the next block is its own write
        await Until(() => File.Exists(wav) && new FileInfo(wav).Length >= TrackSpool.HeaderBytes + 400);
        full = true;
        spool.Write(Fill(100, 0.75f));
        spool.WriteSilence(1);
        spool.Write(Fill(100, 0.75f));
        spool.WriteSilence(1);
        await Until(() => _told.Count == 1);
        full = false;
        spool.Write(Fill(100, 0.25f));
        await spool.CloseAsync();

        float[] samples = Samples(wav);
        Assert.Equal(502, samples.Length);
        Assert.Equal(0.5f, samples[50]);
        Assert.Equal(0f, samples[250]);
        Assert.Equal(0f, samples[351]);
        Assert.Equal(0.25f, samples[450]);
        Assert.Equal(2, _told.Count);
        Assert.True(TrackSpool.IsDiskFull(_told[0]!));
        Assert.Null(_told[1]);
    }

    private static float[] Fill(int count, float value) => Enumerable.Repeat(value, count).ToArray();

    private static float[] Samples(string wav) =>
        MemoryMarshal.Cast<byte, float>(File.ReadAllBytes(wav).AsSpan(TrackSpool.HeaderBytes)).ToArray();

    private static async Task Until(Func<bool> condition)
    {
        for (int i = 0; i < 200 && !condition(); i++) await Task.Delay(10);
        Assert.True(condition());
    }
}
