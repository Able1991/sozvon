using System.Text.Json;

namespace Sozvon.App.Setup;

internal sealed record ModelFiles(string Folder, string[] Names);

/// <summary>A speech model from the engine's models.json, with the files that prove it is downloaded.</summary>
internal sealed record SpeechModel(string Key, string Title, string Description, double SizeGb, bool Recommended, ModelFiles Files, ModelFiles? Vad)
{
    public string Size => Strings.Gigabytes(SizeGb);
}

internal static class ModelCatalog
{
    private static readonly (string Key, string Title, string Description)[] Shown =
    [
        ("turbo", "Whisper Turbo", "Быстро и точно."),
        ("large-v3", "Whisper Large v3", "Самая точная, примерно в 2 раза медленнее Turbo."),
        ("small", "Whisper Small", "Лёгкая: для компьютеров с 8 ГБ памяти и экономии места. Точность ниже."),
        ("gigaam", "GigaAM v3", "Только русский, от Сбера. Лёгкая и быстрая, но без словаря проектов."),
        ("parakeet", "Parakeet v3", "25 европейских языков, от NVIDIA. Очень быстрая, но без словаря проектов."),
    ];

    public static IReadOnlyList<SpeechModel> Load(string manifestPath)
    {
        using var document = JsonDocument.Parse(File.ReadAllText(manifestPath));
        var root = document.RootElement;
        var vad = new ModelFiles(root.GetProperty("vad").GetProperty("dir").GetString()!, Names(root.GetProperty("vad")));
        var models = root.GetProperty("models");
        return Shown.Select(shown =>
        {
            var entry = models.GetProperty(shown.Key);
            // On Windows a Whisper model comes from the "win32" block of its entry; the folder name is shared.
            var source = entry.TryGetProperty("win32", out var win32) ? win32 : entry;
            var files = new ModelFiles(entry.GetProperty("dir").GetString()!, Names(source));
            var isOnnx = entry.GetProperty("kind").GetString() == "onnx";
            return new SpeechModel(shown.Key, shown.Title, Strings.L(shown.Description), source.GetProperty("size_gb").GetDouble(),
                shown.Key == "turbo", files, isOnnx ? vad : null);
        }).ToList();
    }

    private static string[] Names(JsonElement entry) =>
        entry.GetProperty("files").EnumerateArray().Select(name => name.GetString()!).ToArray();
}

/// <summary>What is installed in the data folder, by the same rules as the engine (sozvon_engine/models.py).</summary>
internal static class EngineStatus
{
    public static bool IsReady(SetupContext context, SpeechModel model) =>
        File.Exists(context.Python) && File.Exists(Path.Combine(context.DataFolder, ".installed")) && IsDownloaded(context, model);

    public static bool IsDownloaded(SetupContext context, SpeechModel model) =>
        IsComplete(context, model.Files) && (model.Vad is null || IsComplete(context, model.Vad));

    public static bool HasDiarization(SetupContext context) =>
        !File.Exists(Path.Combine(context.DataFolder, ".no-diarization"));

    private static bool IsComplete(SetupContext context, ModelFiles files)
    {
        var folder = Path.Combine(context.DataFolder, "models", files.Folder);
        return File.Exists(Path.Combine(folder, ".complete"))
            || files.Names.All(name => new FileInfo(Path.Combine(folder, name)) is { Exists: true, Length: > 0 });
    }
}
