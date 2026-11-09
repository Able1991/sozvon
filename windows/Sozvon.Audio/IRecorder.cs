namespace Sozvon.Audio;

/// <summary>Records one call into mic.m4a and system.m4a in the call's folder.</summary>
public interface IRecorder
{
    /// <summary>About ten times a second while recording, on a background thread.</summary>
    event EventHandler<RecorderLevels>? LevelsChanged;

    /// <summary>Once per episode, when a track has been silent long enough to tell the user.</summary>
    event EventHandler<RecorderAlert>? AlertRaised;

    /// <summary>The recording cannot continue (a full disk). The caller should stop to save what was written.</summary>
    event EventHandler<Exception>? Failed;

    bool IsRecording { get; }

    /// <summary>Opens the devices and starts writing into an existing folder that has no tracks yet.</summary>
    /// <exception cref="RecorderStartException">The microphone could not be opened.</exception>
    Task StartAsync(string callDirectory, CancellationToken cancellationToken = default);

    /// <summary>The star: remembers this moment. False when not recording or within 5 s of the previous mark.</summary>
    bool Mark();

    /// <summary>Stops, encodes and writes call.json. On failure the audio stays recoverable (<see cref="RecordingRecovery"/>).</summary>
    Task<RecordingResult> StopAsync(CancellationToken cancellationToken = default);
}

public enum RecordingTrack { Microphone, System }

/// <summary>A track silent right now, for the capsule. <paramref name="Seconds"/> is how long it has been.</summary>
public sealed record TrackWarning(RecordingTrack Track, int Seconds);

/// <summary>Levels on the capsule's display scale, 0 to 1.</summary>
public sealed record RecorderLevels(float Microphone, float System, TrackWarning? Warning);

public enum RecorderAlertKind { MicrophoneSilent, SystemSilent, MicrophoneQuiet }

public sealed record RecorderAlert(RecorderAlertKind Kind, int Seconds);

/// <summary>What call.json's audio holds. A track that recorded nothing has a null start.</summary>
public sealed record AudioTimes(double? MicStart, double? SystemStart, double MicSeconds, double SystemSeconds);

/// <param name="Marks">Seconds on the transcript timeline, sorted.</param>
/// <param name="MicrophoneRaw">The microphone was captured without Windows or driver processing.</param>
public sealed record RecordingResult(AudioTimes Audio, IReadOnlyList<double> Marks, bool MicrophoneRaw);

public sealed class RecorderStartException(string message, bool accessDenied, Exception? inner = null)
    : Exception(message, inner)
{
    /// <summary>Windows privacy settings refuse this app the microphone.</summary>
    public bool AccessDenied { get; } = accessDenied;
}

/// <param name="FfmpegPath">Absolute path of the engine's ffmpeg.</param>
/// <param name="LogPath">Where capture events are appended, or null for no log.</param>
public sealed record RecorderOptions(string FfmpegPath, string? LogPath)
{
    public static RecorderOptions ForDataDirectory(string dataDirectory) => new(
        Path.Combine(dataDirectory, ".venv", "Scripts", "ffmpeg.exe"),
        Path.Combine(dataDirectory, "Logs", "recorder.log"));
}
