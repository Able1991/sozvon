namespace Sozvon.Core.Automation;

// What happens around a call beyond the "Record?" prompt, as on the Mac (SozvonCore CallAutomation.swift, Sozvon
// CallPrompt.swift):
//   start: ask (the prompt), record by itself after a short countdown, or nothing;
//   end:   optionally stop the recording once no call app has held the microphone for a while.
// Every automatic start and stop is shown on the capsule with a way to cancel it.

/// <summary>What Sozvon does when a call app starts using the microphone. The values are the Settings row's order.</summary>
public enum CallStartMode
{
    /// <summary>"A call is on in Zoom. Record?" (default).</summary>
    Ask = 0,

    /// <summary>The same capsule with a countdown: it records when the countdown runs out, unless cancelled.</summary>
    Record = 1,

    Off = 2,
}

public static class CallAutomation
{
    /// <summary>Seconds between noticing the call (after <see cref="CallDetector.Debounce"/>) and the automatic start.</summary>
    public const int StartCountdown = 10;

    /// <summary>
    /// Seconds without any call app on the microphone before the recording stops. Call apps let go of the microphone for
    /// a moment when they reconnect or switch devices: a short gap must not end the recording.
    /// </summary>
    public const int StopGrace = 30;

    /// <summary>A Settings value from an older or newer version falls back to asking.</summary>
    public static CallStartMode Mode(int stored) => Enum.IsDefined((CallStartMode)stored) ? (CallStartMode)stored : CallStartMode.Ask;
}

/// <summary>
/// During one recording: notices that the call is over. Armed once a call app has held the microphone for
/// <see cref="ArmHold"/> in a row during the recording, so a recording of a meeting in the room is never stopped and a
/// voice message during it doesn't count. The countdown runs while no call app holds the microphone and the other side
/// is silent: an app that releases the microphone on mute is still a call as long as someone is heard. "Keep recording"
/// cancels it for the rest of this recording.
/// </summary>
public sealed class CallEndDetector
{
    public static readonly TimeSpan ArmHold = TimeSpan.FromSeconds(15);

    private DateTimeOffset? _heldSince;
    private DateTimeOffset? _releasedAt;

    public bool Armed { get; private set; }

    public bool Kept { get; private set; }

    /// <summary>The seconds left until the recording should stop (0: stop now), or null when there is no countdown.</summary>
    /// <param name="inCall">A call app holds the microphone now.</param>
    /// <param name="otherSideAudible">The other side's track has sound now.</param>
    public double? Update(bool inCall, bool otherSideAudible, DateTimeOffset now, int grace = CallAutomation.StopGrace)
    {
        if (inCall)
        {
            var since = _heldSince ??= now;
            if (now - since >= ArmHold) Armed = true;
            _releasedAt = null;
            return null;
        }
        if (_heldSince is { } held && now - held >= ArmHold) Armed = true;
        _heldSince = null;
        if (!Armed || Kept || otherSideAudible)
        {
            _releasedAt = null;
            return null;
        }
        var released = _releasedAt ??= now;
        return Math.Max(0, grace - (now - released).TotalSeconds);
    }

    /// <summary>"Keep recording": no automatic stop for the rest of this recording.</summary>
    public void KeepRecording()
    {
        Kept = true;
        _releasedAt = null;
    }
}

/// <summary>Whole seconds on a countdown capsule.</summary>
public static class Countdown
{
    /// <summary>Seconds left, rounded up: 0.2 s left still shows 1.</summary>
    public static int Seconds(double left) => (int)Math.Ceiling(left);

    /// <summary>The start countdown at <paramref name="now"/>: the seconds to show (never negative) and whether the deadline has come.</summary>
    public static (int Shown, bool Due) StartTick(DateTimeOffset deadline, DateTimeOffset now)
    {
        int left = Seconds((deadline - now).TotalSeconds);
        return (Math.Max(left, 0), left <= 0);
    }
}

/// <summary>What the rules want done after an update.</summary>
public enum CallAction { None, Record, Stop }

/// <summary>Sozvon's side of an update: the settings and what the recorder is doing.</summary>
/// <param name="Busy">Recording, starting, stopping or unable to record: no prompt.</param>
/// <param name="Recording">A recording is running: the automatic stop watches only then.</param>
/// <param name="OtherSideAudible">The other side's track has sound right now: the call is not over, whatever the microphone says.</param>
public readonly record struct CallSituation(CallStartMode Mode, bool AutoStop, bool Busy, bool Recording, bool OtherSideAudible);

/// <summary>
/// The prompt, the start countdown and the stop countdown together, without timers: the app calls
/// <see cref="Update"/> about once a second with who holds the microphone, and does what it returns.
/// </summary>
public sealed class CallAutomationRules(int ownPid)
{
    private readonly CallDetector _detector = new(ownPid);
    private CallEndDetector _end = new();
    private DateTimeOffset? _startDeadline;

    public CallApp? Prompt => _detector.Prompt;

    /// <summary>Seconds left before the automatic start, while counting down.</summary>
    public int? StartIn { get; private set; }

    /// <summary>Seconds left before the automatic stop, while counting down.</summary>
    public int? StopIn { get; private set; }

    /// <summary>A known call app holds the microphone (as of the last update).</summary>
    public bool InCall => _detector.OnMic.Count > 0;

    public CallAction Update(IEnumerable<MicClient> clients, DateTimeOffset now, CallSituation situation)
    {
        // With "Do nothing" the detector still runs: it tells when a call is on for the automatic stop and the queue.
        _detector.Update(clients, now, situation.Busy || situation.Mode == CallStartMode.Off);
        if (Prompt is null || situation.Mode != CallStartMode.Record)
        {
            CancelStart();
        }
        else
        {
            var (shown, due) = Countdown.StartTick(_startDeadline ??= now.AddSeconds(CallAutomation.StartCountdown), now);
            if (due)
            {
                Record();
                return CallAction.Record;
            }
            StartIn = shown;
        }
        return CheckEnd(now, situation);
    }

    /// <summary>"Record" (now, without waiting for the countdown): the app is not offered again until it releases the mic.</summary>
    public void Record() => NotNow();

    /// <summary>"Not now" or "Don't record": nothing for this call until its app lets go of the microphone.</summary>
    public void NotNow()
    {
        CancelStart();
        _detector.Dismiss();
    }

    /// <summary>"Continue": the call looked over, but the recording goes on.</summary>
    public void KeepRecording()
    {
        _end.KeepRecording();
        StopIn = null;
    }

    private void CancelStart()
    {
        _startDeadline = null;
        StartIn = null;
    }

    private CallAction CheckEnd(DateTimeOffset now, CallSituation situation)
    {
        if (!situation.AutoStop || !situation.Recording)
        {
            _end = new CallEndDetector();
            StopIn = null;
            return CallAction.None;
        }
        if (_end.Update(InCall, situation.OtherSideAudible, now) is not { } left)
        {
            StopIn = null;
            return CallAction.None;
        }
        if (left <= 0)
        {
            _end = new CallEndDetector();
            StopIn = null;
            return CallAction.Stop;
        }
        StopIn = Countdown.Seconds(left);
        return CallAction.None;
    }
}
