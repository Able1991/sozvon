using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Sozvon.App.Calls;

/// <summary>Reads call folders as the contract describes them. Files are the engine's, so they stay shared.</summary>
public sealed partial class CallRepository(string callsDir, string dataDir)
{
    /// <summary>All calls, newest first. A folder that cannot be read is still listed, marked unreadable.</summary>
    public IReadOnlyList<CallRecord> Scan()
    {
        if (!Directory.Exists(callsDir))
        {
            return [];
        }
        var titles = ProjectTitles();
        return new DirectoryInfo(callsDir).EnumerateDirectories()
            .Where(d => !d.Name.StartsWith('.'))
            .Select(d => ReadCall(d.FullName, titles))
            .OfType<CallRecord>()
            .OrderByDescending(c => c.CreatedAt ?? DateTimeOffset.MinValue)
            .ToList();
    }

    public CallContent LoadContent(CallRecord call) =>
        call.InlineContent ?? new CallContent(ReadText(call.Folder, "transcript.txt"), ReadText(call.Folder, "summary.md"));

    private CallRecord? ReadCall(string folder, IReadOnlyDictionary<string, string> titles)
    {
        var name = Path.GetFileName(folder);
        var file = Path.Combine(folder, "call.json");
        if (!File.Exists(file))
        {
            var id = IdPattern().Match(name);
            return id.Success ? FromFolderName(folder, id.Value) : null;
        }
        try
        {
            using var document = JsonDocument.Parse(ReadSharedFile(file));
            return Build(folder, name, document.RootElement, titles);
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException)
        {
            return new CallRecord { Folder = folder, Id = name, Topic = name, IsUnreadable = true };
        }
    }

    private static CallRecord FromFolderName(string folder, string id)
    {
        var hasTranscript = File.Exists(Path.Combine(folder, "transcript.txt"));
        return new CallRecord
        {
            Folder = folder,
            Id = id,
            CreatedAt = DateTimeOffset.TryParseExact(id[..16], "yyyy-MM-dd HH-mm", null, System.Globalization.DateTimeStyles.AssumeLocal, out var at) ? at : null,
            Status = hasTranscript ? CallStatus.Done : CallStatus.Unknown,
        };
    }

    private static CallRecord Build(string folder, string name, JsonElement root, IReadOnlyDictionary<string, string> titles)
    {
        var slug = Text(root, "profile");
        var audio = root.TryGetProperty("audio", out var a) && a.ValueKind == JsonValueKind.Object ? a : default;
        var people = Strings(root, "participants");
        return new CallRecord
        {
            Folder = folder,
            Id = Text(root, "id") is { Length: > 0 } id ? id : name,
            CreatedAt = DateTimeOffset.TryParse(Text(root, "created_at"), out var created) ? created : null,
            Status = ParseStatus(Text(root, "status")),
            Topic = Text(root, "topic"),
            ProjectSlug = slug,
            ProjectTitle = titles.TryGetValue(slug, out var title) ? title : Text(root, "project_title") is { Length: > 0 } restored ? restored : slug,
            People = people.Count > 0 ? people : Strings(root, "names"),
            MicSeconds = Number(audio, "mic_seconds") ?? 0,
            SystemSeconds = Number(audio, "system_seconds") ?? 0,
            MicStart = Number(audio, "mic_start"),
            SystemStart = Number(audio, "system_start"),
            Notes = Notes(root),
            IsDemo = root.TryGetProperty("demo", out var demo) && demo.ValueKind == JsonValueKind.True,
            IsReflection = Text(root, "kind") == "reflection",
            InfoPending = root.TryGetProperty("info_pending", out var pending) && pending.ValueKind == JsonValueKind.True,
            AudioRemoved = Text(root, "audio_removed_at").Length > 0,
            IsQueued = Text(root, "queued_at").Length > 0,
            HasSummaryWarning = HasWarning(root, "summary"),
        };
    }

    private static CallStatus ParseStatus(string status) => status switch
    {
        "recorded" => CallStatus.Recorded,
        "processing" => CallStatus.Processing,
        "done" => CallStatus.Done,
        "failed" => CallStatus.Failed,
        _ => CallStatus.Unknown,
    };

    private static bool HasWarning(JsonElement root, string step) =>
        root.TryGetProperty("warnings", out var list) && list.ValueKind == JsonValueKind.Array
        && list.EnumerateArray().Any(w => w.ValueKind == JsonValueKind.Object && Text(w, "step") == step);

    private static List<CallNote> Notes(JsonElement root)
    {
        if (!root.TryGetProperty("notes", out var list) || list.ValueKind != JsonValueKind.Array)
        {
            return [];
        }
        return list.EnumerateArray()
            .Where(n => n.ValueKind == JsonValueKind.Object && Text(n, "text").Length > 0)
            .Select(n => new CallNote(Text(n, "text"), DateTimeOffset.TryParse(Text(n, "at"), out var at) ? at : null, Text(n, "source")))
            .ToList();
    }

    private Dictionary<string, string> ProjectTitles()
    {
        var titles = new Dictionary<string, string>();
        var folder = Path.Combine(dataDir, "profiles");
        if (!Directory.Exists(folder))
        {
            return titles;
        }
        foreach (var file in Directory.EnumerateFiles(folder, "*.json"))
        {
            try
            {
                using var document = JsonDocument.Parse(ReadSharedFile(file));
                if (document.RootElement.ValueKind == JsonValueKind.Object && Text(document.RootElement, "title") is { Length: > 0 } title)
                {
                    titles[Path.GetFileNameWithoutExtension(file)] = title;
                }
            }
            catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException)
            {
                // An unreadable project shows under its slug.
            }
        }
        return titles;
    }

    private static string ReadText(string folder, string name)
    {
        var path = Path.Combine(folder, name);
        try
        {
            return File.Exists(path) ? ReadSharedFile(path) : "";
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return "";
        }
    }

    private static string ReadSharedFile(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var reader = new StreamReader(stream, Encoding.UTF8);
        return reader.ReadToEnd();
    }

    private static string Text(JsonElement parent, string key) =>
        parent.ValueKind == JsonValueKind.Object && parent.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() ?? ""
            : "";

    private static double? Number(JsonElement parent, string key) =>
        parent.ValueKind == JsonValueKind.Object && parent.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.Number
            ? value.GetDouble()
            : null;

    private static List<string> Strings(JsonElement parent, string key) =>
        parent.TryGetProperty(key, out var list) && list.ValueKind == JsonValueKind.Array
            ? list.EnumerateArray().Where(v => v.ValueKind == JsonValueKind.String).Select(v => v.GetString()!).ToList()
            : [];

    [GeneratedRegex(@"^\d{4}-\d{2}-\d{2} \d{2}-\d{2}(-\d+)?(?= |$)")]
    private static partial Regex IdPattern();
}
