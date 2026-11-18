using System.Diagnostics;
using System.Globalization;

namespace Sozvon.Audio.Session;

/// <summary>Encodes a track with the engine's ffmpeg.</summary>
internal sealed class AacEncoder(string ffmpegPath)
{
    private static readonly TimeSpan s_minimumTimeout = TimeSpan.FromMinutes(2);

    /// <param name="seconds">The track's length, which bounds how long the encoder may run.</param>
    /// <exception cref="IOException">ffmpeg is missing or failed.</exception>
    public Task EncodeAsync(string wav, string output, int kilobitsPerSecond, double seconds, CancellationToken cancellationToken) =>
        EncodeAsync([new EncoderInput(wav, 0)], output, kilobitsPerSecond, seconds, cancellationToken);

    /// <summary>Several tracks of one format, each moved later by its delay and summed as they are (no halving).</summary>
    /// <param name="seconds">The result's length, which bounds how long the encoder may run.</param>
    /// <exception cref="IOException">ffmpeg is missing or failed.</exception>
    public async Task EncodeAsync(IReadOnlyList<EncoderInput> inputs, string output, int kilobitsPerSecond, double seconds,
        CancellationToken cancellationToken)
    {
        if (!File.Exists(ffmpegPath)) throw new IOException($"ffmpeg not found at {ffmpegPath}");
        if (inputs.Count == 0) throw new ArgumentException("Nothing to encode.", nameof(inputs));

        var start = new ProcessStartInfo(ffmpegPath)
        {
            CreateNoWindow = true,
            UseShellExecute = false,
            RedirectStandardError = true,
        };
        foreach (string argument in Arguments(inputs, output, kilobitsPerSecond)) start.ArgumentList.Add(argument);

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
            throw new IOException($"ffmpeg timed out on {Path.GetFileName(inputs[0].Wav)}");
        }

        string message = await errors.ConfigureAwait(false);
        if (process.ExitCode != 0) throw new IOException($"ffmpeg failed with {process.ExitCode}: {message.Trim()}");
    }

    internal static List<string> Arguments(IReadOnlyList<EncoderInput> inputs, string output, int kilobitsPerSecond)
    {
        var arguments = new List<string> { "-hide_banner", "-nostdin", "-v", "error", "-y" };
        foreach (EncoderInput input in inputs) arguments.AddRange(["-i", input.Wav]);
        if (inputs.Count > 1 || inputs[0].DelayFrames > 0)
        {
            // Delays in samples ("S"), so the tracks stay frame-exact on the shared clock.
            var parts = inputs.Select((input, i) =>
                $"[{i}:a]adelay={input.DelayFrames.ToString(CultureInfo.InvariantCulture)}S:all=1[d{i}]").ToList();
            string labels = string.Concat(inputs.Select((_, i) => $"[d{i}]"));
            parts.Add(inputs.Count > 1
                ? $"{labels}amix=inputs={inputs.Count}:duration=longest:normalize=0[out]"
                : $"{labels}anull[out]");
            arguments.AddRange(["-filter_complex", string.Join(';', parts), "-map", "[out]"]);
        }
        arguments.AddRange(["-c:a", "aac", "-b:a", $"{kilobitsPerSecond}k", "-movflags", "+faststart", "-f", "mp4", output]);
        return arguments;
    }
}

/// <param name="DelayFrames">Silence before this track, in frames of the recording's rate.</param>
internal readonly record struct EncoderInput(string Wav, long DelayFrames);
