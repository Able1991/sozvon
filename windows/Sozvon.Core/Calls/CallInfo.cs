using System.Text.Json.Nodes;
using Sozvon.Core.Foundation;
using Sozvon.Core.Settings;

namespace Sozvon.Core.Calls;

/// <summary>What the user said about the call before transcription (call.json fields).</summary>
public sealed record CallInfo
{
    public string Profile { get; set; } = "";

    /// <summary>The participants the user typed, comma-separated (call.json <c>names</c>).</summary>
    public string Names { get; set; } = "";

    public string Topic { get; set; } = "";
    public string Terms { get; set; } = "";
    public bool Summary { get; set; } = true;
    public IReadOnlyList<SpeechLanguage> Languages { get; set; } = [SpeechLanguage.Ru];

    /// <summary>The user alone, thinking out loud (call.json <c>kind</c>).</summary>
    public bool Reflection { get; set; }

    /// <summary>A model chosen for this call (call.json <c>model</c>); null: auto, by the settings and the call's language.</summary>
    public WhisperModel? Model { get; set; }

    public bool Equals(CallInfo? other) =>
        other is not null && Profile == other.Profile && Names == other.Names && Topic == other.Topic
        && Terms == other.Terms && Summary == other.Summary && Reflection == other.Reflection
        && Model == other.Model && Languages.SequenceEqual(other.Languages);

    public override int GetHashCode() => HashCode.Combine(Profile, Names, Topic, Terms, Summary, Reflection);
}

/// <summary>Track offsets and durations on the shared capture clock (call.json <c>audio</c>).</summary>
public sealed record AudioTimes(double? MicStart = null, double? SystemStart = null, double MicSeconds = 0, double SystemSeconds = 0)
{
    public double Duration => Math.Max(MicSeconds, SystemSeconds);

    public static AudioTimes From(JsonObject? o) => o is null
        ? new AudioTimes()
        : new AudioTimes(o.Number("mic_start"), o.Number("system_start"), o.Number("mic_seconds") ?? 0, o.Number("system_seconds") ?? 0);

    public JsonObject ToJson()
    {
        var o = new JsonObject();
        if (MicStart is { } mic)
        {
            o["mic_start"] = mic;
            o["mic_seconds"] = MicSeconds;
        }
        if (SystemStart is { } system)
        {
            o["system_start"] = system;
            o["system_seconds"] = SystemSeconds;
        }
        return o;
    }
}

public enum CallStatus { Recorded, Processing, Done, Failed }

public static class CallStatuses
{
    public static string Key(this CallStatus s) => s.ToString().ToLowerInvariant();

    public static CallStatus? FromKey(string? key) =>
        Enum.GetValues<CallStatus>().Where(s => s.Key() == key).Cast<CallStatus?>().FirstOrDefault();
}
