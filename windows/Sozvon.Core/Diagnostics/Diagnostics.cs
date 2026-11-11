// Diagnostics for support: a list of checks and the scrubbed logs, as the Mac's SozvonCore/Diagnostics.swift.
//
// Privacy rule: the folder never holds transcripts, summaries, audio, call.json, .env, tokens, passwords or voice prints.
// Only a fixed list of log files goes in (never a directory scan), every file is scrubbed, and process.log and mcp.log are
// cut down to the lines that cannot carry what was said (see DiagnosticScrub.ProcessLog).

using System.Text;
using System.Text.RegularExpressions;
using Sozvon.Core.Calls;

namespace Sozvon.Core.Diagnostics;

public enum DiagnosticState { Ok, Warning, Problem }

/// <param name="Hint">One line: what is wrong and what to do, or the value for a good check.</param>
public sealed record DiagnosticCheck(string Id, string Title, DiagnosticState State, string Hint);

public static class DiagnosticChecks
{
    /// <summary>Under 1 GB free a model or an environment update fails; under 5 GB is worth a warning.</summary>
    public const long LowDisk = 5_000_000_000, CriticalDisk = 1_000_000_000;

    public static DiagnosticState DiskState(long? freeBytes) => freeBytes switch
    {
        null => DiagnosticState.Warning,
        < CriticalDisk => DiagnosticState.Problem,
        < LowDisk => DiagnosticState.Warning,
        _ => DiagnosticState.Ok,
    };

    /// <summary>Free space on the drive of <paramref name="path"/>, or null.</summary>
    public static long? FreeBytes(string path)
    {
        try
        {
            return new DriveInfo(Path.GetPathRoot(Path.GetFullPath(path))!).AvailableFreeSpace;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return null;
        }
    }

    /// <summary>The checks as plain text, one per line: <c>[state] title: hint</c>.</summary>
    public static string Text(IEnumerable<DiagnosticCheck> checks) =>
        string.Concat(checks.Select(c => $"[{c.State.ToString().ToLowerInvariant()}] {c.Title}: {c.Hint}\n"));
}

/// <summary>Rewrites log text for support: the profile folder to <c>~</c>, call folder names to their date id, secrets removed.</summary>
public sealed partial class DiagnosticScrub
{
    private readonly Regex[] _homes;

    /// <summary>Longest first, so a folder named like another's prefix is replaced whole.</summary>
    private readonly (string Name, string Id)[] _folders;

    /// <param name="homes">The profile folder, in whatever forms a log may hold it (the real one and USERPROFILE).</param>
    public DiagnosticScrub(IEnumerable<string> homes, IEnumerable<string> callFolders)
    {
        _homes = homes.Select(h => h.TrimEnd('\\', '/')).Where(h => h.Length > 3).Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderByDescending(h => h.Length).Select(HomePattern).ToArray();
        _folders = callFolders.Distinct().Where(n => n.Length >= 4).Select(n => (Name: n, Id: Id(n))).Where(f => f.Name != f.Id)
            .OrderByDescending(f => f.Name.Length).ToArray();
    }

    public DiagnosticScrub(string home, IEnumerable<string> callFolders) : this([home], callFolders)
    {
    }

    /// <summary>
    /// "2026-11-04 15-01 · Acme · pricing" becomes "2026-11-04 15-01". A folder without a date in its name is just "call":
    /// the first characters of its name would be the title.
    /// </summary>
    public static string Id(string folderName) => Call.ParseId(folderName) is not null ? CallFolder.IdFromName(folderName) : "call";

    /// <summary>
    /// "C:\Users\anna" in any spelling a log uses: either slash, doubled backslashes (a Python repr, JSON), any case; and only
    /// at the end of a path part, so "C:\Users\anna2" stays.
    /// </summary>
    private static Regex HomePattern(string home) =>
        new(string.Join(@"(?:\\\\|\\|/)", home.Split('\\', '/').Select(Regex.Escape)) + "(?![A-Za-z0-9_-])", RegexOptions.IgnoreCase);

