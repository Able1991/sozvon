using Sozvon.App.Strings;

namespace Sozvon.App.Calls;

public enum CallStatus { Unknown, Recorded, Processing, Done, Failed }

public sealed record CallNote(string Text, DateTimeOffset? At, string Source);

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
    public IReadOnlyList<CallNote> Notes { get; init; } = [];
    public bool IsDemo { get; init; }
    public bool IsReflection { get; init; }
    public bool InfoPending { get; init; }
    public bool AudioRemoved { get; init; }
    public bool IsQueued { get; init; }
    public bool HasSummaryWarning { get; init; }
    public bool IsUnreadable { get; init; }

    /// <summary>Text of a call that lives only in memory (the demo call); real calls are read from the folder.</summary>
    public CallContent? InlineContent { get; init; }

    public string Title => Topic.Length > 0 ? Topic : Loc.L("Звонок");

    public double DurationSeconds => Math.Max(MicSeconds, SystemSeconds);

    public bool IsWaitingForDescription => InfoPending && Status == CallStatus.Recorded;
}

/// <summary>The text of a call, loaded when it is opened.</summary>
public sealed record CallContent(string Transcript, string Summary);
