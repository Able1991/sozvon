using Sozvon.Core.Calls;
using Sozvon.Core.Foundation;
using Sozvon.Core.Settings;

namespace Sozvon.Core.Tests;

public class ProjectEditingTests : TempFolders
{
    private string Profiles => Path.Combine(Data, "profiles");

    [Fact]
    public void NewProjectGetsAFreeFileNameAndTrimmedFields()
    {
        WriteText(Path.Combine(Profiles, "acme.json"), """{"schema": 1, "title": "Acme"}""");
        var p = new Project("", "").WithForm("  Acme  ", " infra\rvideo \n", "Анна Петрова, Иван\r Олег ,\r\n", "HPA,,Kubernetes", Profiles);
        Assert.Equal("acme-2", p.Slug);
        Assert.Equal("Acme", p.Title);
        Assert.Equal("infra\nvideo", p.Context);
        Assert.Equal(["Анна Петрова", "Иван", "Олег"], p.People);
        Assert.Equal(["HPA", "Kubernetes"], p.Terms);
    }

    [Fact]
    public void RenameKeepsTheFileNameAndTheReplacements()
    {
        WriteText(Path.Combine(Profiles, "acme.json"), """{"schema": 1, "title": "Acme", "replacements": [["хпа", "HPA"]], "extra": true}""");
        var old = Project.All(Profiles).Single();
        old.WithForm("Acme Holding", "", "", "", Profiles).Save(Profiles);
        var saved = Project.All(Profiles).Single();
        Assert.Equal("acme", saved.Slug);
        Assert.Equal("Acme Holding", saved.Title);
        var o = JsonFile.Read(Path.Combine(Profiles, "acme.json"))!;
        Assert.Equal(1, o.Int("schema"));
        Assert.Single(o["replacements"]!.AsArray());
        Assert.True(o.Flag("extra"));
    }

    [Fact]
    public void NewProjectFileHasTheContractSchema()
    {
        new Project("", "").WithForm("Щука", "о чём", "Анна", "", Profiles).Save(Profiles);
        var o = JsonFile.Read(Path.Combine(Profiles, "schuka.json"))!;
        Assert.Equal(1, o.Int("schema"));
        Assert.Equal("Щука", o.Text("title"));
        Assert.Equal(["Анна"], o.Texts("people"));
        Assert.Empty(o["terms"]!.AsArray());
        Assert.Empty(o["replacements"]!.AsArray());
    }

    [Fact]
    public void DeleteHandsTheFileToTheRemoverUnderTheLock()
    {
        WriteText(Path.Combine(Profiles, "acme.json"), """{"schema": 1, "title": "Acme"}""");
        string? removed = null;
        Project.Delete("acme", Profiles, path =>
        {
            Assert.True(File.Exists(FileLock.LockPath(path)));
            removed = path;
            File.Delete(path);
        });
        Assert.Equal(Path.Combine(Profiles, "acme.json"), removed);
        Assert.Empty(Project.All(Profiles));
        Assert.Throws<FileNotFoundException>(() => Project.Delete("../x", Profiles, _ => { }));
    }

    [Fact]
    public void AChangeInAnyShownFieldCountsAsAChange()
    {
        var acme = new Project("acme", "Acme", "infra", ["Анна"], ["HPA"]);
        Assert.True(acme.SameAs(new Project("acme", "Acme", "infra", ["Анна"], ["HPA"])));
        Assert.False(acme.SameAs(acme with { Context = "video" }));
        Assert.False(acme.SameAs(acme with { Title = "ACME" }));
        Assert.False(acme.SameAs(acme with { PeopleList = ["Иван"] }));
        Assert.False(acme.SameAs(acme with { TermsList = [] }));
        Assert.False(acme.SameAs(acme with { Slug = "acme-2" }));
    }

    [Fact]
    public void PeopleAreCountedOnceAcrossProjects()
    {
        Assert.Equal(3, Project.PeopleCount([new Project("a", "A", PeopleList: ["Анна", "Иван"]), new Project("b", "B", PeopleList: ["анна", "Олег"])]));
    }