    // Privacy filter: too much removed is fine, too little is not. A call id starts the match wherever it stands; what follows
    // is its title up to a delimiter, and nothing but the delimiter ends it (never "(", ")", ",", "'", "·").
    // Plain name: a slash or backslash, ":" (Windows never leaves them in a folder name) or the end of the line.
    [GeneratedRegex(@"([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}-[0-9]{2}(?:-[0-9]+)?) [^/\\:\n]+(?=[/\\:]|$)", RegexOptions.Multiline)]
    private static partial Regex DateFolder();

    // Percent-encoded name (a file:// URL): "/", whitespace or a quote, or the end of the text. A ")" closing a surrounding
    // expression goes with the title.
    [GeneratedRegex(@"([0-9]{4}-[0-9]{2}-[0-9]{2})%20([0-9]{2}-[0-9]{2}(?:-[0-9]+)?)(?:%20[^/\\\s""]*)?")]
    private static partial Regex EncodedDateFolder();

    private static readonly (Regex Pattern, string Replacement)[] Secrets =
    [
        (new Regex(@"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]{8,}"), "$1[removed]"),
        (new Regex(@"(?i)\b([\w.-]*(?:token|secret|password|passwd|pwd|api[_-]?key|authorization|cookie)[\w.-]*)([""']?\s*[:=]\s*[""']?)[^\s""',;}]+"),
         "$1$2[removed]"),
        (new Regex(@"\b(?:sk-[A-Za-z0-9_-]{10,}|cfut_[A-Za-z0-9]{10,}|hf_[A-Za-z0-9]{10,}|gh[pousr]_[A-Za-z0-9]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{20,})"),
         "[removed]"),
        (new Regex(@"\b[A-Fa-f0-9]{32,}\b"), "[removed]"),
        (new Regex(@"\b[A-Za-z0-9_-]{40,}\b"), "[removed]"),
        (new Regex(@"[\w.+-]+@[\w-]+\.[\w.-]+"), "[removed]"),
    ];

    public string Text(string input)
    {
        var s = input.Replace("\r\n", "\n");
        // The marker keeps the text after a listed folder: its title is already gone, so the next pass must not take that text for one.
        const string done = "\u0001";
        foreach (var (name, id) in _folders) s = s.Replace(name, id + done, StringComparison.Ordinal);
        // A folder that was renamed or deleted is not in the list: a call id loses its title all the same.
        s = DateFolder().Replace(s, "$1");
        s = s.Replace(done, "", StringComparison.Ordinal);
        s = EncodedDateFolder().Replace(s, "$1 $2");
        foreach (var home in _homes) s = home.Replace(s, "~");
        foreach (var (pattern, replacement) in Secrets) s = pattern.Replace(s, replacement);
        return s;
    }

    // The patterns below match the engine's own log lines in both languages (engine/sozvon_engine/i18n.py).

    /// <summary>
    /// A line the engine writes whose variable part is a name, a project, an assistant's error or anything else that can
    /// repeat the conversation: only the label (group 1) stays.
    /// </summary>
    private static readonly Regex[] Stubs = Compile(
        "^(project|профиль): ",
        "^(added to project|в проект) ",
        "^(speaker names|имена собеседников)",
        "^(voice|голос): ",
        "^(voice prints failed|образцы голосов не сработали)",
        "^(summary failed|саммари не получилось)",
        "^((?:microphone )?diarization failed|диаризация(?: микрофона)? не удалась)",
        "^(echo: cancellation failed|эхо: подавление не удалось)",
        "^(could not save the cleaned microphone|не получилось сохранить очищенный микрофон)",
        "^(could not make the listening file|не получилось сделать файл для прослушивания)",
        "^(invalid project name|недопустимое имя проекта)");

