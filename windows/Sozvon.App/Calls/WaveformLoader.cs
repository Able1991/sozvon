using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using Sozvon.Core.Calls;

namespace Sozvon.App.Calls;

/// <summary>
/// The waveform of a whole call for the trim panel, as on the Mac (TrimPanel.swift's WaveformCache and WaveformReader):
/// the files the player plays, decoded by the engine's ffmpeg to mono at a low rate and gathered straight into a
/// <see cref="WaveformEnvelope"/> on the call's timeline, a chunk at a time. Kept in memory only, keyed by the files'
/// times, so a trimmed call is read again; nothing is written into the call folder.
/// </summary>
internal static class WaveformLoader
{
    /// <summary>Plenty for the panel's bars, quick even for a two-hour call.</summary>
    private const int Rate = 1000;

    public const int Bins = 600;

    private static readonly ConcurrentDictionary<string, float[]> s_cache = new();

    /// <summary>The call's peaks, or null when no file could be decoded.</summary>
    public static async Task<float[]?> PeaksAsync(CallRecord call, string ffmpeg, CancellationToken cancellation)
    {
        var tracks = CallPlayer.FindTracks(call);
        if (tracks.Count == 0 || !File.Exists(ffmpeg))
        {
            return null;
        }
        var key = Key(call.Folder, tracks);
        if (s_cache.TryGetValue(key, out var cached))
        {
            return cached;
        }
        var envelope = new WaveformEnvelope(Bins, Math.Max(call.DurationSeconds, 1));
        var any = false;
        foreach (var (path, offset) in tracks)
        {
            any |= await AddAsync(ffmpeg, path, offset, envelope, cancellation);
        }
        if (!any)
        {
            return null;
        }
        var peaks = envelope.Peaks();
        s_cache[key] = peaks;
        return peaks;
    }

    private static string Key(string folder, List<(string Path, double Offset)> tracks) =>
        folder + "|" + string.Join("|", tracks.Select(t => $"{t.Path}:{File.GetLastWriteTimeUtc(t.Path).Ticks}:{t.Offset}"));

    /// <summary>One file into the envelope; false when ffmpeg could not decode it.</summary>
    private static async Task<bool> AddAsync(string ffmpeg, string path, double offset, WaveformEnvelope envelope, CancellationToken cancellation)
    {
        var start = new ProcessStartInfo(ffmpeg)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
        };
        foreach (var argument in new[] { "-nostdin", "-v", "error", "-i", path, "-vn", "-ac", "1", "-ar", Rate.ToString(), "-f", "f32le", "pipe:1" })
        {
            start.ArgumentList.Add(argument);
        }
        Process process;
        try
        {
            process = Process.Start(start) ?? throw new InvalidOperationException("ffmpeg did not start");
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            return false;
        }
        using (process)
        {
            process.StandardInput.Close();
            var errors = process.StandardError.ReadToEndAsync(cancellation);
            var buffer = new byte[64 * 1024];
            var carry = 0;
            long samples = 0;
            try
            {
                var stream = process.StandardOutput.BaseStream;
                int read;
                while ((read = await stream.ReadAsync(buffer.AsMemory(carry), cancellation)) > 0)
                {
                    var bytes = carry + read;
                    var whole = bytes / sizeof(float) * sizeof(float);
                    var chunk = MemoryMarshal.Cast<byte, float>(buffer.AsSpan(0, whole));
                    envelope.Add(chunk, offset + (double)samples / Rate, Rate);
                    samples += chunk.Length;
                    carry = bytes - whole;
                    buffer.AsSpan(whole, carry).CopyTo(buffer);
                }
                await process.WaitForExitAsync(cancellation);
                await errors;
            }
            catch (OperationCanceledException)
            {
                process.Kill(entireProcessTree: true);
                throw;
            }
            return process.ExitCode == 0 && samples > 0;
        }
    }
}
