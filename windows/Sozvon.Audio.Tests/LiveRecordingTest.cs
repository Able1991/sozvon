using System.Text.Json.Nodes;
using Xunit;
using Xunit.Abstractions;

namespace Sozvon.Audio.Tests;

/// <summary>Records from the real devices. It runs only when SOZVON_LIVE_RECORDING names a folder for the recording.</summary>
public sealed class LiveRecordingTest(ITestOutputHelper output)
{
    private static readonly string? s_folder = Environment.GetEnvironmentVariable("SOZVON_LIVE_RECORDING");

    [LiveFact]
    public async Task RecordsBothTracksForTenSeconds()
    {
        string call = Path.Combine(s_folder!, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(call);
        var options = new RecorderOptions(TestFfmpeg.Path!, Path.Combine(s_folder!, "recorder.log"));
        var recorder = new WasapiRecorder(options);
        var levels = new List<RecorderLevels>();
        recorder.LevelsChanged += (_, l) => { lock (levels) levels.Add(l); };

        await recorder.StartAsync(call);
        await Task.Delay(TimeSpan.FromSeconds(6));
        bool marked = recorder.Mark();
        await Task.Delay(TimeSpan.FromSeconds(4));
        RecordingResult result = await recorder.StopAsync();

        output.WriteLine($"raw {result.MicrophoneRaw}, marked {marked}, marks [{string.Join(", ", result.Marks)}]");
        output.WriteLine($"mic_start {result.Audio.MicStart}, system_start {result.Audio.SystemStart}, " +
                         $"offset {result.Audio.MicStart - result.Audio.SystemStart:F4}");
        output.WriteLine($"mic_seconds {result.Audio.MicSeconds:F3}, system_seconds {result.Audio.SystemSeconds:F3}");
        output.WriteLine($"level events {levels.Count}, mic display max {levels.Max(l => l.Microphone):F2}, system display max {levels.Max(l => l.System):F2}");
        foreach (string track in new[] { "mic.m4a", "system.m4a" })
        {
            string path = Path.Combine(call, track);
            float[] decoded = TestFfmpeg.DecodeMono(path);
            double rms = Math.Sqrt(decoded.Sum(s => (double)s * s) / decoded.Length);
            output.WriteLine($"{track}: {new FileInfo(path).Length} bytes, {decoded.Length / 48000.0:F3} s decoded, " +
                             $"RMS {20 * Math.Log10(Math.Max(rms, 1e-9)):F1} dBFS, peak {decoded.Max(Math.Abs):F4}");
        }

        output.WriteLine(File.ReadAllText(Path.Combine(s_folder!, "recorder.log")));
        output.WriteLine(JsonNode.Parse(File.ReadAllText(Path.Combine(call, "call.json")))!.ToJsonString());
        Assert.False(Directory.Exists(Path.Combine(call, ".recording")));
        Assert.InRange(result.Audio.MicSeconds, 9.5, 11);
        Assert.InRange(result.Audio.SystemSeconds, 9.5, 11);
    }

    private sealed class LiveFactAttribute : FactAttribute
    {
        public LiveFactAttribute()
        {
            if (s_folder is null || TestFfmpeg.Path is null) Skip = "SOZVON_LIVE_RECORDING or SOZVON_TEST_FFMPEG is not set";
        }
    }
}
