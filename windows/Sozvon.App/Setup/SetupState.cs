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
        // Codex and Cursor are never picked for the user: they run only when chosen.
        var claude = assistants.Any(a => a.Key == "claude" && a.IsInstalled);
        Assistant = saved.GetValueOrDefault("SOZVON_LLM", claude ? "claude" : NoAssistant);
    }

    public IReadOnlyList<SpeechModel> Models { get; }
    public IReadOnlyList<Assistant> Assistants { get; }
    public string Name { get; set; }
    public List<string> Languages { get; set; }
    public string Assistant { get; set; }
    public SpeechModel Model { get; set; }
    public bool UseGpu { get; set; }

    public bool IsEngineReady => EngineStatus.IsReady(_context, Model);

    public void Save() => EnvFile.Write(_context.EnvFile, new Dictionary<string, string>
    {
        ["SOZVON_ENV_VERSION"] = "1",
        ["SOZVON_ME"] = Name.Trim(),
        ["SOZVON_LLM"] = Assistant,
        ["SOZVON_LANGUAGE"] = Languages.Count == 0 ? Auto : string.Join(',', Languages),
        ["SOZVON_MODEL"] = Model.Key,
    });
}
