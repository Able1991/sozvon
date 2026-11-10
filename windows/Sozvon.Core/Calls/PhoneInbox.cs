using System.Text.RegularExpressions;

namespace Sozvon.Core.Calls;

/// <summary>What one step of the phone folder's watcher did.</summary>
public abstract record PhoneImport
{
    /// <summary>No file is ready.</summary>
    public sealed record Nothing : PhoneImport;

    /// <summary>The file became the call in <paramref name="CallDir"/>; it now lies in Imported.</summary>
    public sealed record Imported(string File, string CallDir, string Topic) : PhoneImport;

    /// <summary>The file cannot leave the folder (read-only): not tried again until the next launch.</summary>
    public sealed record Stuck(string File, string Message) : PhoneImport;

    /// <summary>The import failed and the file went to Failed; an empty message: the file has no audio.</summary>
    public sealed record Failed(string File, string Message) : PhoneImport;
}

/// <summary>
/// Recordings from the phone, as on the Mac: a folder the phone's recordings arrive in (iCloud Drive, OneDrive or any
/// other). Each new audio file becomes a call and goes to transcription. This is the part without UI: which files are
/// ready and where they go afterwards. Nothing is deleted: an imported file moves to a subfolder.
/// </summary>
public static partial class PhoneInbox
{
    /// <summary>Inside the watched folder: imported files stay here.</summary>
    public const string DoneFolder = "Imported";

    /// <summary>Files that could not be imported, so they are not tried again and again.</summary>
    public const string FailedFolder = "Failed";

    /// <summary>A file changed more recently than this may still be arriving.</summary>
    public static readonly TimeSpan Settle = TimeSpan.FromSeconds(10);

    /// <summary>
    /// Complete audio files directly in the folder, oldest first. Hidden files and files still being written are left
    /// for later; subfolders (Imported, Failed) are not looked into.
    /// </summary>
    public static IReadOnlyList<string> Ready(string dir, DateTime nowUtc)
    {
        try
        {
            return new DirectoryInfo(dir).EnumerateFiles()
                .Where(f => !f.Name.StartsWith('.') && (f.Attributes & (FileAttributes.Hidden | FileAttributes.System)) == 0)
                .Where(f => CallImport.IsSupported(f.Name) && nowUtc - f.LastWriteTimeUtc >= Settle)
                .OrderBy(f => f.LastWriteTimeUtc)
                .ThenBy(f => f.Name, StringComparer.Ordinal)
                .Select(f => f.FullName)
                .ToList();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return [];
        }
    }

    /// <summary>Into a subfolder of its folder (or of <paramref name="root"/>), never over another file: "a.m4a", then "a 2.m4a". Where it went.</summary>
    public static string MoveAside(string file, string folder, string? root = null)
    {
        var dir = Path.Combine(root ?? Path.GetDirectoryName(file)!, folder);
        Directory.CreateDirectory(dir);
        var stem = Path.GetFileNameWithoutExtension(file);
        var extension = Path.GetExtension(file);
        var target = Path.Combine(dir, Path.GetFileName(file));
        for (var n = 2; File.Exists(target) || Directory.Exists(target); n++)
            target = Path.Combine(dir, $"{stem} {n}{extension}");
        File.Move(file, target);
        return target;
    }

    /// <summary>
    /// One step of the watcher: the oldest ready file is moved to Imported first (a file that cannot leave the folder would
    /// otherwise be imported on every step), then becomes a call. A failed import moves on to Failed.
    /// </summary>
    /// <param name="skip">Files that could not be moved before; they wait for the next launch.</param>
    public static async Task<PhoneImport> ImportNextAsync(string dir, string callsRoot, string ffmpeg, IReadOnlySet<string> skip, DateTime nowUtc)
    {
        if (Ready(dir, nowUtc).FirstOrDefault(f => !skip.Contains(f)) is not { } file) return new PhoneImport.Nothing();
        string claimed;
        try
        {
            claimed = MoveAside(file, DoneFolder);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return new PhoneImport.Stuck(file, e.Message);
        }
        try
        {
            var call = await CallImport.ImportAsync(claimed, callsRoot, ffmpeg);
            return new PhoneImport.Imported(file, call, Topic(file));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            try
            {
                MoveAside(claimed, FailedFolder, dir);
            }
            catch (Exception again) when (again is IOException or UnauthorizedAccessException)
            {
                // It stays in Imported: never tried again, and the message below still tells.
            }
            return new PhoneImport.Failed(file, e is NoAudioException ? "" : e.Message);
        }
    }

    /// <summary>The call's topic: the name the user gave the recording; a default name or a bare date says nothing.</summary>
    public static string Topic(string file)
    {
        var name = Path.GetFileNameWithoutExtension(file).Trim();
        if (GenericName().IsMatch(name)) return "";
        return name.All(c => char.IsDigit(c) || " -_.:".Contains(c)) ? "" : name;
    }

    /// <summary>The Mac's names, plus Windows Sound Recorder's "Recording (2)" and Android's "Voice 001".</summary>
    [GeneratedRegex(@"^(?i:new recording|новая запись|think out loud|recording|запись|voice)( \(?\d+\)?)?$")]
    private static partial Regex GenericName();
}
