using Sozvon.Core.Foundation;

namespace Sozvon.Core.Calls;

/// <summary>"Delete audio automatically": after N days a finished call keeps its transcript and summary, its tracks go.</summary>
public static class AudioRetention
{
    /// <summary>The choices in Settings, in days; 0 keeps audio forever.</summary>
    public static readonly int[] Choices = [0, 7, 15, 30, 60];

    public static readonly string[] Tracks = ["mic.m4a", "system.m4a"];

    /// <summary>Everything the cleanup removes: the tracks, the engine's cleaned microphone and its listening file.</summary>
    public static readonly string[] RemovedFiles = [.. Tracks, "mic.clean.m4a", "listen.m4a"];

    /// <summary>call.json: when the tracks were removed, so the card can say why there is no player.</summary>
    public const string RemovedKey = "audio_removed_at";

    /// <summary>Days for a Settings choice; an unknown index keeps audio.</summary>
    public static int Days(int choice) => choice >= 0 && choice < Choices.Length ? Choices[choice] : 0;

    /// <summary>
    /// Calls whose audio may go: done, with a transcript, started more than <paramref name="days"/> days ago, with a
    /// track left, not busy. Oldest folder name first.
    /// </summary>
    public static List<string> Expired(string root, int days, DateTimeOffset now, Func<string, bool>? busy = null)
    {
        if (days <= 0 || !Directory.Exists(root)) return [];
        var cutoff = now.AddDays(-days);
        return Directory.EnumerateDirectories(root)
            .Where(dir => !Path.GetFileName(dir).StartsWith('.') && busy?.Invoke(dir) != true)
            .Where(dir =>
            {
                var call = CallFile.Read(dir);
                return call.Text("status") == CallStatus.Done.Key()
                    && File.Exists(Path.Combine(dir, "transcript.txt"))
                    && Iso8601.Parse(call.Text("created_at")) is { } created && created < cutoff
                    && Tracks.Any(t => File.Exists(Path.Combine(dir, t)));
            })
            .OrderBy(dir => Path.GetFileName(dir), StringComparer.Ordinal)
            .ToList();
    }

    /// <summary>The bytes the cleanup would free in these calls.</summary>
    public static long Size(IEnumerable<string> dirs) =>
        dirs.Sum(dir => RemovedFiles.Select(name => new FileInfo(Path.Combine(dir, name))).Where(f => f.Exists).Sum(f => f.Length));

    /// <summary>Deletes the audio of one call and notes it in call.json. The bytes freed.</summary>
    public static long RemoveAudio(string dir, DateTimeOffset now)
    {
        long freed = 0;
        foreach (var name in RemovedFiles)
        {
            var file = new FileInfo(Path.Combine(dir, name));
            if (!file.Exists) continue;
            var size = file.Length;
            try
            {
                file.Delete();
                freed += size;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                // In use (a player, a copy): the next run tries again.
            }
        }
        if (freed > 0) CallFile.Update(dir, c => c[RemovedKey] = Iso8601.Seconds(now));
        return freed;
    }
}
