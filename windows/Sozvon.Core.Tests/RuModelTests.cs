using System.Text.Json.Nodes;
using Sozvon.Core.Calls;
using Sozvon.Core.Engine;
using Sozvon.Core.Settings;

namespace Sozvon.Core.Tests;

/// <summary>
/// Whisper for the rest, GigaAM for Russian (SOZVON_MODEL_RU, docs/CONTRACT.md), as the Mac's RuModelTests: when the
/// second model applies, what "Auto" means for a call, a model chosen for one call, and a project's call language.
/// </summary>
public sealed class RuModelTests : TempFolders
{
    private string Env => Path.Combine(Data, ".env");
    private string Profiles => Path.Combine(Data, "profiles");

    private static string L(string key, object[] args) =>
        args.Aggregate(key, (text, arg) => text.Contains("%@") ? text[..text.IndexOf("%@")] + arg + text[(text.IndexOf("%@") + 2)..] : text);

    [Fact]
    public void TheRussianModelOnlyFollowsAWhisperModel()
    {
        Assert.Equal(WhisperModel.GigaAm, WhisperModels.RuModel(WhisperModel.Turbo, WhisperModel.GigaAm));
        Assert.Equal(WhisperModel.Parakeet, WhisperModels.RuModel(WhisperModel.Small, WhisperModel.Parakeet));
        Assert.Null(WhisperModels.RuModel(WhisperModel.GigaAm, WhisperModel.GigaAm));
        Assert.Null(WhisperModels.RuModel(WhisperModel.Parakeet, WhisperModel.GigaAm)); // onnx can't tell languages apart
        Assert.Null(WhisperModels.RuModel(WhisperModel.Turbo, WhisperModel.Large));     // a second Whisper gives nothing
        Assert.Null(WhisperModels.RuModel(WhisperModel.Turbo, null));
        Assert.True(WhisperModel.Turbo.IsWhisper());
        Assert.False(WhisperModel.GigaAm.IsWhisper());
    }

    [Fact]
    public void AutoNamesTheModelACallGets()
    {
        Assert.Equal(WhisperModel.GigaAm, WhisperModels.Auto([SpeechLanguage.Ru], WhisperModel.Turbo, WhisperModel.GigaAm));
        Assert.Equal(WhisperModel.Turbo, WhisperModels.Auto([SpeechLanguage.En], WhisperModel.Turbo, WhisperModel.GigaAm));
        Assert.Null(WhisperModels.Auto([SpeechLanguage.Ru, SpeechLanguage.En], WhisperModel.Turbo, WhisperModel.GigaAm)); // by each track
        Assert.Null(WhisperModels.Auto([], WhisperModel.Turbo, WhisperModel.GigaAm));
        Assert.Equal(WhisperModel.Turbo, WhisperModels.Auto([SpeechLanguage.Ru], WhisperModel.Turbo, null));
        Assert.Equal(WhisperModel.GigaAm, WhisperModels.Auto([SpeechLanguage.Ru, SpeechLanguage.En], WhisperModel.GigaAm, WhisperModel.GigaAm));
    }

    [Fact]
    public void TheAutoLineSaysWhichModel()
    {
        Assert.Equal("Авто: GigaAM v3", WhisperModels.AutoTitle([SpeechLanguage.Ru], WhisperModel.Turbo, WhisperModel.GigaAm, L));
        Assert.Equal("Авто: Whisper Turbo", WhisperModels.AutoTitle([SpeechLanguage.En], WhisperModel.Turbo, WhisperModel.GigaAm, L));
        Assert.Equal("Авто: GigaAM для русского, Turbo для остального",
            WhisperModels.AutoTitle([SpeechLanguage.Ru, SpeechLanguage.En], WhisperModel.Turbo, WhisperModel.GigaAm, L));
        Assert.Equal("Авто: Parakeet для русского, Large v3 для остального",
            WhisperModels.AutoTitle([], WhisperModel.Large, WhisperModel.Parakeet, L));
        Assert.Equal("Авто: Whisper Large v3", WhisperModels.AutoTitle([SpeechLanguage.Ru, SpeechLanguage.En], WhisperModel.Large, null, L));
    }

