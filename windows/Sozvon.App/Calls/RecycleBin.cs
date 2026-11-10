using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;

namespace Sozvon.App.Calls;

/// <summary>Moves a folder to the Recycle Bin, as File Explorer's Delete does: no confirmation, it can be restored.</summary>
public static partial class RecycleBin
{
    private const uint FO_DELETE = 0x3;
    private const ushort FOF_SILENT = 0x4;
    private const ushort FOF_NOCONFIRMATION = 0x10;
    private const ushort FOF_ALLOWUNDO = 0x40;
    private const ushort FOF_NOERRORUI = 0x400;

    /// <summary>Windows asks before it deletes for good what the Recycle Bin can't take (a network folder, no room).</summary>
    private const ushort FOF_WANTNUKEWARNING = 0x4000;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct SHFILEOPSTRUCT
    {
        public nint hwnd;
        public uint wFunc;
        public string pFrom;
        public string? pTo;
        public ushort fFlags;
        public int fAnyOperationsAborted;
        public nint hNameMappings;
        public string? lpszProgressTitle;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SHFileOperation(ref SHFILEOPSTRUCT operation);

    /// <summary>A call folder or a single file, such as a project's profile.</summary>
    /// <exception cref="IOException">It is still there: in use, gone already or refused.</exception>
    public static void Move(string path)
    {
        var full = Path.GetFullPath(path);
        if (!Directory.Exists(full) && !File.Exists(full))
        {
            throw new FileNotFoundException(full);
        }
        var operation = new SHFILEOPSTRUCT
        {
            wFunc = FO_DELETE,
            pFrom = full + "\0\0",
            fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_SILENT | FOF_WANTNUKEWARNING,
        };
        var result = SHFileOperation(ref operation);
        if (result != 0 || operation.fAnyOperationsAborted != 0 || Directory.Exists(full) || File.Exists(full))
        {
            throw new IOException(result != 0 ? new Win32Exception(result).Message : full, result);
        }
    }
}
