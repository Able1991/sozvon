using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using Sozvon.Core.Foundation;

namespace Sozvon.Core.Calls;

/// <summary>Why a folder cannot be the calls folder.</summary>
public enum CallsFolderProblem
{
    /// <summary>The folder in use now.</summary>
    Same,

    /// <summary>Inside the current calls folder: it would look like a call.</summary>
    Inside,

    /// <summary>The current calls folder is inside it: the calls would sit next to their own copies.</summary>
    Contains,

    /// <summary>The engine's own folder or inside it (models, environment): reinstalling the engine would take the calls.</summary>
    EngineData,
}

/// <summary>The calls could not move. Either names already taken in the new folder, or a copy that did not match.</summary>
public sealed class CallsFolderMoveException : IOException
{
    public CallsFolderMoveException(IReadOnlyList<string> taken) : base("taken: " + string.Join(", ", taken)) => Taken = taken;

    public CallsFolderMoveException(string mismatch) : base("copy mismatch: " + mismatch)
    {
        Taken = [];
        Mismatch = mismatch;
    }

    /// <summary>These call folder names already exist in the new folder; nothing moved.</summary>
    public IReadOnlyList<string> Taken { get; }

    /// <summary>The copy of this call on the other drive did not match its original; the original stays.</summary>
    public string? Mismatch { get; }
}

/// <summary>
/// Where the calls live, as on the Mac (CallsFolder.swift): %USERPROFILE%\Sozvon Calls unless the user picked another
/// folder (the setup wizard or Settings, Recognition, Files). A new folder can take the calls along: on the same drive
/// each call folder is renamed; on another drive it is copied, the copy is compared with the original file by file (size
/// and SHA-256), and only then the original goes to the Recycle Bin. Nothing moves when any name is already taken.
/// </summary>
public static class CallsFolder
{
    /// <summary>The key in settings.json of the data folder; absent for the default folder.</summary>
    public const string SettingKey = "CallsFolder";

    /// <summary>A recording in progress spools here (Sozvon.Audio's SessionFiles.FolderName).</summary>
    public const string RecordingFolder = ".recording";

    private const int ErrorNotSameDevice = 17;

    /// <summary>The folder the user picked, null for the default (or an unreadable settings.json).</summary>
    public static string? Chosen(string settingsFile)
    {
        var text = SharedFile.ReadText(settingsFile);
        if (text is null || JsonFile.Parse(text) is not { } settings) return null;
        try
        {
            return settings[SettingKey]?.GetValue<string>() is { Length: > 0 } path ? path : null;
        }
        catch (Exception e) when (e is InvalidOperationException or FormatException)
        {
            return null;
        }
    }

    /// <summary>
    /// The calls folder of this run: SOZVON_CALLS_DIR when it is set (the contract's variable wins, as for every other
    /// folder), then the choice, then the default.
    /// </summary>
    public static string Current(string settingsFile, string defaultFolder, string? variable) =>
        !string.IsNullOrWhiteSpace(variable) ? variable : Chosen(settingsFile) ?? defaultFolder;

    /// <summary>
    /// Keeps <paramref name="folder"/> in settings.json beside the values already there; the default folder or null
    /// removes the key, as the Mac removes callsDir.
    /// </summary>
    public static void Choose(string settingsFile, string? folder, string defaultFolder)
    {
        var settings = JsonFile.Read(settingsFile) ?? [];
        if (folder is null || SamePath(folder, defaultFolder)) settings.Remove(SettingKey);
        else settings[SettingKey] = Path.GetFullPath(folder);
        Directory.CreateDirectory(Path.GetDirectoryName(settingsFile)!);
        JsonFile.WriteAtomic(settingsFile, settings);
    }

    public static CallsFolderProblem? Problem(string current, string chosen, string data)
    {
        var o = Normalize(current);
        var n = Normalize(chosen);
        var d = Normalize(data);
        if (Equal(n, o)) return CallsFolderProblem.Same;
        if (Equal(n, d) || IsUnder(n, d)) return CallsFolderProblem.EngineData;
        if (IsUnder(n, o)) return CallsFolderProblem.Inside;
        if (IsUnder(o, n)) return CallsFolderProblem.Contains;
        return null;
    }

    public static bool SamePath(string a, string b) => Equal(Normalize(a), Normalize(b));

    /// <summary>Call folders in <paramref name="root"/>: folders with a call.json or a recording. Other files and folders are not ours.</summary>
    public static IReadOnlyList<string> Calls(string root)
    {
        if (!Directory.Exists(root)) return [];
        return Directory.EnumerateDirectories(root)
            .Where(dir => !Path.GetFileName(dir).StartsWith('.'))
            .Where(dir => File.Exists(Path.Combine(dir, CallFile.Name)) || Directory.EnumerateFiles(dir, "*.m4a").Any())
            .Order(StringComparer.Ordinal)
            .ToList();
    }

    /// <summary>
    /// A recording or a run of the engine in the files: a call spooling its recording, being transcribed or waiting in
    /// the queue. For a process that cannot ask the recorder, such as the setup wizard.
    /// </summary>
    public static bool HasWorkInProgress(string root)
    {
        foreach (var dir in Calls(root))
        {
            if (Directory.Exists(Path.Combine(dir, RecordingFolder))) return true;
            if (!CallFile.Exists(dir)) continue;
            var call = CallFile.Read(dir);
            if (call.Text("status") == CallStatus.Processing.Key() || CallFile.QueuedAt(call) is not null) return true;
        }
        return false;
    }

