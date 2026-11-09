namespace Sozvon.Core.Settings;

/// <summary>The assistant that writes summaries (.env <c>SOZVON_LLM</c>).</summary>
public enum Assistant { Claude, Codex, Cursor, None }

public static class Assistants
{
    public static string Key(this Assistant a) => a.ToString().ToLowerInvariant();

    public static Assistant? FromKey(string? key) => key switch
    {
        "claude" => Assistant.Claude,
        "codex" => Assistant.Codex,
        "cursor" => Assistant.Cursor,
        "none" => Assistant.None,
        _ => null,
    };

    /// <summary>Claude when its command line tool is installed: on Windows the engine picks no other assistant by itself.</summary>
    public static Assistant Detect()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var folders = (Environment.GetEnvironmentVariable("PATH") ?? "")
            .Split(Path.PathSeparator, StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
            .Where(Path.IsPathFullyQualified)
            .Append(Path.Combine(home, ".local", "bin"));
        var found = folders.Any(f => File.Exists(Path.Combine(f, "claude.exe")) || File.Exists(Path.Combine(f, "claude.cmd")));
        return found ? Assistant.Claude : Assistant.None;
    }
}

/// <summary>Spoken language of a call.</summary>
public enum SpeechLanguage { Ru, En, Uk, De, Es, Auto }

public static class SpeechLanguages
{
    /// <summary>Real languages, in the canonical order, without "detect automatically".</summary>
    public static readonly IReadOnlyList<SpeechLanguage> Real =
        [SpeechLanguage.Ru, SpeechLanguage.En, SpeechLanguage.Uk, SpeechLanguage.De, SpeechLanguage.Es];

    public static string Code(this SpeechLanguage l) => l.ToString().ToLowerInvariant();

    /// <summary>"ru,en" becomes [Ru, En]; "auto" or empty becomes an empty list, which means any language.</summary>
    public static List<SpeechLanguage> Parse(string text) =>
        text.Split(',', StringSplitOptions.TrimEntries)
            .SelectMany(code => Real.Where(l => l.Code() == code))
            .ToList();

    public static string Serialize(IReadOnlyCollection<SpeechLanguage> list) =>
        list.Count == 0 ? "auto" : string.Join(',', list.Select(Code));

    /// <summary>The languages after clicking one in a checklist; Auto clears the list.</summary>
    public static List<SpeechLanguage> Toggling(SpeechLanguage language, IReadOnlyCollection<SpeechLanguage> list)
    {
        if (language == SpeechLanguage.Auto) return [];
        var picked = list.Contains(language) ? list.Where(l => l != language).ToList() : list.Append(language).ToList();
        return Real.Where(picked.Contains).ToList();
    }
}

/// <summary>Speech recognition model. Keys match engine/models.json.</summary>
public enum WhisperModel { Turbo, Large, Small, GigaAm, Parakeet }

public static class WhisperModels
{
    public static string Key(this WhisperModel m) => m switch
    {
        WhisperModel.Turbo => "turbo",
        WhisperModel.Large => "large-v3",
        WhisperModel.Small => "small",
        WhisperModel.GigaAm => "gigaam",
        WhisperModel.Parakeet => "parakeet",
        _ => throw new ArgumentOutOfRangeException(nameof(m)),
    };

    public static WhisperModel? FromKey(string? key) =>
        Enum.GetValues<WhisperModel>().Where(m => m.Key() == key).Cast<WhisperModel?>().FirstOrDefault();

    public static string Folder(this WhisperModel m) => m switch
    {
        WhisperModel.Turbo => "whisper-large-v3-turbo",
        WhisperModel.Large => "whisper-large-v3",
        WhisperModel.Small => "whisper-small",
        WhisperModel.GigaAm => "gigaam-v3-onnx",
        WhisperModel.Parakeet => "parakeet-tdt-0.6b-v3-onnx",
        _ => throw new ArgumentOutOfRangeException(nameof(m)),
    };

    /// <summary>Models without Whisper prompting need the voice activity model next to them.</summary>
    public static bool SupportsPrompt(this WhisperModel m) => m is not (WhisperModel.GigaAm or WhisperModel.Parakeet);

    public static bool IsDownloaded(this WhisperModel m, string dataFolder)
    {
        var models = Path.Combine(dataFolder, "models");
        if (!File.Exists(Path.Combine(models, m.Folder(), ".complete"))) return false;
        return m.SupportsPrompt() || File.Exists(Path.Combine(models, "silero-vad-onnx", ".complete"));
    }
}
