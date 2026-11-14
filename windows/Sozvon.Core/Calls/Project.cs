using System.Text;
using System.Text.Json.Nodes;
using Sozvon.Core.Foundation;
using Sozvon.Core.Settings;

namespace Sozvon.Core.Calls;

public enum ProjectTitleProblem { Empty, Duplicate }

/// <summary>A project: profiles/&lt;slug&gt;.json in the data folder.</summary>
public sealed record Project(string Slug, string Title, string Context = "", IReadOnlyList<string>? PeopleList = null, IReadOnlyList<string>? TermsList = null)
{
    private const int Schema = 1;

    private static readonly Dictionary<char, string> Latin = new()
    {
        ['а'] = "a", ['б'] = "b", ['в'] = "v", ['г'] = "g", ['д'] = "d", ['е'] = "e", ['ё'] = "e", ['ж'] = "zh", ['з'] = "z",
        ['и'] = "i", ['й'] = "y", ['к'] = "k", ['л'] = "l", ['м'] = "m", ['н'] = "n", ['о'] = "o", ['п'] = "p", ['р'] = "r",
        ['с'] = "s", ['т'] = "t", ['у'] = "u", ['ф'] = "f", ['х'] = "h", ['ц'] = "c", ['ч'] = "ch", ['ш'] = "sh", ['щ'] = "sch",
        ['ъ'] = "", ['ы'] = "y", ['ь'] = "", ['э'] = "e", ['ю'] = "yu", ['я'] = "ya",
    };

    public IReadOnlyList<string> People => PeopleList ?? [];
    public IReadOnlyList<string> Terms => TermsList ?? [];

    /// <summary>Languages of the project's calls (profile <c>languages</c>, "ru,en"); empty: the settings' ones.</summary>
    public IReadOnlyList<SpeechLanguage> Languages { get; init; } = [];

    /// <summary>The editor's "Call language": one language, or Russian and English together, as on the Mac.</summary>
    public static readonly IReadOnlyList<string> LanguageChoices = ["ru", "en", "ru,en", "uk", "de", "es"];

    /// <summary>The languages a call takes when <paramref name="project"/> is picked: its own, or <paramref name="current"/> without them.</summary>
    public static IReadOnlyList<SpeechLanguage> CallLanguages(Project? project, IReadOnlyList<SpeechLanguage> current) =>
        project is { Languages.Count: > 0 } p ? p.Languages : current;

    /// <summary>Short name for the folder name and the list: "Acme / Holding" becomes "Acme".</summary>
    public string ShortTitle => Title.Split(" / ")[0];

    public static List<Project> All(string profilesFolder)
    {
        if (!Directory.Exists(profilesFolder)) return [];
        return Directory.GetFiles(profilesFolder, "*.json").Select(Load).OfType<Project>()
                        .OrderBy(p => p.Title.ToLowerInvariant(), StringComparer.Ordinal).ToList();
    }

    /// <summary>
    /// The editor's fields as they are saved: title and context trimmed (line breaks as "\n"), people and terms split on commas and line
    /// breaks. A new project (empty slug) gets a free file name from its title.
    /// </summary>
    public Project WithForm(string title, string context, string people, string terms, string profilesFolder)
    {
        var t = title.Trim();
        return this with
        {
            Slug = Slug.Length > 0 ? Slug : UniqueSlug(t, profilesFolder),
            Title = t,
            Context = context.Trim().ReplaceLineEndings("\n"),
            PeopleList = TextRules.SplitList(people),
            TermsList = TextRules.SplitList(terms),
        };
    }

    /// <summary>
    /// The same project as the pages show it, field by field: a record holding lists compares the lists by reference.
    /// </summary>
    public bool SameAs(Project other) =>
        Slug == other.Slug && Title == other.Title && Context == other.Context
        && People.SequenceEqual(other.People) && Terms.SequenceEqual(other.Terms) && Languages.SequenceEqual(other.Languages);

    /// <summary>Different people across the projects, ignoring case: the "10 человек" of the list's summary.</summary>
    public static int PeopleCount(IEnumerable<Project> list) =>
        list.SelectMany(p => p.People).Select(p => p.ToLowerInvariant()).Distinct().Count();

    public static Dictionary<string, string> Titles(IEnumerable<Project> list)
    {
        var titles = new Dictionary<string, string>();
        foreach (var p in list) titles.TryAdd(p.Slug, p.ShortTitle);
        return titles;
    }

