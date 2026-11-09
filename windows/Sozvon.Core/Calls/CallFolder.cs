using System.ComponentModel;
using System.Globalization;
using System.Runtime.InteropServices;
using Sozvon.Core.Foundation;

namespace Sozvon.Core.Calls;

/// <summary>
/// The folder of a new recording. Two recordings in one minute never share a folder: the second id gets a suffix,
/// "2026-11-04 15-01-2". The id goes to call.json as soon as the folder exists.
/// </summary>
public static class CallFolder
{
    private const int IdLength = 16;
    private const int ErrorAlreadyExists = 183;
    private static readonly string[] Unused = [CallFile.Name, CallFile.LockName, "desktop.ini", "Thumbs.db"];

    /// <summary>"2026-11-04 15-01" in local time.</summary>
    public static string BaseId(DateTimeOffset at) =>
        at.ToLocalTime().ToString("yyyy-MM-dd HH-mm", CultureInfo.InvariantCulture);

    /// <summary>The id at the start of a folder name: a date and an optional "-N". Not a date: the first 16 characters.</summary>
    public static string IdFromName(string name)
    {
        if (name.Length < IdLength || Call.ParseId(name) is null) return TextRules.Prefix(name, IdLength);
        var end = IdLength;
        if (name.Length > IdLength + 1 && name[IdLength] == '-')
        {
            var j = IdLength + 1;
            while (j < name.Length && char.IsAsciiDigit(name[j])) j++;
            if (j > IdLength + 1 && (j == name.Length || name[j] == ' ')) end = j;
        }
        return name[..end];
    }

    /// <summary>Ids of all calls in the folder, from call.json, otherwise from the name.</summary>
    public static HashSet<string> Ids(string root) => CallFile.Folders(root).Select(CallFile.CallId).ToHashSet();

    /// <summary>Creates a folder with a new id and its call.json. An existing folder is never accepted.</summary>
    public static string Create(string root, DateTimeOffset? at = null)
    {
        Directory.CreateDirectory(root);
        var startedAt = at ?? DateTimeOffset.Now;
        var baseId = BaseId(startedAt);
        var taken = Ids(root);
        for (var n = 1; n <= 999; n++)
        {
            var id = n == 1 ? baseId : $"{baseId}-{n}";
            if (taken.Contains(id)) continue;
            var dir = Path.Combine(root, id);
            if (!CreateNew(dir)) continue;
            var written = CallFile.Update(dir, c =>
            {
                c["schema"] = CallFile.Schema;
                c["id"] = id;
                c["created_at"] = Iso8601.Seconds(startedAt);
            });
            if (written) return dir;
            DiscardIfUnused(dir);
            throw new IOException($"could not write {CallFile.Name} in {dir}");
        }
        throw new IOException($"no free call id for {baseId}");
    }

    /// <summary>Recording did not start: removes the folder if it holds nothing but call.json. Whether it was removed.</summary>
    public static bool DiscardIfUnused(string dir)
    {
        try
        {
            var items = Directory.GetFileSystemEntries(dir).Select(Path.GetFileName).ToList();
            if (!items.All(i => Unused.Contains(i, StringComparer.OrdinalIgnoreCase))) return false;
            foreach (var item in items) File.Delete(Path.Combine(dir, item!));
            Directory.Delete(dir);
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    private static bool CreateNew(string dir)
    {
        if (CreateDirectoryW(dir, IntPtr.Zero)) return true;
        var error = Marshal.GetLastPInvokeError();
        if (error == ErrorAlreadyExists) return false;
        throw new IOException($"could not create {dir}", new Win32Exception(error));
    }

    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateDirectoryW(string path, IntPtr securityAttributes);
}