    [Theory]
    [InlineData(1, "1 проект")]
    [InlineData(3, "3 проекта")]
    [InlineData(5, "5 проектов")]
    [InlineData(11, "11 проектов")]
    [InlineData(21, "21 проект")]
    [InlineData(112, "112 проектов")]
    [InlineData(0, "0 проектов")]
    public void RussianPlurals(int n, string text) =>
        Assert.Equal(text, Plural.Count(n, ("проект", "проекта", "проектов"), ("project", "projects"), russian: true));

    [Fact]
    public void EnglishPlurals()
    {
        Assert.Equal("1 person", Plural.Count(1, ("человек", "человека", "человек"), ("person", "people"), russian: false));
        Assert.Equal("2 people", Plural.Count(2, ("человек", "человека", "человек"), ("person", "people"), russian: false));
    }
}

public class VoiceListTests
{
    private static readonly VoiceRecord Me = new("m", "Борис", Me: true, UpdatedAt: "2026-11-05T10:00:00Z");
    private static readonly VoiceRecord OldMe = new("o", "Борис", Me: true, UpdatedAt: "2026-01-01T10:00:00Z");
    private static readonly VoiceRecord Anna = new("a", "Анна", "beta");
    private static readonly VoiceRecord Ivan = new("i", "Иван", "alpha");
    private static readonly VoiceRecord Oleg = new("g", "Олег");
    private static readonly VoiceRecord Anna2 = new("b", "Анна", "alpha");

    [Fact]
    public void OwnVoiceFirstThenProjectThenName()
    {
        string Title(VoiceRecord r) => r.Profile.Length == 0 ? "zz" : r.Profile;
        Assert.Equal(["m", "b", "i", "a", "g"], Voices.ListOrder([Anna, Ivan, Oleg, Me, Anna2], Title).Select(r => r.Id));
    }

    [Fact]
    public void OtherNamesAreDistinctAndSkipTheUser() =>
        Assert.Equal(["Анна", "Иван", "Олег"], Voices.OtherNames([Oleg, Anna, Me, Ivan, Anna2]));

    [Fact]
    public void ReplacingTheOwnSampleDropsOnlyOlderOwnRecords()
    {
        Assert.Equal(["o"], Voices.Superseded(new HashSet<string> { "o" }, [OldMe, Me, Anna]).Select(r => r.Id));
        Assert.Empty(Voices.Superseded(new HashSet<string> { "m" }, [Me, Anna]));
        Assert.Empty(Voices.Superseded(new HashSet<string>(), [Anna]));
    }
}

public class VoiceSampleTests
{
    [Fact]
    public void LanguagesComeFromSettings()
    {
        Assert.Equal([SpeechLanguage.Ru, SpeechLanguage.En], VoiceSample.Languages([]));
        Assert.Equal([SpeechLanguage.Ru, SpeechLanguage.En], VoiceSample.Languages([SpeechLanguage.Auto]));
        Assert.Equal([SpeechLanguage.De], VoiceSample.Languages([SpeechLanguage.De]));
        Assert.NotNull(VoiceSample.Text(SpeechLanguage.Ru));
        Assert.Null(VoiceSample.Text(SpeechLanguage.De));
    }

    [Fact]
    public void WordsLightUpAtReadingPace()
    {
        const string text = "один два три четыре";
        Assert.Equal(4, VoiceSample.WordsRead(text, TimeSpan.Zero, recording: false));
        Assert.Equal(0, VoiceSample.WordsRead(text, TimeSpan.Zero, recording: true));
        Assert.Equal(2, VoiceSample.WordsRead(text, TimeSpan.FromSeconds(10), recording: true));
        Assert.Equal(4, VoiceSample.WordsRead(text, TimeSpan.FromSeconds(40), recording: true));
    }

    [Fact]
    public void LevelAndClock()
    {
        Assert.Equal(0, VoiceSample.Level(0));
        Assert.Equal(1, VoiceSample.Level(1));
        Assert.Equal(0.6, VoiceSample.Level(0.1), 3);
        Assert.Equal(0, VoiceSample.Level(0.001));
        Assert.Equal("0:07", VoiceSample.Clock(TimeSpan.FromSeconds(7.9)));
        Assert.Equal("0:25", VoiceSample.Clock(VoiceSample.MaxDuration));
    }
}
