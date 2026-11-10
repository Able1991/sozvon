using System.Runtime.InteropServices;
using System.Text;

namespace Sozvon.Audio.Capture;

/// <summary>Names and parents of the running processes in one snapshot, and the path of one of them.</summary>
internal static class ProcessTable
{
    private const uint SnapProcess = 0x2;
    private const uint QueryLimitedInformation = 0x1000;
    private static readonly IntPtr InvalidHandle = new(-1);

    public readonly record struct Entry(string Name, int ParentId);

    public static Dictionary<int, Entry> Snapshot()
    {
        var table = new Dictionary<int, Entry>();
        IntPtr snapshot = CreateToolhelp32Snapshot(SnapProcess, 0);
        if (snapshot == InvalidHandle) return table;
        try
        {
            var entry = new ProcessEntry { Size = (uint)Marshal.SizeOf<ProcessEntry>() };
            for (bool more = Process32FirstW(snapshot, ref entry); more; more = Process32NextW(snapshot, ref entry))
            {
                table[(int)entry.ProcessId] = new Entry(entry.ExeFile, (int)entry.ParentProcessId);
            }
        }
        finally
        {
            CloseHandle(snapshot);
        }
        return table;
    }

    /// <summary>The executable's full path, or null for a process this user may not query.</summary>
    public static string? ImagePath(int pid)
    {
        IntPtr process = OpenProcess(QueryLimitedInformation, false, (uint)pid);
        if (process == IntPtr.Zero) return null;
        try
        {
            var path = new StringBuilder(1024);
            int size = path.Capacity;
            return QueryFullProcessImageNameW(process, 0, path, ref size) ? path.ToString(0, size) : null;
        }
        finally
        {
            CloseHandle(process);
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ProcessEntry
    {
        public uint Size;
        public uint Usage;
        public uint ProcessId;
        public IntPtr DefaultHeapId;
        public uint ModuleId;
        public uint Threads;
        public uint ParentProcessId;
        public int PriorityClassBase;
        public uint Flags;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string ExeFile;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool Process32FirstW(IntPtr snapshot, ref ProcessEntry entry);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool Process32NextW(IntPtr snapshot, ref ProcessEntry entry);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inherit, uint processId);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool QueryFullProcessImageNameW(IntPtr process, uint flags, StringBuilder path, ref int size);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);
}