    public static Project? Load(string path)
    {
        var slug = Path.GetFileNameWithoutExtension(path);
        if (!IsValidSlug(slug) || JsonFile.Read(path) is not { } o) return null;
        return new Project(slug, o.Text("title") ?? slug, o.Text("context") ?? "", o.Texts("people") ?? [], o.Texts("terms") ?? [])
        {
            Languages = SpeechLanguages.Parse(o.Text("languages") ?? ""),
        };
    }

    /// <summary>Why a title cannot be saved for the project <paramref name="slug"/> ("" for a new one); null when it can.</summary>
    public static ProjectTitleProblem? TitleProblem(string title, string slug, IEnumerable<Project> projects)
    {
        var t = title.Trim();
        if (t.Length == 0) return ProjectTitleProblem.Empty;
        var key = t.ToLowerInvariant();
        return projects.Any(p => p.Slug != slug && p.Title.Trim().ToLowerInvariant() == key) ? ProjectTitleProblem.Duplicate : null;
    }

    /// <summary>The contract's project name: only <c>[a-z0-9_-]{1,64}</c>.</summary>
    public static bool IsValidSlug(string s) =>
        s.Length is > 0 and <= 64 && s.All(ch => char.IsAsciiLetterLower(ch) || char.IsAsciiDigit(ch) || ch is '_' or '-');

    public static string Slugify(string text)
    {
        var mapped = new StringBuilder();
        foreach (var ch in text.ToLowerInvariant())
        {
            if (Latin.TryGetValue(ch, out var latin)) mapped.Append(latin);
            else if (char.IsAsciiLetterOrDigit(ch)) mapped.Append(ch);
            else mapped.Append('-');
        }
        var slug = string.Join('-', mapped.ToString().Split('-', StringSplitOptions.RemoveEmptyEntries));
        return slug.Length == 0 ? "project" : slug[..Math.Min(slug.Length, 40)];
    }

    /// <summary>A free file name for a new project: "acme", "acme-2", and so on.</summary>
    public static string UniqueSlug(string title, string profilesFolder)
    {
        var slugBase = Slugify(title);
        var slug = slugBase;
        for (var n = 2; File.Exists(Path.Combine(profilesFolder, slug + ".json")); n++) slug = $"{slugBase}-{n}";
        return slug;
    }

    /// <summary>Saves without losing other fields, under the lock the engine takes.</summary>
    public void Save(string profilesFolder)
    {
        Directory.CreateDirectory(profilesFolder);
        var path = Path.Combine(profilesFolder, Slug + ".json");
        FileLock.With(path, () =>
        {
            var o = JsonFile.Read(path) ?? [];
            o["schema"] = Schema;
            o["title"] = Title;
            o["context"] = Context;
            o["people"] = People.ToJsonArray();
            o["terms"] = Terms.ToJsonArray();
            if (Languages.Count > 0) o["languages"] = SpeechLanguages.Serialize(Languages.ToList()); else o.Remove("languages");
            if (!o.ContainsKey("replacements")) o["replacements"] = new JsonArray();
            JsonFile.WriteAtomic(path, o);
            return true;
        });
    }

    /// <summary>Removes the project file under its lock. <paramref name="remove"/> is what deletes it: the app passes the Recycle Bin.</summary>
    public static void Delete(string slug, string profilesFolder, Action<string> remove)
    {
        if (!IsValidSlug(slug)) throw new FileNotFoundException(slug);
        var path = Path.Combine(profilesFolder, slug + ".json");
        FileLock.With(path, () =>
        {
            remove(path);
            return true;
        });
    }

    /// <summary>Project people for suggestions: from past calls, most frequent first, then the profile. Never the user.</summary>
    public static List<string> KnownPeople(string slug, IEnumerable<Call> calls, IEnumerable<Project> projects, string me, int limit = 12)
    {
        if (slug.Length == 0) return [];
        var count = new Dictionary<string, int>();
        foreach (var call in calls.Where(c => c.Info.Profile == slug))
            foreach (var name in TextRules.SplitList(call.People))
                count[name] = count.GetValueOrDefault(name) + 1;
        foreach (var person in projects.FirstOrDefault(p => p.Slug == slug)?.People ?? [])
        {
            if (count.ContainsKey(person)) continue;
            var first = person.Split(' ')[0];
            if (count.Keys.Any(k => k == first || k.StartsWith(first + " ", StringComparison.Ordinal))) continue;
            count[person] = 0;
        }
        var lowerMe = me.ToLowerInvariant();
        return count.Where(kv => kv.Key.ToLowerInvariant() != lowerMe)
                    .OrderByDescending(kv => kv.Value).ThenBy(kv => kv.Key, StringComparer.Ordinal)
                    .Take(limit).Select(kv => kv.Key).ToList();
    }
}
