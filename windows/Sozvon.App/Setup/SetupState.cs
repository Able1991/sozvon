namespace Sozvon.App.Setup;

/// <summary>What the user chose in the wizard, kept in the .env of the data folder.</summary>
internal sealed class SetupState
{
    public const string Auto = "auto";
    public const string NoAssistant = "none";

    private readonly SetupContext _context;

    public SetupState(SetupContext context, IReadOnlyList<SpeechModel> models, IReadOnlyList<Assistant> assistants)
    {
        _context = context;
        Models = models;
        Assistants = assistants;
        var saved = EnvFile.Read(context.EnvFile);
        Name = saved.GetValueOrDefault("SOZVON_ME", "");
        Languages = saved.GetValueOrDefault("SOZVON_LANGUAGE", "ru")
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Where(language => language != Auto)
            .ToList();
        var model = saved.GetValueOrDefault("SOZVON_MODEL");
        Model = models.FirstOrDefault(m => m.Key == model) ?? models.First(m => m.Recommended);
        ModelRu = saved.GetValueOrDefault("SOZVON_MODEL_RU", "");
        // Codex and Cursor are never picked for the user: they run only when chosen.
        var claude = assistants.Any(a => a.Key == "claude" && a.IsInstalled);
        Assistant = saved.GetValueOrDefault("SOZVON_LLM", claude ? "claude" : NoAssistant);
        var summary = saved.GetValueOrDefault("SOZVON_SUMMARY_LANGUAGE", Auto);
        SummaryLanguage = SummaryLanguages.Contains(summary) ? summary : Auto;
    }

    /// <summary>SOZVON_SUMMARY_LANGUAGE values, in the order of the dropdown: the conversation's language first.</summary>
    public static readonly IReadOnlyList<string> SummaryLanguages = [Auto, "ru", "en", "uk", "de", "es"];

    /// <summary>The summary's language; "auto": the conversation's.</summary>
    public string SummaryLanguage { get; set; }

    public IReadOnlyList<SpeechModel> Models { get; }
    public IReadOnlyList<Assistant> Assistants { get; }
    public string Name { get; set; }
    public List<string> Languages { get; set; }
    public string Assistant { get; set; }
    public SpeechModel Model { get; set; }
    public bool UseGpu { get; set; }

    /// <summary>SOZVON_MODEL_RU: "gigaam" (or "parakeet", set in Settings) for Russian tracks; "": the main model.</summary>
    public string ModelRu { get; set; }

    /// <summary>The model Russian tracks go to with the chosen main model, as the engine decides it (models.ru_model).</summary>
    public SpeechModel? RussianModel =>
        Sozvon.Core.Settings.WhisperModels.FromKey(Model.Key) is { } main
        && Sozvon.Core.Settings.WhisperModels.RuModel(main, Sozvon.Core.Settings.WhisperModels.FromKey(ModelRu)) is { } ru
            ? Models.FirstOrDefault(m => m.Key == Sozvon.Core.Settings.WhisperModels.Key(ru))
            : null;

    /// <summary>Ready only with both models on disk: the install downloads the Russian one too.</summary>
    public bool IsEngineReady => EngineStatus.IsReady(_context, Model) && (RussianModel is not { } ru || EngineStatus.IsDownloaded(_context, ru));

    public void Save() => EnvFile.Write(_context.EnvFile, new Dictionary<string, string>
    {
        ["SOZVON_ENV_VERSION"] = "1",
        ["SOZVON_ME"] = Name.Trim(),
        ["SOZVON_LLM"] = Assistant,
        ["SOZVON_LANGUAGE"] = Languages.Count == 0 ? Auto : string.Join(',', Languages),
        ["SOZVON_MODEL"] = Model.Key,
        ["SOZVON_MODEL_RU"] = ModelRu,
        ["SOZVON_SUMMARY_LANGUAGE"] = SummaryLanguage,
    });
}
