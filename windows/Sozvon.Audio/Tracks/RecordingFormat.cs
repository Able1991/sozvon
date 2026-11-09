using System.Diagnostics;

namespace Sozvon.Audio;

/// <summary>The fixed format of every recording: Windows converts whatever the device gives to this.</summary>
internal static class RecordingFormat
{
    public const int SampleRate = 48_000;
    public const int MicChannels = 1;
    public const int SystemChannels = 2;
    public const int BytesPerSample = sizeof(float);
}

/// <summary>QueryPerformanceCounter in seconds: the clock WASAPI stamps packets with.</summary>
internal static class SharedClock
{
    public static double Now => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;
}
