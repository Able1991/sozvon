using System.Runtime.InteropServices;

namespace Sozvon.App.Setup;

/// <summary>Why a test recording failed; the message is ready to show.</summary>
internal sealed class MicrophoneTestException(string message) : Exception(message);

/// <summary>Records three seconds from the default microphone into memory and reports the level as it goes.</summary>
internal static unsafe partial class MicrophoneTest
{
    private const int SampleRate = 16000, BufferMilliseconds = 100, BufferCount = 4, BuffersToRecord = 30;
    private const int BufferBytes = SampleRate * 2 * BufferMilliseconds / 1000;
    private const int NoAudioTimeoutMilliseconds = 2000;
    private const uint WaveMapper = 0xFFFFFFFF, CallbackEvent = 0x00050000, HeaderDone = 1;
    private const string NoSound = "Запись запустилась, но микрофон не прислал звук. Проверь, какой микрофон выбран в Параметрах Windows: Система > Звук.";

    public static Task RunAsync(IProgress<double> level, CancellationToken cancellation) =>
        Task.Run(() => Record(level, cancellation), cancellation);

    private static void Record(IProgress<double> level, CancellationToken cancellation)
    {
        using var signal = new AutoResetEvent(false);
        var format = new WaveFormat
        {
            FormatTag = 1,
            Channels = 1,
            SamplesPerSecond = SampleRate,
            AverageBytesPerSecond = SampleRate * 2,
            BlockAlign = 2,
            BitsPerSample = 16,
        };
        Check(waveInOpen(out var device, WaveMapper, format, signal.SafeWaitHandle.DangerousGetHandle(), 0, CallbackEvent));

        var headers = stackalloc WaveHeader[BufferCount];
        var memory = (byte*)NativeMemory.Alloc(BufferCount * BufferBytes);
        var prepared = 0;
        try
        {
            for (; prepared < BufferCount; prepared++)
            {
                headers[prepared] = new WaveHeader { Data = memory + prepared * BufferBytes, BufferLength = BufferBytes };
                Check(waveInPrepareHeader(device, &headers[prepared], (uint)sizeof(WaveHeader)));
                Check(waveInAddBuffer(device, &headers[prepared], (uint)sizeof(WaveHeader)));
            }
            Check(waveInStart(device));
            RecordBuffers(device, headers, signal, level, cancellation);
        }
        finally
        {
            waveInReset(device);
            for (var i = 0; i < prepared; i++)
            {
                waveInUnprepareHeader(device, &headers[i], (uint)sizeof(WaveHeader));
            }
            waveInClose(device);
            NativeMemory.Free(memory);
        }
    }

    private static void RecordBuffers(nint device, WaveHeader* headers, AutoResetEvent signal, IProgress<double> level, CancellationToken cancellation)
    {
        var recorded = 0;
        var heardSound = false;
        while (recorded < BuffersToRecord)
        {
            cancellation.ThrowIfCancellationRequested();
            if (!signal.WaitOne(NoAudioTimeoutMilliseconds))
            {
                throw new MicrophoneTestException(Strings.L(NoSound));
            }
            for (var i = 0; i < BufferCount && recorded < BuffersToRecord; i++)
            {
                if ((headers[i].Flags & HeaderDone) == 0)
                {
                    continue;
                }
                var peak = Peak(headers[i]);
                heardSound |= peak > 0;
                level.Report(peak);
                recorded++;
                Check(waveInAddBuffer(device, &headers[i], (uint)sizeof(WaveHeader)));
            }
        }
        if (!heardSound)
        {
            throw new MicrophoneTestException(Strings.L(NoSound));
        }
    }

    private static double Peak(in WaveHeader header)
    {
        var peak = 0;
        foreach (var sample in new ReadOnlySpan<short>(header.Data, (int)header.BytesRecorded / 2))
        {
            peak = Math.Max(peak, Math.Abs((int)sample));
        }
        return peak / 32768.0;
    }

    private static void Check(uint error)
    {
        if (error != 0)
        {
            throw new MicrophoneTestException(Strings.L("Не удалось открыть микрофон (код %@). Проверь разрешение и выбранный микрофон в Параметрах Windows.", error));
        }
    }

    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    private struct WaveFormat
    {
        public ushort FormatTag, Channels;
        public uint SamplesPerSecond, AverageBytesPerSecond;
        public ushort BlockAlign, BitsPerSample, ExtraSize;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WaveHeader
    {
        public byte* Data;
        public uint BufferLength, BytesRecorded;
        public nuint User;
        public uint Flags, Loops;
        public nint Next, Reserved;
    }

    [LibraryImport("winmm.dll")]
    private static partial uint waveInOpen(out nint device, uint deviceId, in WaveFormat format, nint callback, nint instance, uint flags);

    [LibraryImport("winmm.dll")]
    private static partial uint waveInPrepareHeader(nint device, WaveHeader* header, uint size);

    [LibraryImport("winmm.dll")]
    private static partial uint waveInUnprepareHeader(nint device, WaveHeader* header, uint size);

    [LibraryImport("winmm.dll")]
    private static partial uint waveInAddBuffer(nint device, WaveHeader* header, uint size);

    [LibraryImport("winmm.dll")]
    private static partial uint waveInStart(nint device);

    [LibraryImport("winmm.dll")]
    private static partial uint waveInReset(nint device);

    [LibraryImport("winmm.dll")]
    private static partial uint waveInClose(nint device);
}
