using Sozvon.Core.Engine;
using Sozvon.Core.Foundation;

namespace Sozvon.Core.Calls;

/// <summary>&lt;call&gt;\.work: the engine's working files. Only a hard kill or a crash leaves them behind.</summary>
public static class WorkFiles
{
    public const string Folder = ".work";

    /// <summary>
    /// At launch: removes <c>.work</c> from every call folder except <paramref name="keeping"/> (the restored queue:
    /// its run clears the folder itself) and calls found processing.
    /// </summary>
    public static void Sweep(string root, IEnumerable<string> keeping)
    {
        var kept = keeping.Select(ProcessingJob.Key).ToHashSet();
        foreach (var dir in CallFile.Folders(root))
        {
            if (kept.Contains(ProcessingJob.Key(dir)) || !Directory.Exists(Path.Combine(dir, Folder))) continue;
            if (CallFile.Read(dir).Text("status") == CallStatus.Processing.Key()) continue;
            Remove(dir);
        }
    }

    /// <summary>Removes the working files of one call, waiting briefly for files that are still being closed.</summary>
    public static bool Remove(string dir)
    {
        var work = Path.Combine(dir, Folder);
        try
        {
            BusyRetry.Run(() =>
            {
                if (Directory.Exists(work)) Directory.Delete(work, recursive: true);
            });
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }
}
