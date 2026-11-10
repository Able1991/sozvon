using Sozvon.Core.Foundation;
using Sozvon.Core.Server;

namespace Sozvon.Core.Calls;

/// <summary>A call put in the Recycle Bin during this run; Ctrl+Z brings it back to <see cref="Folder"/>.</summary>
public sealed record TrashedCall(string Id, string Folder);

/// <summary>
/// Calls go to the Recycle Bin as the Mac's go to the Trash: no confirmation, and Ctrl+Z puts the last one back while
/// the app runs. The own server's lists follow (<see cref="ServerLists"/>): a trashed call is deleted there on the
/// next sync; a call brought back is kept there, or brought back there too when the sync already deleted it.
/// </summary>
/// <param name="retryFor">How long a refused move is tried again (a file still open for a moment); tests pass zero.</param>
public sealed class CallTrash(string dataDir, IRecycler recycler, Func<bool> hasServer, Func<DateTimeOffset>? now = null, TimeSpan? retryFor = null)
{
    private static readonly TimeSpan RetryPoll = TimeSpan.FromMilliseconds(100);
    private readonly Stack<TrashedCall> _trashed = new();
    private readonly Func<DateTimeOffset> _now = now ?? (() => DateTimeOffset.UtcNow);
    private readonly TimeSpan _retryFor = retryFor ?? TimeSpan.FromSeconds(3);

    /// <summary>The call Ctrl+Z would bring back, or null.</summary>
    public TrashedCall? Last => _trashed.TryPeek(out var call) ? call : null;

    public bool CanUndo => _trashed.Count > 0;

    /// <summary>
    /// The call's folder to the Recycle Bin. Null, or why the own server will keep its copy (the folder is in the Bin
    /// all the same).
    /// </summary>
    /// <exception cref="IOException">The folder stayed: in use, gone already or refused.</exception>
    /// <exception cref="UnauthorizedAccessException">The folder stayed.</exception>
    public Exception? Trash(string id, string folder)
    {
        Recycle(folder);
        _trashed.Push(new TrashedCall(id, folder));
        if (!hasServer())
        {
            return null;
        }
        try
        {
            ServerLists.Add(Path.Combine(dataDir, ServerLists.DeletedFile), id, _now());
            return null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return e;
        }
    }

    /// <summary>
    /// The last trashed call back to its folder, with null, or with why the server may still delete its copy (the
    /// call is back all the same). A folder already back, restored in File Explorer, is only noted.
    /// </summary>
    /// <exception cref="InvalidOperationException">Nothing to undo.</exception>
    /// <exception cref="IOException">It did not come back: gone from the Bin, or something is in its way. It is forgotten.</exception>
    public (TrashedCall Call, Exception? ServerProblem) Undo()
    {
        var call = _trashed.Count > 0 ? _trashed.Pop() : throw new InvalidOperationException("nothing to undo");
        if (!Directory.Exists(call.Folder))
        {
            recycler.Restore(call.Folder);
        }
        return (call, KeepOnServer(call.Id));
    }

    /// <summary>
    /// The player that just let the call's audio go releases the files a moment later, on Media Foundation's own
    /// threads, and the shell refuses a folder with an open file: so a refusal is tried again for a few seconds.
    /// </summary>
    private void Recycle(string folder)
    {
        var deadline = DateTime.UtcNow + _retryFor;
        while (true)
        {
            try
            {
                recycler.Recycle(folder);
                return;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException && e is not FileNotFoundException && DateTime.UtcNow < deadline)
            {
                Thread.Sleep(RetryPoll);
            }
        }
    }

    /// <summary>
    /// Back from the Bin: the server must not delete it, and if the sync already did, it goes back there. Without a
    /// server only the old note is withdrawn.
    /// </summary>
    private Exception? KeepOnServer(string id)
    {
        try
        {
            ServerLists.Remove(Path.Combine(dataDir, ServerLists.DeletedFile), id);
            if (hasServer())
            {
                ServerLists.Add(Path.Combine(dataDir, ServerLists.RestoreFile), id, _now());
            }
            return null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return e;
        }
    }
}
