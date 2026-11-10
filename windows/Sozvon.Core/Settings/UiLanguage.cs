using System.Text.Json;

namespace Sozvon.Core.Settings;

/// <summary>
/// The interface language from the "Язык интерфейса" setting, for a process that has no settings store of its own: the
/// setup wizard reads settings.json from the data folder it was given.
/// </summary>
public static class UiLanguage
{
    /// <summary>
    /// Russian or English from the text of settings.json: "Russian" and "English" decide, "System", an absent or unknown
    /// value, no file at all (<paramref name="settingsJson"/> is null) and a broken file follow Windows.
    /// </summary>
    public static bool IsRussian(string? settingsJson, bool systemIsRussian) =>
        Setting(settingsJson) switch
        {
            "russian" or "1" => true,
            "english" or "2" => false,
            _ => systemIsRussian,
        };

    private static string? Setting(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return null;
        try
        {
            using var document = JsonDocument.Parse(json);
            if (document.RootElement.ValueKind != JsonValueKind.Object || !document.RootElement.TryGetProperty("Language", out var value))
            {
                return null;
            }
            return value.ValueKind switch
            {
                JsonValueKind.String => value.GetString()?.ToLowerInvariant(),
                JsonValueKind.Number => value.GetRawText(),
                _ => null,
            };
        }
        catch (JsonException)
        {
            return null;
        }
    }
}
