using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Sozvon.Core.Engine;

/// <summary>The Win32 calls behind process start and Job Objects.</summary>
internal static class Native
{
    internal const uint ExtendedStartupInfoPresent = 0x00080000;
    internal const uint CreateUnicodeEnvironment = 0x00000400;
    internal const uint CreateSuspended = 0x00000004;
    internal const uint CreateNoWindow = 0x08000000;
    internal const uint BelowNormalPriorityClass = 0x00004000;
    internal const int StartfUseStdHandles = 0x00000100;
    internal const nint ProcThreadAttributeHandleList = 0x00020002;

    internal const int JobObjectBasicAccountingInformation = 1;
    internal const int JobObjectExtendedLimitInformation = 9;
    internal const uint JobObjectLimitPriorityClass = 0x00000020;
    internal const uint JobObjectLimitKillOnJobClose = 0x00002000;

    [StructLayout(LayoutKind.Sequential)]
    internal struct StartupInfo
    {
        internal int Size;
        internal nint Reserved, Desktop, Title;
        internal int X, Y, XSize, YSize, XCountChars, YCountChars, FillAttribute, Flags;
        internal short ShowWindow, Reserved2Size;
        internal nint Reserved2, StdInput, StdOutput, StdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct StartupInfoEx
    {
        internal StartupInfo Info;
        internal nint AttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct ProcessInformation
    {
        internal nint Process, Thread;
        internal int ProcessId, ThreadId;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct JobBasicLimits
    {
        internal long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        internal uint LimitFlags;
        internal nuint MinimumWorkingSetSize, MaximumWorkingSetSize;
        internal uint ActiveProcessLimit;
        internal nuint Affinity;
        internal uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct IoCounters
    {
        internal ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct JobExtendedLimits
    {
        internal JobBasicLimits Basic;
        internal IoCounters Io;
        internal nuint ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct JobBasicAccounting
    {
        internal long TotalUserTime, TotalKernelTime, ThisPeriodUserTime, ThisPeriodKernelTime;
        internal uint TotalPageFaults, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses;
    }

    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
    internal static extern bool CreateProcessW(string applicationName, [In, Out] char[] commandLine, nint processAttributes,
        nint threadAttributes, bool inheritHandles, uint creationFlags, [In] char[] environment, string currentDirectory,
        ref StartupInfoEx startupInfo, out ProcessInformation processInformation);

    [DllImport("kernel32", SetLastError = true)]
    internal static extern bool InitializeProcThreadAttributeList(nint list, int count, int flags, ref nint size);

    [DllImport("kernel32", SetLastError = true)]
    internal static extern bool UpdateProcThreadAttribute(nint list, uint flags, nint attribute, nint value, nint size, nint previous, nint returnSize);

    [DllImport("kernel32")]
    internal static extern void DeleteProcThreadAttributeList(nint list);

    [DllImport("kernel32", SetLastError = true)]
    internal static extern uint ResumeThread(nint thread);

    [DllImport("kernel32", SetLastError = true)]
    internal static extern bool TerminateProcess(nint process, uint exitCode);

    [DllImport("kernel32", SetLastError = true)]
    internal static extern bool CloseHandle(nint handle);

    [DllImport("kernel32", SetLastError = true)]
    internal static extern bool GetExitCodeProcess(SafeProcessHandle process, out uint exitCode);

    [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Unicode)]
    internal static extern SafeJobHandle CreateJobObjectW(nint attributes, string? name);

    [DllImport("kernel32", SetLastError = true)]
    internal static extern bool SetInformationJobObject(SafeJobHandle job, int infoClass, ref JobExtendedLimits info, int size);

    [DllImport("kernel32", SetLastError = true)]
    internal static extern bool QueryInformationJobObject(SafeJobHandle job, int infoClass, out JobBasicAccounting info, int size, nint returned);

    [DllImport("kernel32", SetLastError = true)]
    internal static extern bool AssignProcessToJobObject(SafeJobHandle job, nint process);

    [DllImport("kernel32", SetLastError = true)]
    internal static extern bool TerminateJobObject(SafeJobHandle job, uint exitCode);
}

internal sealed class SafeJobHandle() : SafeHandleZeroOrMinusOneIsInvalid(ownsHandle: true)
{
    protected override bool ReleaseHandle() => Native.CloseHandle(handle);
}
