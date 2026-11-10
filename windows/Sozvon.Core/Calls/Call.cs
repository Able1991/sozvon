using System.Collections.Concurrent;
using System.Globalization;
using Sozvon.Core.Foundation;
using Sozvon.Core.Settings;

namespace Sozvon.Core.Calls;

/// <summary>
/// A call for the list: everything comes from call.json. The folder name is parsed only for old calls without it.
/// </summary>
public sealed class Call
{
    private const string Dot = " · ";

    public required string Dir { get; init; }
    public required string CallId { get; set; }
    public DateTimeOffset? Date { get; set; }

    /// <summary>Topic, otherwise project; empty when neither is known, and the app shows its localized "Call".</summary>
    public string Title { get; set; } = "";

    public string Project { get; set; } = "";
    public string Topic { get; set; } = "";
    public IReadOnlyList<SpeechLanguage> Languages { get; set; } = [];

    /// <summary>Who took part, comma-separated: <c>participants</c>, else the typed <c>names</c>.</summary>
    public string People { get; set; } = "";

    /// <summary>call.json <c>participants</c> as stored; null for a call that has none yet.</summary>
    public IReadOnlyList<string>? Participants { get; set; }

    public double Duration { get; set; }
    public long Bytes { get; set; }
    public bool HasTranscript { get; init; }
    public bool HasSummary { get; init; }
    public bool HasAudio { get; init; }
    public CallInfo Info { get; set; } = new();
    public CallStatus? Status { get; set; }
    public IReadOnlyList<CallNote> Notes { get; set; } = [];
    public bool InfoPending { get; set; }
    public string? SummaryWarning { get; set; }
    public bool IsDemo { get; set; }
    public bool IsLegacy { get; init; }

    public string TranscriptPath => Path.Combine(Dir, "transcript.md");
    public string SummaryPath => Path.Combine(Dir, "summary.md");
    public string LogPath => Path.Combine(Dir, "process.log");
    public string DurationText => Clock((int)Duration);

    /// <summary>"2026-11-04 15-01" at the start of the text becomes a local time; otherwise null.</summary>
    public static DateTimeOffset? ParseId(string text)
    {
        if (text.Length < 16) return null;
        var s = text.AsSpan(0, 16);
        if (s[4] != '-' || s[7] != '-' || s[10] != ' ' || s[13] != '-') return null;
        if (Digits(s[..4]) is not { } y || Digits(s[5..7]) is not { } mo || Digits(s[8..10]) is not { } d
            || Digits(s[11..13]) is not { } h || Digits(s[14..16]) is not { } mi) return null;
        if (y < 1 || mo is < 1 or > 12 || d < 1 || d > DateTime.DaysInMonth(y, mo) || h > 23 || mi > 59) return null;
        return new DateTimeOffset(new DateTime(y, mo, d, h, mi, 0, DateTimeKind.Local));
    }

    /// <summary>"12:34" or "1:02:03"; <paramref name="empty"/> for zero.</summary>
    public static string Clock(int seconds, string empty = "")
    {
        if (seconds <= 0) return empty;
        return seconds >= 3600
            ? string.Create(CultureInfo.InvariantCulture, $"{seconds / 3600}:{seconds / 60 % 60:00}:{seconds % 60:00}")
            : string.Create(CultureInfo.InvariantCulture, $"{seconds / 60}:{seconds % 60:00}");
    }

    /// <summary>Loads a call folder; null for a folder that is not a call.</summary>
    /// <param name="projects">Short project names by slug.</param>
    /// <param name="withSize">Compute the folder size, which walks every file; otherwise <see cref="Bytes"/> is 0.</param>
    public static Call? Load(string dir, IReadOnlyDictionary<string, string>? projects = null, CallInfo? defaults = null, bool withSize = false)
    {
        var name = Path.GetFileName(dir);
        bool Has(string file) => File.Exists(Path.Combine(dir, file));
        var call = new Call
        {
            Dir = dir,
            CallId = CallFolder.IdFromName(name),
            HasTranscript = Has("transcript.md"),
            HasSummary = Has("summary.md"),
            HasAudio = Has("mic.m4a") || Has("system.m4a"),
            IsLegacy = !Has(CallFile.Name),
            Info = defaults ?? new CallInfo(),
        };
        if (call.IsLegacy)
        {
            call.Date = ParseId(name);
            if (call.Date is null && !Has("meta.json")) return null;
            call.LoadLegacy(name);
        }
        else
        {
            call.LoadFromFile(projects ?? new Dictionary<string, string>(), defaults);
        }
        call.Title = call.Topic.Length > 0 ? call.Topic : call.Project;
        if (withSize) call.Bytes = FolderSizeCache.Shared.Size(dir);
        return call;
    }

    /// <summary>All calls in the folder, newest first.</summary>
    public static List<Call> All(string root, IReadOnlyDictionary<string, string>? projects = null, CallInfo? defaults = null, bool withSizes = false)
    {
        var calls = CallFile.Folders(root).Select(d => Load(d, projects, defaults, withSizes)).OfType<Call>().ToList();
        calls.Sort((a, b) =>
        {
            var byDate = Nullable.Compare(b.Date, a.Date);
            return byDate != 0 ? byDate : CompareNumeric(b.CallId, a.CallId);
        });
        return calls;
    }

