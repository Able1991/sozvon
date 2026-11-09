using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Sozvon.Core.Engine;

/// <summary>
/// The app's Job for one engine run: below normal priority, and the OS kills every process in it when the last handle
/// closes, so the engine and its workers die with the app however it dies. The handle is not inheritable.
/// </summary>
internal sealed class JobObject : IDisposable
{
    private readonly SafeJobHandle _handle;

    internal JobObject()
    {
        _handle = Native.CreateJobObjectW(0, null);
        if (_handle.IsInvalid) throw new Win32Exception(Marshal.GetLastPInvokeError());
        var limits = new Native.JobExtendedLimits
        {
            Basic = new Native.JobBasicLimits
            {
                LimitFlags = Native.JobObjectLimitKillOnJobClose | Native.JobObjectLimitPriorityClass,
                PriorityClass = Native.BelowNormalPriorityClass,
            },
        };
        if (!Native.SetInformationJobObject(_handle, Native.JobObjectExtendedLimitInformation, ref limits, Marshal.SizeOf(limits)))
        {
            var error = Marshal.GetLastPInvokeError();
            _handle.Dispose();
            throw new Win32Exception(error);
        }
    }

    internal void Assign(nint process)
    {
        if (!Native.AssignProcessToJobObject(_handle, process)) throw new Win32Exception(Marshal.GetLastPInvokeError());
    }

    internal void Terminate(uint exitCode) => Native.TerminateJobObject(_handle, exitCode);

    internal int ActiveProcesses =>
        Native.QueryInformationJobObject(_handle, Native.JobObjectBasicAccountingInformation, out var info, Marshal.SizeOf<Native.JobBasicAccounting>(), 0)
            ? (int)info.ActiveProcesses
            : 0;

    /// <summary>Terminating is asynchronous: waits until no process of the Job is left, so its files are closed.</summary>
    internal async Task WaitUntilEmptyAsync(TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (ActiveProcesses > 0 && DateTime.UtcNow < deadline) await Task.Delay(20);
    }

    public void Dispose() => _handle.Dispose();
}
