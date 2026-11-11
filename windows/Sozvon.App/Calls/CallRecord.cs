using Sozvon.App.Strings;

namespace Sozvon.App.Calls;

public enum CallStatus { Unknown, Recorded, Processing, Done, Failed }

/// <summary>One call as listed: what call.json says, with no transcript or summary text yet.</summary>
public sealed record CallRecord
{
    public required string Folder { get; init; }
    public required string Id { get; init; }
    public DateTimeOffset? CreatedAt { get; init; }
    public CallStatus Status { get; init; }
    public string Topic { get; init; } = "";
    public string ProjectSlug { get; init; } = "";
    public string ProjectTitle { get; init; } = "";
    public IReadOnlyList<string> People { get; init; } = [];
    public double MicSeconds { get; init; }
    public double SystemSeconds { get; init; }
    public double? MicStart { get; init; }
    public double? SystemStart { get; init; }
    public IReadOnlyList<Sozvon.Core.Calls.CallNote> Notes { get; init; } = [];

    /// <summary>call.json has <c>participants</c>; otherwise <see cref="People"/> are only the typed names.</summary>
    public bool HasParticipants { get; init; }
    public bool IsDemo { get; init; }
    public bool IsReflection { get; init; }
    public bool InfoPending { get; init; }
    public bool AudioRemoved { get; init; }

    /// <summary>mic.m4a or system.m4a is there: the call can be played and transcribed again.</summary>
    public bool HasAudio { get; init; }
    public bool IsQueued { get; init; }
    /// <summary>Why the summary failed on the last run (call.json <c>warnings</c>), on one line; null when it did not.</summary>
    public string? SummaryWarning { get; init; }
    public bool HasSummaryWarning => SummaryWarning is not null;
    public bool IsUnreadable { get; init; }

    /// <summary>Text of a call that lives only in memory (the demo call); real calls are read from the folder.</summary>
    public CallContent? InlineContent { get; init; }

    public string Title => Topic.Length > 0 ? Topic : Loc.L("Звонок");

    public double DurationSeconds => Math.Max(MicSeconds, SystemSeconds);

    public bool IsWaitingForDescription => InfoPending && Status == CallStatus.Recorded;
}

/// <summary>The text of a call, loaded when it is opened.</summary>
public sealed record CallContent(string Transcript, string Summary);