    /// <summary>Both folders on one drive: a rename moves a call at once and cannot leave half a copy.</summary>
    public static bool OnSameVolume(string a, string b)
    {
        var x = Volume(a);
        var y = Volume(b);
        return x is not null && y is not null && string.Equals(x, y, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Moves every call folder from <paramref name="current"/> into <paramref name="chosen"/> (created if missing) and
    /// returns how many moved. <paramref name="trash"/> takes an original once its copy checked out (another drive only);
    /// <paramref name="progress"/> gets (done, total). <paramref name="copy"/> is for tests.
    /// </summary>
    /// <exception cref="CallsFolderMoveException">A name is taken (nothing moved) or a copy did not match (that original stays).</exception>
    public static int Move(string current, string chosen, Action<string> trash, Action<int, int> progress, bool? sameVolume = null,
        Action<string, string>? copy = null)
    {
        var items = Calls(current);
        var taken = items.Select(dir => Path.GetFileName(dir)!).Where(name => Directory.Exists(Path.Combine(chosen, name)) || File.Exists(Path.Combine(chosen, name))).ToList();
        if (taken.Count > 0) throw new CallsFolderMoveException(taken);
        Directory.CreateDirectory(chosen);
        var rename = sameVolume ?? OnSameVolume(current, chosen);
        copy ??= CopyFolder;
        progress(0, items.Count);
        for (var i = 0; i < items.Count; i++)
        {
            var source = items[i];
            var target = Path.Combine(chosen, Path.GetFileName(source));
            if (!rename || !TryRename(source, target))
            {
                CopyChecked(source, target, copy);
                trash(source);
            }
            progress(i + 1, items.Count);
        }
        return items.Count;
    }

    /// <summary>A folder with everything in it; the files keep their times.</summary>
    public static void CopyFolder(string source, string target)
    {
        Directory.CreateDirectory(target);
        foreach (var file in Directory.EnumerateFiles(source))
        {
            File.Copy(file, Path.Combine(target, Path.GetFileName(file)));
        }
        foreach (var folder in Directory.EnumerateDirectories(source))
        {
            CopyFolder(folder, Path.Combine(target, Path.GetFileName(folder)));
        }
    }

    /// <summary>A rename; false when the folders are on different drives after all (a junction, a mounted folder).</summary>
    private static bool TryRename(string source, string target)
    {
        try
        {
            Directory.Move(source, target);
            return true;
        }
        catch (IOException e) when ((e.HResult & 0xFFFF) == ErrorNotSameDevice || !Path.GetPathRoot(source)!.Equals(Path.GetPathRoot(target), StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }
    }

    private static void CopyChecked(string source, string target, Action<string, string> copy)
    {
        try
        {
            copy(source, target);
            if (Footprint(source).SequenceEqual(Footprint(target))) return;
        }
        catch (IOException) when (Directory.Exists(target))
        {
            DropCopy(target);
            throw;
        }
        DropCopy(target);
        throw new CallsFolderMoveException(Path.GetFileName(source));
    }

    private static void DropCopy(string target)
    {
        try
        {
            Directory.Delete(target, recursive: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // The original is still in place; a half copy left behind is only clutter.
        }
    }

    /// <summary>Relative path, size and SHA-256 of every file under <paramref name="dir"/>, in order: equal for an exact copy.</summary>
    private static List<(string Path, long Size, string Hash)> Footprint(string dir) =>
        Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories)
            .Select(file =>
            {
                using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                return (Path.GetRelativePath(dir, file), stream.Length, Convert.ToHexString(SHA256.HashData(stream)));
            })
            .OrderBy(entry => entry.Item1, StringComparer.OrdinalIgnoreCase)
            .ToList();

    /// <summary>The volume of the path, through the nearest folder that exists.</summary>
    private static string? Volume(string path)
    {
        var folder = Path.GetFullPath(path);
        while (!Directory.Exists(folder) && Path.GetDirectoryName(folder) is { } parent) folder = parent;
        var buffer = new char[1024];
        if (Directory.Exists(folder) && GetVolumePathName(folder, buffer, buffer.Length))
        {
            return new string(buffer, 0, Array.IndexOf(buffer, '\0'));
        }
        return Path.GetPathRoot(folder);
    }

    private static string Normalize(string path)
    {
        var full = Path.GetFullPath(path);
        try
        {
            if (Directory.Exists(full) && new DirectoryInfo(full).ResolveLinkTarget(returnFinalTarget: true) is { } target) full = target.FullName;
        }
        catch (IOException)
        {
            // An unreadable link is compared as written.
        }
        return Path.TrimEndingDirectorySeparator(full);
    }

    private static bool Equal(string a, string b) => string.Equals(a, b, StringComparison.OrdinalIgnoreCase);

    private static bool IsUnder(string path, string folder) =>
        path.StartsWith(Path.TrimEndingDirectorySeparator(folder) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetVolumePathName(string fileName, [Out] char[] volumePathName, int bufferLength);
}
