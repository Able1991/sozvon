using System.Text.Json;
using System.Text.Json.Serialization;

namespace Sozvon.Audio.Session;

/// <summary>The files of a recording in progress, in a hidden folder of the call the engine never reads.</summary>
internal sealed class SessionFiles(string callDirectory)
{
    public const string FolderName = ".recording";

    public string CallDirectory { get; } = callDirectory;
    public string Folder { get; } = Path.Combine(callDirectory, FolderName);
    public string Journal => Path.Combine(Folder, "session.json");
    public string MicWav => Path.Combine(Folder, "mic.wav");
    public string SystemWav => Path.Combine(Folder, "system.wav");
    public string MicEncoding => Path.Combine(Folder, "mic.encoding.m4a");
    public string SystemEncoding => Path.Combine(Folder, "system.encoding.m4a");
    public string MicFinal => Path.Combine(CallDirectory, "mic.m4a");
    public string SystemFinal => Path.Combine(CallDirectory, "system.m4a");

    public void Create()
    {
        DirectoryInfo folder = Directory.CreateDirectory(Folder);
        folder.Attributes |= FileAttributes.Hidden;
    }
}

/// <summary>What a recovery needs and the audio does not say: the track starts, the marks, when it began.</summary>
internal sealed record SessionJournal(
    [property: JsonPropertyName("started_at")] DateTimeOffset StartedAt,
    [property: JsonPropertyName("mic_start")] double? MicStart,
    [property: JsonPropertyName("system_start")] double? SystemStart,
    [property: JsonPropertyName("marks")] IReadOnlyList<double> Marks)
{
    public void Save(string path)
    {
        string temporary = path + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(this));
        File.Move(temporary, path, overwrite: true);
    }

    public static SessionJournal? Load(string path)
    {
        try
        {
            return JsonSerializer.Deserialize<SessionJournal>(File.ReadAllText(path));
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
        {
            return null;
        }
    }
}

/// <summary>The marks on the transcript timeline, by the rule of the Mac app (CallMarks).</summary>
internal static class CallMarks
{
    public const double MinGapSeconds = 5;

    /// <param name="clockTimes">Presses on the shared clock.</param>
    /// <param name="start">The earlier track's start: the engine's t0. Null when no track has audio.</param>
    public static IReadOnlyList<double> Offsets(IEnumerable<double> clockTimes, double? start)
    {
        if (start is not double t0) return [];
        var offsets = new List<double>();
        foreach (double t in clockTimes.Order())
        {
            double second = Math.Round(Math.Max(0, t - t0) * 10) / 10;
            if (offsets.Count > 0 && second - offsets[^1] < MinGapSeconds) continue;
            offsets.Add(second);
        }
        return offsets;
    }
}