    /// <summary>Lines made of fixed words and numbers only (file and model names, counts), matched whole.</summary>
    private static readonly Regex[] Keeps = Compile(
        @"^[\w.-]+: (?:~\d+ s of speech|речи ~\d+ с)$",
        @"^[\w.-]+: (?:the track is very quiet|дорожка очень тихая), .*\d+ (?:dB|дБ)$",
        @"^(?:transcribing|транскрибация) \w+(?: \([\w./:-]+\))? …$",
        @"^\w+: \d+ (?:segments|сегментов)$",
        @"^\w+: (?:language|язык) [A-Za-z-]+ \(\d+% .*\)$",
        @"^\w+: (?:phrases in another language|фраз на другом языке): \d+$",
        @"^(?:microphone diarization|diarization|диаризация микрофона|диаризация): (?:\d+ speakers|собеседников \d+)$",
        "^(?:summary|саммари) …$",
        @"^(?:summary|саммари): [\w .-]+ \([\w .-]+\)$",
        @"^(?:done|готово): .+ \(\d+ (?:paragraphs|реплик)\)$",
        @"^(?:echo: removed ~-?\d+ dB from the microphone \(delay \d+ ms\)|эхо: из микрофона убрано ~-?\d+ дБ \(задержка \d+ мс\))$",
        "^(?:echo: the microphone is left as is, [^:]+|эхо: микрофон оставлен как есть, [^:]+)$",
        @"^(?:listening file ready in \d+ s|файл для прослушивания готов за \d+ с)$",
        @"^(?:speaker echo: dropped \d+ microphone segments|эхо из динамиков: выкинуто \d+ сегментов микрофона)$",
        @"^(?:system audio was missing for \d+ s, separating speakers on the microphone there|системный звук пропадал на \d+ с, там собеседники разводятся по микрофону)$",
        "^(?:the prompt with terms confused the model, retrying with a short prompt|подсказка с терминами сбила модель, повтор с короткой подсказкой)$",
        @"^(?:model [\w./:-]+: no Whisper prompt, project terms are not used, only replacements|модель [\w./:-]+: без подсказки Whisper, термины проекта не используются, только автозамены)$",
        "^(?:GigaAM understands only Russian: other languages will be recognized poorly|GigaAM понимает только русский: нерусская речь распознается плохо)$",
        "^(?:another run is still processing this call, waiting for it to end|этот звонок ещё обрабатывает другой запуск, жду, пока он закончится)$",
        @"^voices: \d+ voice print\(s\) of another model skipped \(they stay saved\)$");

    /// <summary>
    /// mcp.log is the MCP server's stderr. Its errors can quote what an assistant sent: a search query (SQLite's FTS syntax
    /// error repeats a fragment of it), a tool argument (validation errors print the input). So it is filtered closed like
    /// process.log: the start marker, uvicorn's fixed status lines and traceback scaffolding stay, lines that carry an
    /// exception message keep their label only, the rest is dropped.
    /// </summary>
    private static readonly Regex[] McpStubs = Compile(
        "^(sozvon: search index unavailable, substring search)",
        "^(sozvon: note not sent to the server yet)",
        @"^(ERROR:\s+Exception in ASGI application)");

    private static readonly Regex[] McpKeeps = Compile(
        @"^=== \S+ server\.py --http$",
        @"^(?:INFO|WARNING):\s+(?:Started server process \[\d+\]|Waiting for application startup\.|Application startup complete\.|Uvicorn running on http://127\.0\.0\.1:\d+(?: \(Press CTRL\+C to quit\))?|Finished server process \[\d+\]|Shutting down)$",
        @"^ERROR:\s+\[Errno 48\] error while attempting to bind on address \('127\.0\.0\.1', \d+\): (?:\[errno 48\] )?address already in use$",
        // Windows' wording of the same: the port is taken.
        @"^ERROR:\s+\[Errno 10048\] error while attempting to bind on address \('127\.0\.0\.1', \d+\): (?:\[winerror 10048\] )?only one usage of each socket address \(protocol/network address/port\) is normally permitted$");

    /// <summary>Traceback scaffolding shared by every log with Python output (the exception message itself never stays).</summary>
    private static readonly Regex[] TraceKeeps = Compile(
        @"^Traceback \(most recent call last\):$",
        @"^\s+File "".*"", line \d+(?:, in \S+)?$",
        "^(?:During handling of the above exception, another exception occurred:|The above exception was the direct cause of the following exception:)$");

    [GeneratedRegex(@"^([A-Za-z_][\w.]*(?:Error|Exception|Exit|Interrupt)):(?: .*)?$")]
    private static partial Regex ExceptionLine();

    [GeneratedRegex(@"^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\] (.*)$")]
    private static partial Regex Stamped();

