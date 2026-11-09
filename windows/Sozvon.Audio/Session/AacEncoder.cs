using System.Diagnostics;

namespace Sozvon.Audio.Session;

/// <summary>Encodes a track with the engine's ffmpeg.</summary>
internal sealed class AacEncoder(string ffmpegPath)
{
    private static readonly TimeSpan s_minimumTimeout = TimeSpan.FromMinutes(2);

    /// <param name="seconds">The track's length, which bounds how long the encoder may run.</param>
    /// <exception cref="IOException">ffmpeg is missing or failed.</exception>
    public async Task EncodeAsync(string wav, string output, int kilobitsPerSecond, double seconds, CancellationToken cancellationToken)
    {
        if (!File.Exists(ffmpegPath)) throw new IOException($"ffmpeg not found at {ffmpegPath}");

        var start = new ProcessStartInfo(ffmpegPath)
        {
            CreateNoWindow = true,
            UseShellExecute = false,
            RedirectStandardError = true,
        };
        foreach (string argument in new[]
        {
            "-hide_banner", "-nostdin", "-v", "error", "-y", "-i", wav,
            "-c:a", "aac", "-b:a", $"{kilobitsPerSecond}k", "-movflags", "+faststart", "-f", "mp4", output,
        })
        {
            start.ArgumentList.Add(argument);
        }

        using var process = Process.Start(start) ?? throw new IOException("ffmpeg did not start");
        Task<string> errors = process.StandardError.ReadToEndAsync(CancellationToken.None);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(s_minimumTimeout + TimeSpan.FromSeconds(seconds));
        try
        {
            await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            process.Kill(entireProcessTree: true);
            if (cancellationToken.IsCancellationRequested) throw;
            throw new IOException($"ffmpeg timed out on {Path.GetFileName(wav)}");
        }

        string message = await errors.ConfigureAwait(false);
        if (process.ExitCode != 0) throw new IOException($"ffmpeg failed with {process.ExitCode}: {message.Trim()}");
    }
}
