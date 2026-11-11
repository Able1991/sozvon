using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Call = Sozvon.Core.Calls.Call;
using Project = Sozvon.Core.Calls.Project;
using TextRules = Sozvon.Core.Foundation.TextRules;

namespace Sozvon.App.Calls;

/// <summary>Reads call folders as the contract describes them. Files are the engine's, so they stay shared.</summary>
public sealed partial class CallRepository(Func<string> callsFolder, string dataDir)
{
    /// <summary>The calls folder of this moment: Settings can change it while the app runs.</summary>
    private string CallsDir => callsFolder();

    /// <summary>All calls, newest first. A folder that cannot be read is still listed, marked unreadable.</summary>
    public IReadOnlyList<CallRecord> Scan()
    {
        if (!Directory.Exists(CallsDir))
        {
            return [];
        }
        var titles = Project.Titles(Project.All(Path.Combine(dataDir, "profiles")));
        return new DirectoryInfo(CallsDir).EnumerateDirectories()
            .Where(d => !d.Name.StartsWith('.'))
            .Select(d => ReadCall(d.FullName, titles))
            .OfType<CallRecord>()
            .OrderByDescending(c => c.CreatedAt ?? DateTimeOffset.MinValue)
            .ToList();
    }

    /// <summary>The saved voice prints: speakers without one are offered for confirmation.</summary>
    public IReadOnlyList<Sozvon.Core.Calls.VoiceRecord> Voices() => Sozvon.Core.Calls.Voices.All(Path.Combine(dataDir, "voices"));

    public CallContent LoadContent(CallRecord call) =>
        call.InlineContent ?? new CallContent(ReadText(call.Folder, "transcript.txt"), ReadText(call.Folder, "summary.md"));

    private CallRecord? ReadCall(string folder, IReadOnlyDictionary<string, string> titles)
    {
        var name = Path.GetFileName(folder);
        var file = Path.Combine(folder, "call.json");
        if (!File.Exists(file))
        {
            return IdPattern().IsMatch(name) && Call.Load(folder, titles) is { } legacy ? FromFolderName(folder, legacy) : null;
        }
        try
        {
            using var document = JsonDocument.Parse(ReadSharedFile(file));
            return document.RootElement.ValueKind == JsonValueKind.Object && Call.Load(folder, titles) is { } call
                ? Build(folder, call, document.RootElement)
                : Unreadable(folder, name);
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException)
        {
            return Unreadable(folder, name);
        }
    }

    /// <summary>Listed under the day its folder name gives, as the Mac does, rather than under «Без даты».</summary>
    private static CallRecord Unreadable(string folder, string name) =>
        new() { Folder = folder, Id = name, Topic = name, CreatedAt = Call.ParseId(name), IsUnreadable = true };

    /// <summary>An old call without call.json: what the folder name and meta.json say.</summary>
    private static CallRecord FromFolderName(string folder, Call call) => new()
    {
        Folder = folder,
        Id = call.CallId,
        CreatedAt = call.Date,
        Status = call.HasTranscript || File.Exists(Path.Combine(folder, "transcript.txt")) ? CallStatus.Done : CallStatus.Unknown,
        Topic = call.Title,
        ProjectTitle = call.Project,
        People = TextRules.SplitList(call.People),
        MicSeconds = call.Duration,
    };

    /// <summary>Title, project, date and people as the Mac shows them (Core's <see cref="Call"/>); the rest from call.json.</summary>
    private static CallRecord Build(string folder, Call call, JsonElement root)
    {
        var audio = root.TryGetProperty("audio", out var a) && a.ValueKind == JsonValueKind.Object ? a : default;
        return new CallRecord
        {
            Folder = folder,
            Id = call.CallId,
            CreatedAt = call.Date,
            Status = ParseStatus(Text(root, "status")),
            Topic = call.Title,
            ProjectSlug = call.Info.Profile,
            ProjectTitle = call.Project,
            People = TextRules.SplitList(call.People),
            MicSeconds = Number(audio, "mic_seconds") ?? 0,
            SystemSeconds = Number(audio, "system_seconds") ?? 0,
            MicStart = Number(audio, "mic_start"),
            SystemStart = Number(audio, "system_start"),
            Notes = call.Notes,
            HasParticipants = call.Participants is not null,
            IsDemo = root.TryGetProperty("demo", out var demo) && demo.ValueKind == JsonValueKind.True,
            IsReflection = Text(root, "kind") == "reflection",
            InfoPending = root.TryGetProperty("info_pending", out var pending) && pending.ValueKind == JsonValueKind.True,
            AudioRemoved = Text(root, "audio_removed_at").Length > 0,
            HasAudio = call.HasAudio,
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

    [GeneratedRegex(@"^\d{4}-\d{2}-\d{2} \d{2}-\d{2}(-\d+)?(?= |$)")]
    private static partial Regex IdPattern();
}