    [Fact]
    public void BothModelsMustBeDownloaded()
    {
        var layout = new EngineLayout(Data, Calls);
        WriteText(layout.Python, "x");
        MarkInstalled();
        WriteText(Path.Combine(Data, "models", "whisper-large-v3-turbo", ".complete"), "");
        Assert.Equal(EngineStateKind.Ready, EngineState.Evaluate(layout, WhisperModel.Turbo));
        Assert.Equal(EngineStateKind.ModelMissing, EngineState.Evaluate(layout, WhisperModel.Turbo, ruModel: WhisperModel.GigaAm));
        Assert.Equal([WhisperModel.GigaAm], WhisperModels.Missing(Data, WhisperModel.Turbo, WhisperModel.GigaAm));
        Assert.Empty(WhisperModels.Missing(Data, WhisperModel.Turbo, WhisperModel.Large)); // no second Whisper
        WriteText(Path.Combine(Data, "models", "gigaam-v3-onnx", ".complete"), "");
        Assert.Equal(EngineStateKind.ModelMissing, EngineState.Evaluate(layout, WhisperModel.Turbo, ruModel: WhisperModel.GigaAm)); // and its VAD
        WriteText(Path.Combine(Data, "models", "silero-vad-onnx", ".complete"), "");
        Assert.Equal(EngineStateKind.Ready, EngineState.Evaluate(layout, WhisperModel.Turbo, ruModel: WhisperModel.GigaAm));
        Assert.Empty(WhisperModels.Missing(Data, WhisperModel.Turbo, WhisperModel.GigaAm));
        Assert.Equal([WhisperModel.Large], WhisperModels.Missing(Data, WhisperModel.Large, WhisperModel.GigaAm));
    }

    [Fact]
    public void TheEnvKeepsTheRussianModel()
    {
        var values = SettingsValues.FromEnv(new Dictionary<string, string> { ["SOZVON_MODEL_RU"] = "gigaam" }, () => Assistant.None);
        Assert.Equal(WhisperModel.GigaAm, values.ModelRu);
        Assert.Contains(("SOZVON_MODEL_RU", "gigaam"), values.Pairs());
        Assert.Null(SettingsValues.FromEnv(new Dictionary<string, string> { ["SOZVON_MODEL_RU"] = "" }, () => Assistant.None).ModelRu);
        Assert.DoesNotContain(new SettingsValues().Pairs(), p => p.Key == "SOZVON_MODEL_RU");
        Assert.Contains("SOZVON_MODEL_RU", SettingsValues.ManagedKeys);
    }

    [Fact]
    public void SettingsWriteOnlyTheRussianModelKey()
    {
        WriteText(Env, "HF_TOKEN=keep\nSOZVON_MODEL=\"turbo\"\nSOZVON_MODEL_RU=\"parakeet\"\n");
        SettingsValues.SaveModelRu(Env, WhisperModel.GigaAm);
        var text = File.ReadAllText(Env);
        Assert.Contains("SOZVON_MODEL_RU=\"gigaam\"", text);
        Assert.DoesNotContain("parakeet", text);
        Assert.Contains("HF_TOKEN=keep", text);
        Assert.Contains("SOZVON_MODEL=\"turbo\"", text);
        // "Same model": the key leaves the file, so the engine's install and its runs read none.
        SettingsValues.SaveModelRu(Env, null);
        Assert.DoesNotContain("SOZVON_MODEL_RU", File.ReadAllText(Env));
        Assert.Null(SettingsValues.Load(Env, () => Assistant.None).ModelRu);
    }

    [Fact]
    public void AnInheritedRussianModelDoesNotOverruleTheEnvFile()
    {
        var env = EngineEnvironment.Build(new EngineLayout(Data, Calls), new EngineOptions(), new Dictionary<string, string> { ["SOZVON_MODEL_RU"] = "parakeet" });
        Assert.False(env.ContainsKey("SOZVON_MODEL_RU"));
    }

