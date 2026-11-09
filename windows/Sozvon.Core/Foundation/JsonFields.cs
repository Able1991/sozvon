using System.Text.Json.Nodes;

namespace Sozvon.Core.Foundation;

/// <summary>Typed reads of a JSON object: a missing field or one of another type is null, never an error.</summary>
public static class JsonFields
{
    public static string? Text(this JsonObject o, string key) =>
        o[key] is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;

    public static bool? Flag(this JsonObject o, string key) =>
        o[key] is JsonValue v && v.TryGetValue<bool>(out var b) ? b : null;

    public static int? Int(this JsonObject o, string key) =>
        o[key] is JsonValue v && v.TryGetValue<int>(out var i) ? i : null;

    public static double? Number(this JsonObject o, string key) =>
        o[key] is JsonValue v && v.TryGetValue<double>(out var d) ? d : null;

    public static JsonObject? Object(this JsonObject o, string key) => o[key] as JsonObject;

    /// <summary>The field as a list of strings; null unless it is an array holding only strings.</summary>
    public static List<string>? Texts(this JsonObject o, string key)
    {
        if (o[key] is not JsonArray array) return null;
        var list = new List<string>(array.Count);
        foreach (var item in array)
        {
            if (item is not JsonValue v || !v.TryGetValue<string>(out var s)) return null;
            list.Add(s);
        }
        return list;
    }

    public static JsonArray ToJsonArray(this IEnumerable<string> items) =>
        new(items.Select(s => (JsonNode?)JsonValue.Create(s)).ToArray());
}
