using System.Runtime.InteropServices;
using Sozvon.App.Shell;

namespace Sozvon.App.Recording;

public enum Chime { Start, Stop }

/// <summary>
/// The Mac's pair of soft tones for the start and the stop of a recording. Windows' loopback hears every sound the
/// computer plays, Sozvon's own too, so the start tone ends before the capture begins and the stop tone plays after it
/// has ended; during a call there is none, since the microphone would carry it to the other side.
/// </summary>
public static partial class Chimes
{
    private const uint SndSync = 0x0000, SndNoDefault = 0x0002, SndFileName = 0x00020000;

    [LibraryImport("winmm.dll", EntryPoint = "PlaySoundW", StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool PlaySound(string sound, nint module, uint flags);

    /// <summary>Plays the tone to its end, off the UI thread; a missing file or no sound device is silence.</summary>
    public static Task PlayAsync(Chime chime)
    {
        var file = AppPaths.Asset(chime == Chime.Start ? "record-start.wav" : "record-stop.wav");
        return File.Exists(file) ? Task.Run(() => PlaySound(file, 0, SndSync | SndNoDefault | SndFileName)) : Task.CompletedTask;
    }
}
