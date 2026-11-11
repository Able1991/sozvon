using System.Text.Json.Nodes;

namespace Sozvon.Core.Settings;

/// <summary>settings.json, shared by the app and the setup wizard: each writes its own keys and keeps the rest.</summary>
public static class SettingsJson
{
    /// <summary>
    /// <paramref name="mine"/> with the keys of <paramref name="disk"/> it does not have, such as the calls folder the
    /// wizard chose (<see cref="Calls.CallsFolder.SettingKey"/>), which the app's settings object does not hold.
    /// </summary>
    public static JsonObject KeepForeignKeys(JsonObject? disk, JsonObject mine)
    {
        if (disk is null) return mine;
        foreach (var (key, value) in disk.ToList())
        {
            if (!mine.ContainsKey(key)) mine[key] = value?.DeepClone();
        }
        return mine;
    }
}