    /// <summary>Bytes in the call folder, without the engine's working files.</summary>
    internal static long FolderSize(string dir)
    {
        long bytes = 0;
        foreach (var file in Directory.EnumerateFiles(dir))
            bytes += new FileInfo(file).Length;
        foreach (var sub in Directory.EnumerateDirectories(dir))
            if (Path.GetFileName(sub) != WorkFiles.Folder) bytes += FolderSize(sub);
        return bytes;
    }

    private void LoadFromFile(IReadOnlyDictionary<string, string> projects, CallInfo? defaults)
    {
        var c = CallFile.Read(Dir);
        if (c.Text("id") is { Length: > 0 } id) CallId = id;
        Date = ParseId(CallId) ?? Iso8601.Parse(c.Text("created_at"));
        Info = CallFile.Info(c, defaults);
        Status = CallStatuses.FromKey(c.Text("status"));
        Notes = CallNotes.List(c);
        InfoPending = PendingInfo.IsPending(c);
        SummaryWarning = CallWarnings.Summary(c);
        IsDemo = c.Flag("demo") == true;
        Duration = AudioTimes.From(c.Object("audio")).Duration;
        Languages = c.Text("languages") is { } languages ? SpeechLanguages.Parse(languages) : [];
        Topic = Info.Topic.Length > 0 ? Info.Topic : Info.Terms;
        if (Info.Profile.Length > 0)
        {
            var remote = c.Text("project_title") is { Length: > 0 } t ? t : null;
            Project = projects.GetValueOrDefault(Info.Profile) ?? remote ?? Info.Profile;
        }
        Participants = CallParticipants.Stored(c);
        People = string.Join(", ", Participants ?? TextRules.SplitList(Info.Names));
        FillFromFolderName(Path.GetFileName(Dir), projects.ContainsKey(Info.Profile) || c.Text("project_title") is { Length: > 0 });
    }

    /// <summary>
    /// A call.json without a topic, or with a project this computer doesn't have (calls copied from another one): the
    /// folder name the engine built from them, "id · Project · Topic · People", still has them.
    /// </summary>
    private void FillFromFolderName(string name, bool projectKnown)
    {
        var hasProject = Info.Profile.Length > 0;
        if (Topic.Length > 0 && (projectKnown || !hasProject)) return;
        var (project, topic) = FolderNameParts(name, hasProject, Participants ?? TextRules.SplitList(Info.Names));
        if (Topic.Length == 0) Topic = topic;
        if (hasProject && !projectKnown && project.Length > 0) Project = project;
    }

    /// <summary>Project and topic from a name <see cref="CallFolderName"/> built; empty where the name has none.</summary>
    internal static (string Project, string Topic) FolderNameParts(string name, bool hasProject, IReadOnlyList<string> people)
    {
        var parts = name.Split(Dot).Skip(1).ToList();
        var project = hasProject && parts.Count > 0 ? parts[0] : "";
        var rest = parts.Skip(hasProject ? 1 : 0).ToList();
        var names = TextRules.ShortPeople(people.Where(n => n.Trim().Length > 0).ToList(), 3);
        if (rest.Count > 0 && names.Length > 0 && rest[^1] == names) rest.RemoveAt(rest.Count - 1);
        return (project, rest.Count > 0 ? rest[0] : "");
    }

    private void LoadLegacy(string name)
    {
        if (JsonFile.Read(Path.Combine(Dir, "meta.json")) is { } meta) Duration = AudioTimes.From(meta).Duration;
        var parts = name.Split(Dot).Skip(1).ToArray();
        Project = parts.Length >= 2 ? parts[0] : "";
        Topic = parts.Length >= 2 ? parts[1] : parts.Length == 1 ? parts[0] : "";
        People = parts.Length >= 3 ? string.Join(Dot, parts.Skip(2)) : "";
        Info = Info with { Names = People };
    }

    private static int? Digits(ReadOnlySpan<char> s)
    {
        foreach (var ch in s)
            if (!char.IsAsciiDigit(ch)) return null;
        return int.Parse(s, CultureInfo.InvariantCulture);
    }

    /// <summary>"…15-01-2" is newer than "…15-01", and "-10" newer than "-9".</summary>
    private static int CompareNumeric(string a, string b) =>
        string.Compare(a, b, CultureInfo.InvariantCulture, CompareOptions.NumericOrdering);
}

/// <summary>Call folder size keyed by (path, folder time). An atomic write inside changes the folder time.</summary>
public sealed class FolderSizeCache
{
    public static readonly FolderSizeCache Shared = new();

    private readonly ConcurrentDictionary<string, (DateTime Time, long Bytes)> _entries = new();

    public long Size(string dir)
    {
        var time = Directory.GetLastWriteTimeUtc(dir);
        if (_entries.TryGetValue(dir, out var entry) && entry.Time == time) return entry.Bytes;
        var bytes = Call.FolderSize(dir);
        _entries[dir] = (time, bytes);
        return bytes;
    }
}
