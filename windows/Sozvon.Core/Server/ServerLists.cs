using System.Text.Json.Nodes;
using Sozvon.Core.Foundation;

namespace Sozvon.Core.Server;

/// <summary>
/// The app's lists for the own server's sync (contract: <c>server-deleted.json</c> and <c>server-restore.json</c>),
/// <c>{"schema": 1, "calls": [{"id": "...", "at": "..."}]}</c>, changed only under their <c>.lock</c>, which the engine
/// takes too. A call moved to the Recycle Bin in Sozvon while a server is set up goes on the deleted list: the next
/// sync deletes it on the server instead of downloading it back.
/// </summary>
public static class ServerLists
{
    public const string DeletedFile = "server-deleted.json";
    public const string RestoreFile = "server-restore.json";

    public static IReadOnlyList<string> Ids(string file) =>
        Entries(file).Select(Id).OfType<string>().ToList();

    /// <summary>Adds the call once. Throws when the list cannot be written: the call would stay on the server.</summary>
    public static void Add(string file, string id, DateTimeOffset at) => Change(file, list =>
    {
        if (list.Any(e => Id(e) == id)) return false;
        list.Add(new JsonObject { ["id"] = id, ["at"] = Iso8601.Seconds(at) });
        return true;
    });

    public static void Remove(string file, string id) => Change(file, list =>
    {
        var gone = list.Where(e => Id(e) == id).ToList();
        foreach (var entry in gone) list.Remove(entry);
        return gone.Count > 0;
    });

    private static string? Id(JsonNode? entry) => entry?["id"] is JsonValue v && v.TryGetValue<string>(out var id) ? id : null;

    private static JsonArray Entries(string file) =>
        JsonFile.Read(file)?["calls"] is JsonArray calls ? new JsonArray(calls.Where(c => c is JsonObject).Select(c => c!.DeepClone()).ToArray()) : [];

    private static void Change(string file, Func<JsonArray, bool> change)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        FileLock.With(file, () =>
        {
            var list = Entries(file);
            if (change(list)) JsonFile.WriteAtomic(file, new JsonObject { ["schema"] = 1, ["calls"] = list });
            return true;
        });
    }
}
