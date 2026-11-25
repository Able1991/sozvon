using System.Text.Json;
using System.Text.Json.Serialization;
using Sozvon.Core.Foundation;

namespace Sozvon.Core.Engine;

/// <summary>
/// How fast this computer transcribes, as on the Mac (SpeedBook.swift): processing seconds per call second, per model,
/// from finished runs. Only calls of 10 minutes or more count (short ones are mostly start-up), the last 10 per model.
/// Kept in speed.json of the data folder.
/// </summary>
public sealed class SpeedBook
{
    public const string FileName = "speed.json";
    internal const double MinCallSeconds = 600;
    internal const int Keep = 10;

    [JsonPropertyName("samples")]
    public Dictionary<string, List<double>> Samples { get; init; } = [];

    /// <summary>The model of the latest sample: a waiting call is estimated with it (the engine picks its model during the run).</summary>
    [JsonPropertyName("last_model")]
    public string? LastModel { get; set; }

    public void Record(string model, double callSeconds, double processingSeconds)
    {
        if (model.Length == 0 || callSeconds < MinCallSeconds || processingSeconds <= 0) return;
        var list = Samples.TryGetValue(model, out var existing) ? existing : Samples[model] = [];
        list.Add(processingSeconds / callSeconds);
        if (list.Count > Keep) list.RemoveRange(0, list.Count - Keep);
        LastModel = model;
    }

    /// <summary>Processing seconds per call second, the mean of the last samples; null without samples.</summary>
    public double? Factor(string model) =>
        Samples.TryGetValue(model, out var list) && list.Count > 0 ? list.Average() : null;

    public double? Estimate(string model, double callSeconds) => Factor(model) * callSeconds;

    public static SpeedBook Load(string dataDir)
    {
        try
        {
            return SharedFile.ReadText(Path.Combine(dataDir, FileName)) is { } text
                ? JsonSerializer.Deserialize<SpeedBook>(text) ?? new SpeedBook()
                : new SpeedBook();
        }
        catch (JsonException)
        {
            return new SpeedBook();
        }
    }

    public void Save(string dataDir)
    {
        try
        {
            Directory.CreateDirectory(dataDir);
            AtomicFile.Write(Path.Combine(dataDir, FileName), JsonSerializer.SerializeToUtf8Bytes(this));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Only an estimate: the next run tries again.
        }
    }
}

/// <summary>The estimate's words, as on the Mac; <c>l</c> is the app's text tables (keys with %@ for the numbers).</summary>
public static class EstimateText
{
    /// <summary>"≈ 1 мин" under two minutes, "≈ 12 мин", then "≈ 1 ч", "≈ 1 ч 10 мин": whole minutes, rounded (59.5 is 1 h).</summary>
    public static string Duration(double seconds, Func<string, object[], string> l)
    {
        var minutes = seconds < 120 ? 1 : (int)Math.Round(seconds / 60, MidpointRounding.AwayFromZero);
        if (minutes < 60) return l("≈ %@ мин", [minutes]);
        if (minutes % 60 == 0) return l("≈ %@ ч", [minutes / 60]);
        return l("≈ %@ ч %@ мин", [minutes / 60, minutes % 60]);
    }

    /// <summary>The running call: "осталось ≈ 12 мин", so it does not read as a second duration next to the call's own.</summary>
    public static string Remaining(double estimate, double elapsed, Func<string, object[], string> l) =>
        elapsed >= estimate ? l("почти готово", []) : l("осталось %@", [Duration(estimate - elapsed, l)]);
}
