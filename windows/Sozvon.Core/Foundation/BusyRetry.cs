namespace Sozvon.Core.Foundation;

/// <summary>Repeats a file operation while Windows refuses it because someone holds the file for a moment.</summary>
internal static class BusyRetry
{
    private const int ErrorAccessDenied = 5;
    private const int ErrorSharingViolation = 32;
    private const int ErrorLockViolation = 33;
    private static readonly TimeSpan Wait = TimeSpan.FromSeconds(3);
    private static readonly TimeSpan Poll = TimeSpan.FromMilliseconds(100);

    internal static void Run(Action operation)
    {
        var deadline = DateTime.UtcNow + Wait;
        while (true)
        {
            try
            {
                operation();
                return;
            }
            catch (Exception e) when (IsBusy(e) && DateTime.UtcNow < deadline)
            {
                Thread.Sleep(Poll);
            }
        }
    }

    internal static bool IsLockViolation(IOException e) => (e.HResult & 0xFFFF) == ErrorLockViolation;

    private static bool IsBusy(Exception e) => e switch
    {
        UnauthorizedAccessException => true,
        IOException io => (io.HResult & 0xFFFF) is ErrorAccessDenied or ErrorSharingViolation or ErrorLockViolation,
        _ => false,
    };
}
