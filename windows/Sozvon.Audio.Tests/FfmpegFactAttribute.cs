using Xunit;

namespace Sozvon.Audio.Tests;

/// <summary>A test that needs a real ffmpeg, whose path comes from SOZVON_TEST_FFMPEG.</summary>
public sealed class FfmpegFactAttribute : FactAttribute
{
    public FfmpegFactAttribute()
    {
        if (TestFfmpeg.Path is null) Skip = "SOZVON_TEST_FFMPEG is not set";
    }
}

internal static class TestFfmpeg
{
    public static string? Path
    {
        get
        {
            string? path = Environment.GetEnvironmentVariable("SOZVON_TEST_FFMPEG");
            return File.Exists(path) ? path : null;
        }
    }

    public static float[] DecodeMono(string file)
    {
        var start = new System.Diagnostics.ProcessStartInfo(Path!)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        foreach (string a in new[] { "-v", "error", "-i", file, "-ac", "1", "-f", "f32le", "-" }) start.ArgumentList.Add(a);

        using var process = System.Diagnostics.Process.Start(start)!;
        process.ErrorDataReceived += (_, _) => { };
        process.BeginErrorReadLine();
        using var memory = new MemoryStream();
        process.StandardOutput.BaseStream.CopyTo(memory);
        process.WaitForExit();
        Assert.Equal(0, process.ExitCode);

        byte[] bytes = memory.ToArray();
        var samples = new float[bytes.Length / sizeof(float)];
        Buffer.BlockCopy(bytes, 0, samples, 0, samples.Length * sizeof(float));
        return samples;
    }
}