    [GeneratedRegex(@"^RESULT: (ok|error [0-9]+)(?: .*)?$")]
    private static partial Regex Result();

    private static Regex[] Compile(params string[] patterns) => patterns.Select(p => new Regex(p)).ToArray();

    /// <summary>
    /// process.log holds the engine's output. Most of it is safe counts, but some lines carry speaker names, the project and
    /// what the assistant answered or choked on, and tracebacks can quote anything. So the filter is closed by default: a
    /// line stays only when it matches a known shape made of fixed words and numbers; a line with a variable part keeps its
    /// label; everything else is counted and dropped.
    /// </summary>
    public string ProcessLog(string input) => Filter(input, Stubs, Keeps);

    /// <summary>The MCP server's log, filtered closed (see McpStubs).</summary>
    public string McpLog(string input) => Filter(input, McpStubs, McpKeeps);

    private string Filter(string input, Regex[] stubs, Regex[] keeps)
    {
        var output = new List<string>();
        var omitted = 0;
        foreach (var line in input.Split(['\n', '\r'], StringSplitOptions.RemoveEmptyEntries))
        {
            var prefix = "";
            var body = line;
            if (Stamped().Match(line) is { Success: true } stamped)
            {
                prefix = line[..11];
                body = stamped.Groups[1].Value;
            }
            else if (Result().Match(line) is { Success: true } result)
            {
                var kind = result.Groups[1].Value;
                output.Add("RESULT: " + kind + (kind.StartsWith("error", StringComparison.Ordinal) ? " [message removed]" : ""));
                continue;
            }
            else if (ExceptionLine().Match(line) is { Success: true } exception)
            {
                output.Add(exception.Groups[1].Value + ": [removed]");
                continue;
            }
            if (stubs.Select(re => re.Match(body)).FirstOrDefault(m => m.Success) is { } stub)
            {
                output.Add(prefix + stub.Groups[1].Value + ": [removed]");
            }
            else if (keeps.Concat(TraceKeeps).Any(re => re.IsMatch(body)))
            {
                output.Add(Text(prefix + body));
            }
            else
            {
                omitted++;
            }
        }
        if (omitted > 0) output.Add($"[{omitted} lines omitted]");
        return output.Count == 0 ? "" : string.Join("\n", output) + "\n";
    }
}

/// <summary>Which files go to support, and how they are written: "Show Logs" puts them, scrubbed, in a folder.</summary>
public static class DiagnosticArchive
{
    /// <summary>One log goes in at most this long (its end: the newest lines).</summary>
    public const int MaxLogBytes = 200_000;

    /// <summary>How many calls' process.log go in.</summary>
    public const int ProcessLogCount = 5;

    private const string EarlierCut = "[earlier lines cut]";
    private static readonly UTF8Encoding Utf8 = new(false);

    /// <param name="Name">The file name in the folder.</param>
    public sealed record Item(string Name, string Path, bool IsProcessLog)
    {
        /// <summary>The MCP server's log: filtered closed, like process.log.</summary>
        public bool IsMcpLog => Name == "mcp.log";
    }

    /// <summary>
    /// The named logs and where they are: the recorder's in <c>&lt;data&gt;\Logs</c>, the engine's in the data folder, among
    /// them assistant.log, the engine's journal of assistant CLI calls (llm.journal: the request is masked there).
    /// </summary>
    private static IEnumerable<(string Folder, string Name)> NamedLogs(string logs, string data) =>
        [(logs, "recorder.log"), (logs, "cloudflare.log"), (data, "setup.log"), (data, "mcp.log"), (data, "assistant.log")];

