using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Sozvon.Core.Foundation;

namespace Sozvon.Core.Calls;

/// <summary>One saved voice. The engine owns the files; the app only reads them.</summary>
public sealed record VoiceRecord(string Id, string Name, string Profile = "", bool Me = false, double Seconds = 0, string UpdatedAt = "")
{
    /// <summary>From a record's JSON object; null without an id or a name.</summary>
    public static VoiceRecord? From(JsonObject o)
    {
        if (o.Text("id") is not { Length: > 0 } id || o.Text("name") is not { } name) return null;
        return new VoiceRecord(id, name, o.Text("profile") ?? "", o.Flag("me") ?? false, o.Number("seconds") ?? 0, o.Text("updated_at") ?? "");
    }
}

/// <summary>Voice prints: reading the records, the arguments of bin\voice.py, and which names get a voice print.</summary>
public static partial class Voices
{
    public const string Script = "voice.py";

    private static readonly Dictionary<char, string> Latin = new()
    {
        ['а'] = "a", ['б'] = "b", ['в'] = "v", ['г'] = "g", ['д'] = "d", ['е'] = "e", ['ё'] = "e", ['ж'] = "zh", ['з'] = "z",
        ['и'] = "i", ['й'] = "y", ['к'] = "k", ['л'] = "l", ['м'] = "m", ['н'] = "n", ['о'] = "o", ['п'] = "p", ['р'] = "r",
        ['с'] = "s", ['т'] = "t", ['у'] = "u", ['ф'] = "f", ['х'] = "h", ['ц'] = "c", ['ч'] = "ch", ['ш'] = "sh", ['щ'] = "sch",
        ['ъ'] = "", ['ы'] = "y", ['ь'] = "", ['э'] = "e", ['ю'] = "yu", ['я'] = "ya",
    };

    /// <summary>Every readable record, sorted by name. Unreadable or foreign files are skipped.</summary>
    public static List<VoiceRecord> All(string voicesFolder)
    {
        if (!Directory.Exists(voicesFolder)) return [];
        var records = Directory.GetFiles(voicesFolder, "*.json")
            .Where(f => !Path.GetFileName(f).StartsWith('.'))
            .Select(JsonFile.Read).OfType<JsonObject>().Select(VoiceRecord.From).OfType<VoiceRecord>().ToList();
        records.Sort((a, b) =>
        {
            var byName = string.Compare(a.Name, b.Name, CultureInfo.CurrentCulture, CompareOptions.NumericOrdering);
            return byName != 0 ? byName : string.CompareOrdinal(a.Id, b.Id);
        });
        return records;
    }

    /// <summary>The user's own sample, if recorded.</summary>
    public static VoiceRecord? Me(IEnumerable<VoiceRecord> records) =>
        records.Where(r => r.Me).OrderBy(r => r.UpdatedAt, StringComparer.Ordinal).LastOrDefault();

    public static List<VoiceRecord> ForProfile(IEnumerable<VoiceRecord> records, string slug) =>
        records.Where(r => !r.Me && r.Profile == slug).ToList();

    public static VoiceRecord? Voice(string name, string profile, IEnumerable<VoiceRecord> records)
    {
        var n = name.Trim();
        return records.FirstOrDefault(r => !r.Me && r.Profile == profile && r.Name.Equals(n, StringComparison.OrdinalIgnoreCase));
    }

    public static List<string> EnrollFile(string name, string profile, bool me, bool add, string file)
    {
        var args = new List<string> { "enroll", "--name", name };
        if (profile.Length > 0) args.AddRange(["--profile", profile]);
        if (me) args.Add("--me");
        if (add) args.Add("--add");
        args.AddRange(["--file", file]);
        return args;
    }

    public static List<string> EnrollCall(string name, string profile, string dir, string speaker)
    {
        var args = new List<string> { "enroll", "--name", name };
        if (profile.Length > 0) args.AddRange(["--profile", profile]);
        args.AddRange(["--call", dir, "--speaker", speaker]);
        return args;
    }

    public static List<string> Delete(string id) => ["delete", "--id", id];

    public static List<string> DeleteAll() => ["delete", "--all"];

    /// <summary>Named speakers of a call whose voice is not saved yet.</summary>
    public static List<string> Unsaved(IEnumerable<string> speakers, string profile, IReadOnlyCollection<VoiceRecord> records, string me)
    {
        var own = records.Where(r => r.Me).Select(r => r.Name).ToList();
        return NamesToEnroll(speakers, me, own)
            .Where(n => !records.Any(r => !r.Me && (r.Profile == profile || r.Profile.Length == 0)
                                          && r.Name.Equals(n, StringComparison.OrdinalIgnoreCase)))
            .ToList();
    }

    /// <summary>Labels the engine gives when it does not know who speaks, and the user's own name.</summary>
    public static bool IsGenericLabel(string name, string me = "")
    {
        var n = name.Trim();
        if (n.Length == 0 || SameName(n, me)) return true;
        var lower = n.ToLowerInvariant();
        if (lower is "я" or "me") return true;
        if (lower.EndsWith("+ собеседники", StringComparison.Ordinal) || lower.EndsWith("+ others", StringComparison.Ordinal)) return true;
        return GenericLabel().IsMatch(lower);
    }

    /// <summary>Names worth enrolling after a rename: not generic, not the user, each once.</summary>
    public static List<string> NamesToEnroll(IEnumerable<string> names, string me = "", IReadOnlyCollection<string>? own = null)
    {
        var seen = new HashSet<string>();
        return names.Select(n => n.Trim())
            .Where(n => !IsGenericLabel(n, me) && !(own ?? []).Any(o => SameName(n, o)) && seen.Add(n.ToLowerInvariant()))
            .ToList();
    }

    /// <summary>One name, whatever the case and the alphabet ("Борис", "boris"). The engine's voices.same_name.</summary>
    public static bool SameName(string a, string b)
    {
        var (x, y) = (ToLatin(a), ToLatin(b));
        return x.Length > 0 && x == y;
    }

    private static string ToLatin(string text)
    {
        var latin = new StringBuilder();
        foreach (var ch in TextRules.Squeeze(text.ToLowerInvariant()))
        {
            if (Latin.TryGetValue(ch, out var mapped)) latin.Append(mapped);
            else latin.Append(ch);
        }
        return latin.ToString();
    }

    [GeneratedRegex(@"^(собеседник|спикер|speaker)([ _]*([0-9]+|\?|n))?$")]
    private static partial Regex GenericLabel();
}
