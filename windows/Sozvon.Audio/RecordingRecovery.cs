using Sozvon.Audio.Session;

namespace Sozvon.Audio;

/// <summary>Finishes recordings that a crash or a failed encoding left behind.</summary>
public static class RecordingRecovery
{
    /// <summary>The call folders under <paramref name="callsDirectory"/> with an unfinished recording not in progress.</summary>
    public static IReadOnlyList<string> FindInterrupted(string callsDirectory)
    {
        if (!Directory.Exists(callsDirectory)) return [];
        return Directory.EnumerateDirectories(callsDirectory)
            .Where(call => Directory.Exists(Path.Combine(call, SessionFiles.FolderName)) && !IsBeingRecorded(new SessionFiles(call)))
            .ToList();
    }

    /// <summary>Encodes what was spooled and writes call.json, as a normal stop would.</summary>
    /// <exception cref="IOException">Encoding failed; the session stays for another attempt.</exception>
    public static Task<RecordingResult> RecoverAsync(string callDirectory, string ffmpegPath, CancellationToken cancellationToken = default)
    {
        var files = new SessionFiles(callDirectory);
        SessionJournal journal = SessionJournal.Load(files.Journal)
            ?? new SessionJournal(Directory.GetCreationTimeUtc(callDirectory), null, null, []);
        return RecordingFinalizer.FinalizeAsync(files, journal, journal.Marks, ffmpegPath, microphoneRaw: false, cancellationToken);
    }

    /// <summary>A live recording holds its spool files open for writing, which refuses this exclusive open.</summary>
    private static bool IsBeingRecorded(SessionFiles files)
    {
        foreach (string wav in new[] { files.MicWav, files.SystemWav })
        {
            if (!File.Exists(wav)) continue;
            try
            {
                using var probe = new FileStream(wav, FileMode.Open, FileAccess.Read, FileShare.Read);
            }
            catch (IOException)
            {
                return true;
            }
        }
        return false;
    }
}
