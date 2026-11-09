using System.Globalization;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Sozvon.Audio.Session;

/// <summary>Records the facts of a stopped recording in call.json, keeping every other field, under the engine's lock.</summary>
internal static class CallFileAudio
{
    private const string FileName = "call.json";
    private const int Schema = 1;
    private static readonly TimeSpan s_lockTimeout = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan s_lockRetry = TimeSpan.FromMilliseconds(50);

    private static readonly JsonSerializerOptions s_write = new()
    {
        WriteIndented = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    /// <exception cref="InvalidDataException">An existing call.json is not a JSON object; it is left as it is.</exception>
    public static async Task WriteAsync(string callDirectory, DateTimeOffset startedAt, AudioTimes audio,
        IReadOnlyList<double> marks, CancellationToken cancellationToken)
    {
        string path = Path.Combine(callDirectory, FileName);
        using FileStream guard = await AcquireLockAsync(path + ".lock", cancellationToken).ConfigureAwait(false);

        JsonObject call = Read(path);
        call["schema"] = Schema;
        call["created_at"] = startedAt.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
        call["audio"] = AudioNode(audio);
        call["status"] = "recorded";
        if (marks.Count > 0) call["marks"] = new JsonArray(marks.Select(m => (JsonNode?)JsonValue.Create(m)).ToArray());

        string temporary = Path.Combine(callDirectory, $".call.json.{Guid.NewGuid():N}.tmp");
        try
        {
            await File.WriteAllTextAsync(temporary, call.ToJsonString(s_write), cancellationToken).ConfigureAwait(false);
            File.Move(temporary, path, overwrite: true);
        }
        finally
        {
            File.Delete(temporary);
        }
    }

    private static JsonObject Read(string path)
    {
        if (!File.Exists(path)) return [];
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        try
        {
            return JsonNode.Parse(stream) as JsonObject ?? throw new InvalidDataException($"{path} is not a JSON object");
        }
        catch (JsonException ex)
        {
            throw new InvalidDataException($"{path} is not valid JSON", ex);
        }
    }

    private static JsonObject AudioNode(AudioTimes audio)
    {
        var node = new JsonObject();
        if (audio.MicStart is double mic)
        {
            node["mic_start"] = mic;
            node["mic_seconds"] = audio.MicSeconds;
        }
        if (audio.SystemStart is double system)
        {
            node["system_start"] = system;
            node["system_seconds"] = audio.SystemSeconds;
        }
        return node;
    }

    private static async Task<FileStream> AcquireLockAsync(string path, CancellationToken cancellationToken)
    {
        var stream = new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.ReadWrite | FileShare.Delete);
        DateTime deadline = DateTime.UtcNow + s_lockTimeout;
        try
        {
            while (!TryLock(stream, deadline))
            {
                await Task.Delay(s_lockRetry, cancellationToken).ConfigureAwait(false);
            }
            return stream;
        }
        catch
        {
            await stream.DisposeAsync().ConfigureAwait(false);
            throw;
        }
    }

    private static bool TryLock(FileStream stream, DateTime deadline)
    {
        try
        {
            stream.Lock(0, 1);
            return true;
        }
        catch (IOException) when (DateTime.UtcNow < deadline)
        {
            return false;
        }
    }
}
