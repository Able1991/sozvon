using System.Diagnostics;
using System.Globalization;
using System.Text.RegularExpressions;

namespace Sozvon.Core.Calls;

/// <summary>The file has no audio track to import.</summary>
public sealed class NoAudioException(string file) : IOException($"no audio track in {file}");

/// <summary>
/// An existing recording becomes a call: a new folder named by the recording's date, its audio as system.m4a (the
/// other side, one track at offset 0) and status "recorded", so the engine treats it as a call with one track.
/// The conversion uses the engine's ffmpeg, which reads more formats than the Mac can (webm, ogg, opus too).
/// </summary>
public static partial class CallImport
{
    /// <summary>Audio and video files the Calls window accepts, by extension, ignoring case.</summary>
    public static readonly IReadOnlySet<string> Extensions = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        ".m4a", ".mp3", ".wav", ".mp4", ".mov", ".aac", ".flac", ".webm", ".ogg", ".opus", ".oga", ".mkv", ".wma",
    };

    /// <summary>Hidden file of an import in progress, renamed to system.m4a when complete.</summary>
    public const string TempPrefix = ".import-";

    public static bool IsSupported(string path) => Extensions.Contains(Path.GetExtension(path));

    /// <summary>When the recording was made: the date written in the file, else the file's creation date, else now.</summary>
    public static DateTimeOffset Date(string file, DateTimeOffset? recorded, DateTimeOffset now)
    {
        if (recorded is { } at) return at;
        var info = new FileInfo(file);
        var created = info.Exists ? new DateTimeOffset(info.CreationTimeUtc) : (DateTimeOffset?)null;
        var modified = info.Exists ? new DateTimeOffset(info.LastWriteTimeUtc) : (DateTimeOffset?)null;
        return Plausible(created, now) ?? Plausible(modified, now) ?? now;
    }

    /// <summary>A date from the file is plausible after 2000 and not in the future: recorders write 1904 or 1970.</summary>
    public static DateTimeOffset? Plausible(DateTimeOffset? date, DateTimeOffset now) =>
        date is { } d && d > new DateTimeOffset(2000, 1, 1, 0, 0, 0, TimeSpan.Zero) && d < now.AddDays(1) ? d : null;

    /// <summary>"2026-11-04T15:01:02Z", "2026-11-04T15:01:02.000000Z", "2026-11-04T15:01:02+0300", "2026-11-04 15:01:02", "2026-11-04".</summary>
    public static DateTimeOffset? ParseDate(string text)
    {
        var t = text.Trim();
        string[] formats =
        [
            "yyyy-MM-dd'T'HH:mm:ssK", "yyyy-MM-dd'T'HH:mm:ss.FFFFFFFK", "yyyy-MM-dd'T'HH:mm:sszzz", "yyyy-MM-dd'T'HH:mm:sszz00",
            "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd",
        ];
        return DateTimeOffset.TryParseExact(t, formats, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var at) ? at : null;
    }

    /// <summary>What ffmpeg says about the source: its length and the creation date written in it.</summary>
    public static (double? Seconds, DateTimeOffset? Recorded) Probe(string ffmpegOutput, DateTimeOffset now)
    {
        double? seconds = DurationLine().Match(ffmpegOutput) is { Success: true } d
            ? int.Parse(d.Groups[1].Value, CultureInfo.InvariantCulture) * 3600 + int.Parse(d.Groups[2].Value, CultureInfo.InvariantCulture) * 60
              + double.Parse(d.Groups[3].Value, CultureInfo.InvariantCulture)
            : null;
        var recorded = CreationLine().Matches(ffmpegOutput).Select(m => Plausible(ParseDate(m.Groups[1].Value), now)).FirstOrDefault(d => d is not null);
        return (seconds, recorded);
    }

    /// <summary>
    /// Imports one file: a new call folder, the audio converted into it, call.json written. The folder; a failure leaves
    /// nothing behind. <paramref name="progress"/> gets 0..1 as ffmpeg goes.
    /// </summary>
    /// <exception cref="IOException">ffmpeg is missing, the file has no audio, or the conversion failed.</exception>
    public static async Task<string> ImportAsync(string file, string callsRoot, string ffmpeg, IProgress<double>? progress = null,
                                                 CancellationToken cancellationToken = default)
    {
        if (!File.Exists(ffmpeg)) throw new IOException($"ffmpeg not found at {ffmpeg}");
        var now = DateTimeOffset.UtcNow;
        var (_, recorded) = Probe(await RunAsync(ffmpeg, ["-hide_banner", "-nostdin", "-i", file], null, null, cancellationToken), now);
        var date = Date(file, recorded, now);
        var dir = CallFolder.Create(callsRoot, date);
        var temp = Path.Combine(dir, TempPrefix + Guid.NewGuid().ToString("N") + ".m4a");
        try
        {
            double? total = null;
            var output = await RunAsync(ffmpeg,
                ["-hide_banner", "-nostdin", "-y", "-i", file, "-map", "0:a:0", "-vn", "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart", "-f", "mp4", temp],
                line =>
                {
                    total ??= Probe(line, now).Seconds;
                    if (total is > 0 && ProgressLine().Match(line) is { Success: true } p)
                        progress?.Report(Math.Clamp(Seconds(p) / total.Value, 0, 1));
                },
                ok: () => File.Exists(temp), cancellationToken);
            var seconds = Probe(output, now).Seconds ?? 0;
            File.Move(temp, Path.Combine(dir, "system.m4a"));
            if (!CallFile.RecordStopped(dir, date, new AudioTimes(SystemStart: 0, SystemSeconds: seconds)))
                throw new IOException("call.json was not written");
            return dir;
        }
        catch
        {
            File.Delete(temp);
            File.Delete(Path.Combine(dir, "system.m4a"));
            CallFolder.DiscardIfUnused(dir);
            throw;
        }
    }

    private static double Seconds(Match m) =>
        int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture) * 3600 + int.Parse(m.Groups[2].Value, CultureInfo.InvariantCulture) * 60
        + double.Parse(m.Groups[3].Value, CultureInfo.InvariantCulture);

    /// <summary>Runs ffmpeg and returns what it wrote. <paramref name="ok"/> null: any exit code is fine (a probe).</summary>
    private static async Task<string> RunAsync(string ffmpeg, IEnumerable<string> arguments, Action<string>? onLine, Func<bool>? ok,
                                               CancellationToken cancellationToken)
    {
        var start = new ProcessStartInfo(ffmpeg) { CreateNoWindow = true, UseShellExecute = false, RedirectStandardError = true };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new IOException("ffmpeg did not start");
        var output = new System.Text.StringBuilder();
        // ffmpeg ends its progress lines with a carriage return, so read characters, not lines.
        var buffer = new char[4096];
        var line = new System.Text.StringBuilder();
        int read;
        while ((read = await process.StandardError.ReadAsync(buffer, cancellationToken)) > 0)
        {
            for (var i = 0; i < read; i++)
            {
                var ch = buffer[i];
                output.Append(ch);
                if (ch is '\r' or '\n')
                {
                    if (line.Length > 0) onLine?.Invoke(line.ToString());
                    line.Clear();
                }
                else
                {
                    line.Append(ch);
                }
            }
        }
        await process.WaitForExitAsync(cancellationToken);
        if (ok is not null && (process.ExitCode != 0 || !ok()))
        {
            var text = output.ToString();
            if (text.Contains("does not contain any stream", StringComparison.Ordinal) || text.Contains("matches no streams", StringComparison.Ordinal))
                throw new NoAudioException(arguments.SkipWhile(a => a != "-i").Skip(1).FirstOrDefault() ?? "");
            throw new IOException($"ffmpeg failed with {process.ExitCode}: {text.Trim().Split('\n').LastOrDefault()?.Trim()}");
        }
        return output.ToString();
    }

    [GeneratedRegex(@"Duration: (\d+):(\d\d):(\d\d(?:\.\d+)?)")]
    private static partial Regex DurationLine();

    [GeneratedRegex(@"time=(\d+):(\d\d):(\d\d(?:\.\d+)?)")]
    private static partial Regex ProgressLine();

    [GeneratedRegex(@"creation_time\s*:\s*(\S+)")]
    private static partial Regex CreationLine();
}
