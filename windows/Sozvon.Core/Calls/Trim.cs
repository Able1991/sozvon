using System.Text.Json.Nodes;
using Sozvon.Core.Foundation;

namespace Sozvon.Core.Calls;

/// <summary>Why Trim is off for a call, as on the Mac (Trim.swift).</summary>
public enum TrimUnavailable { Busy, Demo, AudioRemoved, NoAudio, TooShort }

/// <summary>
/// Trim a recording (cut its start and end): when it is not available and where the silence hint puts the handles. The
/// cut itself is the engine's <c>bin/trim_call.py</c>; the app queues the transcription afterwards.
/// </summary>
public static class Trim
{
    public const string Script = "trim_call.py";

    /// <summary>call.json: the user dismissed the "quiet at the start or end" hint for this call.</summary>
    public const string HintDismissedKey = "trim_hint_dismissed";

    /// <summary>call.json, written by the engine at the end of a full run: seconds of quiet at the start and the end.</summary>
    public const string SilenceKey = "silence";

    /// <summary>A call shorter than this cannot be trimmed.</summary>
    public const double MinCallSeconds = 30;

    /// <summary>Quiet at the start or end this long raises the hint.</summary>
    public const double HintSeconds = 60;

    /// <summary>The trimmed range is at least this long (the engine's rule).</summary>
    public const double MinRangeSeconds = 10;

    /// <summary>The handles keep this much of the quiet around the speech.</summary>
    internal const double Margin = 2;

    /// <summary>Shown next to the disabled Trim action (keys of the text tables).</summary>
    public static string Reason(TrimUnavailable why) => why switch
    {
        TrimUnavailable.Busy => "Звонок записывается или расшифровывается",
        TrimUnavailable.AudioRemoved => "Звук удалён по настройке «Автоудаление аудио»",
        TrimUnavailable.NoAudio => "Звука этого звонка нет на этом компьютере",
        TrimUnavailable.Demo => "Это демонстрационный звонок",
        _ => "Звонок короче 30 секунд",
    };

    /// <summary>Why Trim is off for a call, or null. Precedence: busy, demo, audio removed, no audio, too short.</summary>
    public static TrimUnavailable? Unavailable(JsonObject call, bool hasAudio, bool busy)
    {
        if (busy) return TrimUnavailable.Busy;
        if (call.Flag("demo") == true) return TrimUnavailable.Demo;
        if (call[AudioRetention.RemovedKey] is not null) return TrimUnavailable.AudioRemoved;
        if (!hasAudio) return TrimUnavailable.NoAudio;
        if (AudioTimes.From(call.Object("audio")).Duration < MinCallSeconds) return TrimUnavailable.TooShort;
        return null;
    }

    /// <summary>The suggested range from the measured silence, or null: dismissed, not measured, or both ends under a minute.</summary>
    public static TrimHint? Hint(JsonObject call, double duration)
    {
        if (call.Flag(HintDismissedKey) == true || call.Object(SilenceKey) is not { } silence) return null;
        var head = silence.Number("head") ?? 0;
        var tail = silence.Number("tail") ?? 0;
        if (head < HintSeconds && tail < HintSeconds) return null;
        var start = head >= HintSeconds ? Math.Max(0, head - Margin) : 0;
        var end = tail >= HintSeconds ? Math.Min(duration, duration - tail + Margin) : duration;
        // Silence data that does not fit the call, or leaves under the minimum range, gives no hint.
        if (end - start < MinRangeSeconds) return null;
        static int Minutes(double seconds) => seconds >= HintSeconds ? (int)Math.Round(seconds / 60, MidpointRounding.AwayFromZero) : 0;
        return new TrimHint(start, end, start > 0 ? Minutes(head) : 0, end < duration ? Minutes(tail) : 0);
    }

    /// <summary>The hint goes away for this call: call.json <c>trim_hint_dismissed</c>.</summary>
    public static bool DismissHint(string dir) => CallFile.Update(dir, c => c[HintDismissedKey] = true);
}

/// <summary>The silence hint of one call, as the call card shows it.</summary>
/// <param name="HeadMinutes">Whole minutes of quiet at the start; 0: the start is not part of the hint.</param>
/// <param name="TailMinutes">The same at the end.</param>
public sealed record TrimHint(double Start, double End, int HeadMinutes, int TailMinutes);

public enum TrimHandle { Start, End }

/// <summary>What Cancel or Escape did.</summary>
public enum TrimCancelResult
{
    /// <summary>The panel closes and the player comes back.</summary>
    Close,

    /// <summary>The confirmation went away: the handles can be moved again.</summary>
    BackToEditing,

    /// <summary>Nothing to cancel: the engine is cutting.</summary>
    None,
}

public enum TrimPhase { Editing, Confirming, Working }

/// <summary>
/// The trim panel's state, as on the Mac (TrimEditing.swift): where the handles are, how the keys move them, and what
/// Cancel and Escape do in each phase. The panel only draws it and feeds it events.
/// </summary>
public sealed class TrimState
{
    /// <summary>A handle moves this far per arrow key, ten times as far with Shift.</summary>
    public const double KeyStep = 1;
    public const double ShiftKeyStep = 10;

    /// <summary>The handles of a call <paramref name="duration"/> long: the silence hint's, or the whole call.</summary>
    public TrimState(double duration, TrimHint? hint)
    {
        Start = hint?.Start ?? 0;
        End = hint?.End ?? duration;
    }

    public double Start { get; private set; }
    public double End { get; private set; }
    public TrimPhase Phase { get; set; } = TrimPhase.Editing;

    public double Value(TrimHandle h) => h == TrimHandle.Start ? Start : End;

    /// <summary>Puts a handle at <paramref name="t"/>: within the call, and at least the engine's minimum range from the other one.</summary>
    public void Set(TrimHandle h, double t, double duration)
    {
        const double gap = Trim.MinRangeSeconds;
        if (h == TrimHandle.Start) Start = Math.Min(Math.Max(0, t), Math.Max(0, End - gap));
        else End = Math.Max(Math.Min(duration, t), Math.Min(duration, Start + gap));
    }

    /// <summary>Cancel or Escape: the confirmation goes back to editing, editing closes the panel, the cut can't be stopped.</summary>
    public TrimCancelResult Cancel()
    {
        switch (Phase)
        {
            case TrimPhase.Editing:
                return TrimCancelResult.Close;
            case TrimPhase.Confirming:
                Phase = TrimPhase.Editing;
                return TrimCancelResult.BackToEditing;
            default:
                return TrimCancelResult.None;
        }
    }

    /// <summary>An arrow moves <paramref name="handle"/> by a second, ten with Shift, while editing. False: not the panel's key now.</summary>
    public bool Move(TrimHandle handle, int direction, bool shift, double duration)
    {
        if (Phase != TrimPhase.Editing) return false;
        Set(handle, Value(handle) + Math.Sign(direction) * (shift ? ShiftKeyStep : KeyStep), duration);
        return true;
    }
}
