using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Sozvon.Core.Foundation;

/// <summary>JSON objects on disk, in the engine's format: UTF-8 without a BOM, indented, written atomically.</summary>
public static class JsonFile
{
    private static readonly JsonSerializerOptions Output = new()
    {
        WriteIndented = true,
        IndentSize = 2,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    /// <summary>The object in the file, or null. <paramref name="exists"/> tells a broken file from a missing one.</summary>
    public static JsonObject? Read(string path, out bool exists)
    {
        var text = SharedFile.ReadText(path);
        exists = text is not null;
        return text is null ? null : Parse(text);
    }

    public static JsonObject? Read(string path) => Read(path, out _);

    /// <summary>The JSON object in the text, or null for anything else.</summary>
    public static JsonObject? Parse(string text)
    {
        try
        {
            var parsed = JsonNode.Parse(text) as JsonObject;
            _ = parsed?.Count; // a duplicate key only fails once the object is materialized
            return parsed;
        }
        catch (Exception e) when (e is JsonException or ArgumentException or InvalidOperationException)
        {
            return null;
        }
    }

    public static void WriteAtomic(string path, JsonObject content)
    {
        var text = content.ToJsonString(Output) + "\n";
        AtomicFile.Write(path, new UTF8Encoding(false).GetBytes(text));
    }
}