    [Fact]
    public void AModelChosenForACallIsKeptInCallJson()
    {
        var c = new JsonObject();
        CallFile.Apply(new CallInfo { Model = WhisperModel.Large }, c);
        Assert.Equal("large-v3", (string?)c["model"]);
        Assert.Equal(WhisperModel.Large, CallFile.Info(c).Model);
        CallFile.Apply(new CallInfo(), c);
        Assert.False(c.ContainsKey("model")); // auto: no field
        Assert.Null(CallFile.Info(c).Model);
        Assert.Null(CallFile.Info(new JsonObject { ["model"] = "whisper-9000" }).Model); // unknown means auto
        Assert.NotEqual(new CallInfo(), new CallInfo { Model = WhisperModel.Small });
    }

    [Fact]
    public void AProjectKeepsItsCallLanguage()
    {
        var p = new Project("acme", "Acme") { Languages = [SpeechLanguage.Ru, SpeechLanguage.En] };
        p.Save(Profiles);
        Assert.Contains("\"languages\": \"ru,en\"", File.ReadAllText(Path.Combine(Profiles, "acme.json")));
        var loaded = Project.Load(Path.Combine(Profiles, "acme.json"))!;
        Assert.Equal([SpeechLanguage.Ru, SpeechLanguage.En], loaded.Languages);
        Assert.True(loaded.SameAs(p));
        Assert.False(loaded.SameAs(p with { Languages = [] }));
        // "As in Settings": no field, the engine and the call window take the settings' languages.
        (loaded with { Languages = [] }).Save(Profiles);
        Assert.DoesNotContain("languages", File.ReadAllText(Path.Combine(Profiles, "acme.json")));
        Assert.Empty(Project.Load(Path.Combine(Profiles, "acme.json"))!.Languages);
    }

    [Fact]
    public void AProjectWithoutALanguageFileStaysAsItWas()
    {
        WriteText(Path.Combine(Profiles, "old.json"), "{\"title\": \"Old\", \"languages\": \"auto\"}");
        Assert.Empty(Project.Load(Path.Combine(Profiles, "old.json"))!.Languages);
    }

    [Fact]
    public void TheProjectLanguageChoicesAreTheMacs()
    {
        Assert.Equal(["ru", "en", "ru,en", "uk", "de", "es"], Project.LanguageChoices);
        Assert.All(Project.LanguageChoices, v => Assert.Equal(v, SpeechLanguages.Serialize(SpeechLanguages.Parse(v))));
    }

    [Fact]
    public void ThePickedProjectBringsItsLanguage()
    {
        var acme = new Project("acme", "Acme") { Languages = [SpeechLanguage.En] };
        var plain = new Project("plain", "Plain");
        Assert.Equal([SpeechLanguage.En], Project.CallLanguages(acme, [SpeechLanguage.Ru]));
        Assert.Equal([SpeechLanguage.Ru], Project.CallLanguages(plain, [SpeechLanguage.Ru]));
        Assert.Equal([SpeechLanguage.Ru], Project.CallLanguages(null, [SpeechLanguage.Ru]));
    }
}

/// <summary>Every new text of the two models has English, from the Mac's table or the Windows one (sentence case there).</summary>
public sealed class RuModelWordingTests
{
    private static readonly string[] Keys =
    [
        "Для русского", "Whisper определяет язык дорожки, русскую расшифровывает эта модель", "Та же модель", "Только русский",
        "Скачана", "Не скачана", "не скачана", "Скачать модель…", "Модель:", "Авто: %@", "Авто: %@ для русского, %@ для остального",
        "Авто выбирает модель по языку звонка, его можно поменять в настройках распознавания", "Язык звонков", "Как в настройках",
    ];

    [Fact]
    public void EveryTextHasEnglish()
    {
        var mac = File.ReadLines(Path.Combine(Repo.Root(), "Sources", "Sozvon", "Resources", "en.lproj", "Localizable.strings"))
            .Select(line => System.Text.RegularExpressions.Regex.Match(line, "^\"(.*)\" = \"(.*)\";$")).Where(m => m.Success)
            .Select(m => m.Groups[1].Value).ToHashSet();
        var windows = ProjectsWordingTests.WindowsEnglish();
        Assert.All(Keys, key => Assert.True(windows.ContainsKey(key) || mac.Contains(key), key));
        Assert.Equal("Download model…", windows["Скачать модель…"]);
    }
}