    /// <summary>
    /// The only files that may go in: the named logs and the process.log of the newest calls. Nothing else from these
    /// folders is ever looked at, so a transcript, call.json or .env cannot slip in.
    /// </summary>
    public static IReadOnlyList<Item> Selection(string logs, string data, string calls, int count = ProcessLogCount)
    {
        var items = new List<Item>();
        foreach (var (folder, name) in NamedLogs(logs, data))
        {
            var path = System.IO.Path.Combine(folder, name);
            if (File.Exists(path)) items.Add(new Item(name, path, false));
        }
        var found = CallFolders(calls)
            .Select(dir => (Dir: dir, Log: System.IO.Path.Combine(dir, "process.log")))
            .Where(f => File.Exists(f.Log))
            .Select(f => (f.Dir, f.Log, Time: File.GetLastWriteTimeUtc(f.Log)))
            .OrderByDescending(f => f.Time)
            .Take(count);
        var used = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (dir, log, _) in found)
        {
            var name = "process-" + DiagnosticScrub.Id(System.IO.Path.GetFileName(dir));
            var unique = name + ".log";
            for (var n = 2; !used.Add(unique); n++) unique = $"{name} ({n}).log";
            items.Add(new Item(unique, log, true));
        }
        return items;
    }

    /// <summary>Names of all call folders: the scrubber turns them into ids.</summary>
    public static IReadOnlyList<string> CallFolderNames(string calls) => CallFolders(calls).Select(System.IO.Path.GetFileName).OfType<string>().ToList();

    private static IEnumerable<string> CallFolders(string calls)
    {
        try
        {
            return Directory.Exists(calls) ? Directory.GetDirectories(calls) : [];
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return [];
        }
    }

    /// <summary>The end of a file as text, from a line start; reads at most <paramref name="limit"/> bytes. A log being written is fine.</summary>
    public static string Tail(string path, int limit)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var cut = stream.Length > limit;
            if (cut) stream.Seek(-limit, SeekOrigin.End);
            using var reader = new StreamReader(stream, Utf8, detectEncodingFromByteOrderMarks: !cut);
            var text = reader.ReadToEnd();
            if (!cut) return text;
            var newline = text.IndexOf('\n');
            return EarlierCut + "\n" + (newline >= 0 ? text[(newline + 1)..] : "");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return "";
        }
    }

    /// <summary>Cut to <see cref="MaxLogBytes"/> from the end, at a line start.</summary>
    public static string Limited(string text)
    {
        var bytes = Utf8.GetBytes(text);
        if (bytes.Length <= MaxLogBytes) return text;
        var s = Utf8.GetString(bytes, bytes.Length - MaxLogBytes, MaxLogBytes);
        var newline = s.IndexOf('\n');
        if (newline >= 0) s = s[(newline + 1)..];
        return s.StartsWith(EarlierCut, StringComparison.Ordinal) ? s : EarlierCut + "\n" + s;
    }

    /// <summary>checks.txt and the selected logs, scrubbed, written into <paramref name="folder"/>. Returns their names.</summary>
    public static IReadOnlyList<string> WriteFiles(IEnumerable<DiagnosticCheck> checks, string logs, string data, string calls,
                                                   DiagnosticScrub scrub, string folder)
    {
        var names = new List<string> { "checks.txt" };
        File.WriteAllText(System.IO.Path.Combine(folder, "checks.txt"), scrub.Text(DiagnosticChecks.Text(checks)), Utf8);
        foreach (var item in Selection(logs, data, calls))
        {
            var raw = Tail(item.Path, MaxLogBytes * 5);
            var clean = item.IsProcessLog ? scrub.ProcessLog(raw) : item.IsMcpLog ? scrub.McpLog(raw) : scrub.Text(raw);
            File.WriteAllText(System.IO.Path.Combine(folder, item.Name), Limited(clean), Utf8);
            names.Add(item.Name);
        }
        return names;
    }

    /// <summary>
    /// "Show Logs": the files the Mac's diagnostics zip holds, scrubbed the same way, in <paramref name="folder"/> (emptied
    /// first) to look at in Explorer and send. Run it off the UI thread.
    /// </summary>
    public static IReadOnlyList<string> WriteFolder(IEnumerable<DiagnosticCheck> checks, string logs, string data, string calls,
                                                    IEnumerable<string> homes, string folder)
    {
        if (Directory.Exists(folder))
        {
            // Only what an earlier "Show Logs" wrote: files at the top. A folder inside (or a link) is never walked into.
            foreach (var file in Directory.GetFiles(folder)) File.Delete(file);
        }
        Directory.CreateDirectory(folder);
        return WriteFiles(checks, logs, data, calls, new DiagnosticScrub(homes, CallFolderNames(calls)), folder);
    }
}
