namespace Sozvon.Audio.Tracks;

/// <summary>The level scales of the Mac app (SozvonCore Levels).</summary>
internal static class Levels
{
    /// <summary>The scale of the warnings and the quiet check: -50...0 dB as 0...1.</summary>
    public static float Meter(float rms) => Math.Clamp((Db(rms) + 50) / 50, 0, 1);

    /// <summary>The capsule's waves: -75...-25 dB as 0...1, so a quiet microphone still shows.</summary>
    public static float Display(float rms) => Math.Clamp((Db(rms) + 75) / 50, 0, 1);

    /// <summary>Below -80 dB: a dead device. A quiet room is never this low.</summary>
    public static bool IsDigitalSilence(float rms) => rms < 1e-4f;

    private static float Db(float rms) => 20 * MathF.Log10(MathF.Max(rms, 1e-6f));
}

/// <summary>One source that went quiet: captured again after two minutes, then the user is told.</summary>
internal sealed class SilenceWatch(bool patient = false)
{
    public enum Action { None, Restart, Tell }

    public const int RestartAfter = 120;
    public const int TellAfterRestart = 30;
    public const int ListeningAfter = 300;
    public const int HeardAfterUpdates = 30;

    private int _soundUpdates;
    private bool _restarted;
    private bool _told;

    private bool Heard => _soundUpdates >= HeardAfterUpdates;

    /// <summary>A person who was heard and went quiet is probably listening: they get more time.</summary>
    public int TellAfter => patient && Heard ? ListeningAfter : RestartAfter + TellAfterRestart;

    public Action Update(int silent, bool sound = false)
    {
        if (sound && _soundUpdates < HeardAfterUpdates) _soundUpdates++;
        if (silent <= 0)
        {
            _restarted = false;
            _told = false;
            return Action.None;
        }
        if (!_restarted)
        {
            if (silent < RestartAfter) return Action.None;
            _restarted = true;
            return Action.Restart;
        }
        if (_told || silent < TellAfter) return Action.None;
        _told = true;
        return Action.Tell;
    }

    public bool Warns(int silent) => silent >= TellAfter;
}

/// <summary>Says once that the microphone works but the user has been very quiet for three minutes.</summary>
internal sealed class QuietMicWatch
{
    public const float Loud = 0.2f;
    public const int After = 180;

    private bool _loudSeen;
    private bool _told;

    public bool Update(float level, int seconds)
    {
        if (level >= Loud) _loudSeen = true;
        if (_told || _loudSeen || seconds < After) return false;
        _told = true;
        return true;
    }
}

internal readonly record struct WatchResult(RecorderLevels Levels, bool RecaptureMic, bool RecaptureSystem,
    IReadOnlyList<RecorderAlert> Alerts);

/// <summary>Turns the two track meters into capsule levels, warnings and recaptures, as the Mac app does.</summary>
internal sealed class RecordingWatch(double startedAt)
{
    public const double FreshSeconds = 1.5;
    public const float SilenceLevel = 0.01f;
    public const int MicMissingWarnAfter = 8;

    private readonly SilenceWatch _micWatch = new();
    private readonly SilenceWatch _systemWatch = new(patient: true);
    private readonly QuietMicWatch _quietWatch = new();
    private double? _systemSilentSince;
    private double? _micMissingSince;
    private double? _micSilentSince;

    public WatchResult Update(double now, TrackMeter mic, TrackMeter system)
    {
        bool micFresh = IsFresh(mic, now);
        bool systemFresh = IsFresh(system, now);
        float micLevel = micFresh ? Levels.Meter(mic.Rms) : 0;
        float systemLevel = systemFresh ? Levels.Meter(system.Rms) : 0;

        _systemSilentSince = systemLevel > SilenceLevel ? null : _systemSilentSince ?? now;
        _micMissingSince = micFresh ? null : _micMissingSince ?? now;
        _micSilentSince = micFresh && !Levels.IsDigitalSilence(mic.Rms) ? null : _micSilentSince ?? now;

        int systemSilent = Seconds(_systemSilentSince, now);
        int micMissing = Seconds(_micMissingSince, now);
        int micSilent = Seconds(_micSilentSince, now);

        var alerts = new List<RecorderAlert>();
        SilenceWatch.Action micAction = _micWatch.Update(micSilent);
        SilenceWatch.Action systemAction = _systemWatch.Update(systemSilent, systemLevel > SilenceLevel);
        if (micAction == SilenceWatch.Action.Tell) alerts.Add(new RecorderAlert(RecorderAlertKind.MicrophoneSilent, micSilent));
        if (systemAction == SilenceWatch.Action.Tell) alerts.Add(new RecorderAlert(RecorderAlertKind.SystemSilent, systemSilent));
        if (micSilent == 0 && _quietWatch.Update(micLevel, (int)(now - startedAt)))
        {
            alerts.Add(new RecorderAlert(RecorderAlertKind.MicrophoneQuiet, QuietMicWatch.After));
        }

        TrackWarning? warning = null;
        if (micMissing >= MicMissingWarnAfter || _micWatch.Warns(micSilent)) warning = new TrackWarning(RecordingTrack.Microphone, micSilent);
        else if (_systemWatch.Warns(systemSilent)) warning = new TrackWarning(RecordingTrack.System, systemSilent);

        var levels = new RecorderLevels(micFresh ? Levels.Display(mic.Rms) : 0, systemFresh ? Levels.Display(system.Rms) : 0, warning);
        return new WatchResult(levels, micAction == SilenceWatch.Action.Restart, systemAction == SilenceWatch.Action.Restart, alerts);
    }

    private static bool IsFresh(TrackMeter meter, double now) =>
        meter.LastPacketAt is double at && now - at < FreshSeconds;

    private static int Seconds(double? since, double now) => since is double s ? (int)(now - s) : 0;
}
