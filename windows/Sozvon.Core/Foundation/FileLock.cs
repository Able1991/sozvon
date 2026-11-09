using System.Diagnostics;

namespace Sozvon.Core.Foundation;

/// <summary>The lock could not be taken in time: another process has held it too long.</summary>
public sealed class FileLockTimeoutException(string path) : IOException($"timed out waiting for the lock {path}");

/// <summary>
/// The engine's lock convention: byte 0 of the sibling file <c>&lt;file&gt;.lock</c>, exclusive. The OS releases it
/// when the handle closes or the process dies, however it dies.
/// </summary>
public static class FileLock
{
    public static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan Poll = TimeSpan.FromMilliseconds(50);

    public static string LockPath(string path) => path + ".lock";

    public static T With<T>(string path, Func<T> body, TimeSpan? timeout = null)
    {
        var lockPath = LockPath(path);
        using var stream = new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite,
                                          FileShare.ReadWrite | FileShare.Delete);
        Acquire(stream, lockPath, timeout ?? DefaultTimeout);
        try
        {
            return body();
        }
        finally
        {
            stream.Unlock(0, 1);
        }
    }

    private static void Acquire(FileStream stream, string lockPath, TimeSpan timeout)
    {
        var waited = Stopwatch.StartNew();
        while (true)
        {
            try
            {
                stream.Lock(0, 1);
                return;
            }
            catch (IOException e) when (BusyRetry.IsLockViolation(e))
            {
                if (waited.Elapsed >= timeout) throw new FileLockTimeoutException(lockPath);
                Thread.Sleep(Poll);
            }
        }
    }
}
