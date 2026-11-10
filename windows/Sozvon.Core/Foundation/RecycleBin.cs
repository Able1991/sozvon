using System.Runtime.InteropServices;

namespace Sozvon.Core.Foundation;

/// <summary>Takes a folder away so that it can come back: the Recycle Bin, or a stand-in for tests.</summary>
public interface IRecycler
{
    /// <exception cref="IOException">It is still there: in use, gone already or refused.</exception>
    void Recycle(string path);

    /// <summary>Puts back what <see cref="Recycle"/> took, to the same path.</summary>
    /// <exception cref="IOException">It did not come back: gone from the bin, or something is in the way.</exception>
    void Restore(string originalPath);
}

/// <summary>The real Recycle Bin, through the shell.</summary>
public sealed class ShellRecycler : IRecycler
{
    public void Recycle(string path) => RecycleBin.Move(path);

    public void Restore(string originalPath) => RecycleBin.Restore(originalPath);
}

/// <summary>
/// Folders and files go to the Recycle Bin the way File Explorer's Delete sends them: through the shell's own file
/// operation, so Explorer's Undo knows about them too, without a confirmation. They come back with the Bin's own
/// "Restore", found there by the path they had.
/// </summary>
public static class RecycleBin
{
    private const uint FOF_NOCONFIRMATION = 0x10;
    private const uint FOF_ALLOWUNDO = 0x40;
    private const uint FOF_NOERRORUI = 0x400;

    /// <summary>Windows asks before it deletes for good what the Recycle Bin can't take (a network folder, no room).</summary>
    private const uint FOF_WANTNUKEWARNING = 0x4000;

    /// <summary>
    /// No FOF_SILENT and no FOF_NO_UI: those would also mute whatever the shell plays for the operation. The progress
    /// window the shell may show is the same one Explorer shows, and only for an operation that takes long.
    /// </summary>
    private const uint MoveFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_WANTNUKEWARNING;

    private const uint SIGDN_NORMALDISPLAY = 0;
    private const uint CMF_NORMAL = 0;
    private const uint CMIC_MASK_FLAG_NO_UI = 0x400;
    private const uint GCS_VERBW = 4;
    private const int SW_SHOWNORMAL = 1;

    private static readonly Guid RecycleBinFolder = new("B7534046-3ECB-4C18-BE4E-64CD4CB7D6AC");
    private static readonly Guid BHID_EnumItems = new("94f60519-2850-4924-aa5a-d15e84868039");
    private static readonly Guid BHID_SFUIObject = new("3981e225-f559-11d3-8e3a-00c04f6837d5");
    private static readonly Guid IID_IShellItem = new("43826d1e-e718-42ee-bc55-a1e261c37bfe");
    private static readonly Guid IID_IEnumShellItems = new("70629033-e363-4a28-a567-0db78006e6d7");
    private static readonly Guid IID_IContextMenu = new("000214e4-0000-0000-c000-000000000046");

    /// <summary>System.Recycle.DeletedFrom: the folder the item was in.</summary>
    private static PROPERTYKEY DeletedFrom = new() { fmtid = new Guid("9B174B33-40FF-11D2-A27E-00C04FC30871"), pid = 2 };

    /// <summary>System.Recycle.DateDeleted.</summary>
    private static PROPERTYKEY DateDeleted = new() { fmtid = new Guid("9B174B33-40FF-11D2-A27E-00C04FC30871"), pid = 3 };

    /// <summary>A call folder or a single file, such as a project's profile.</summary>
    /// <exception cref="IOException">It is still there: in use, gone already or refused.</exception>
    public static void Move(string path)
    {
        var full = Path.GetFullPath(path);
        if (!Directory.Exists(full) && !File.Exists(full))
        {
            throw new FileNotFoundException(full);
        }
        Sta(() =>
        {
            var operation = (IFileOperation)new FileOperation();
            try
            {
                operation.SetOperationFlags(MoveFlags);
                operation.DeleteItem(ItemAt(full), IntPtr.Zero);
                operation.PerformOperations();
                if (operation.GetAnyOperationsAborted())
                {
                    // The shell gave up without a word (no error UI): a file in use, most often.
                    throw new IOException(full);
                }
            }
            catch (COMException e)
            {
                throw new IOException(e.Message, e) { HResult = e.HResult };
            }
            finally
            {
                Marshal.FinalReleaseComObject(operation);
            }
        });
        if (Directory.Exists(full) || File.Exists(full))
        {
            throw new IOException(full);
        }
    }

    /// <summary>Whether the Recycle Bin holds something that was at this path.</summary>
    public static bool Contains(string originalPath) => Sta(() => Find(Path.GetFullPath(originalPath)) is not null);

    /// <summary>
    /// The Bin's own Restore for what was at this path (the one deleted last, if several): back to where it was.
    /// </summary>
    /// <exception cref="FileNotFoundException">Nothing in the Bin was at this path.</exception>
    /// <exception cref="IOException">It did not come back: something is in the way.</exception>
    public static void Restore(string originalPath)
    {
        var full = Path.GetFullPath(originalPath);
        if (Directory.Exists(full) || File.Exists(full))
        {
            throw new IOException("already there: " + full);
        }
        Sta(() =>
        {
            var item = Find(full) ?? throw new FileNotFoundException("not in the Recycle Bin: " + full);
            try
            {
                Undelete(item);
            }
            catch (COMException e)
            {
                throw new IOException(e.Message, e);
            }
            finally
            {
                Marshal.FinalReleaseComObject(item);
            }
        });
        // The shell moves it back on its own thread; it is there within a moment.
        for (var waited = 0; waited < 100 && !Directory.Exists(full) && !File.Exists(full); waited++)
        {
            Thread.Sleep(50);
        }
        if (!Directory.Exists(full) && !File.Exists(full))
        {
            throw new IOException("did not come back: " + full);
        }
    }

    /// <summary>What the Bin holds, as (the folder it was in, its name); for tests and diagnostics.</summary>
    internal static List<(string From, string Name)> Entries() => Sta(() =>
    {
        var entries = new List<(string, string)>();
        SHGetKnownFolderItem(RecycleBinFolder, 0, IntPtr.Zero, IID_IShellItem, out var bin);
        var enumerator = (IEnumShellItems)bin.BindToHandler(IntPtr.Zero, BHID_EnumItems, IID_IEnumShellItems);
        while (enumerator.Next(1, out var item, out var fetched) == 0 && fetched == 1)
        {
            var shellItem = (IShellItem2)item;
            string from;
            try { from = shellItem.GetString(DeletedFrom); } catch (COMException e) { from = "<" + e.Message + ">"; }
            entries.Add((from, shellItem.GetDisplayName(SIGDN_NORMALDISPLAY)));
            Marshal.FinalReleaseComObject(item);
        }
        Marshal.FinalReleaseComObject(enumerator);
        Marshal.FinalReleaseComObject(bin);
        return entries;
    });

    /// <summary>The Bin's item that was at this path, the one deleted last when there are several; caller releases.</summary>
    private static IShellItem? Find(string full)
    {
        var folder = Path.TrimEndingDirectorySeparator(Path.GetDirectoryName(full) ?? "");
        var name = Path.GetFileName(full);
        SHGetKnownFolderItem(RecycleBinFolder, 0, IntPtr.Zero, IID_IShellItem, out var bin);
        IShellItem? best = null;
        var bestTime = 0L;
        try
        {
            var enumerator = (IEnumShellItems)bin.BindToHandler(IntPtr.Zero, BHID_EnumItems, IID_IEnumShellItems);
            try
            {
                while (enumerator.Next(1, out var item, out var fetched) == 0 && fetched == 1)
                {
                    var keep = false;
                    try
                    {
                        if (IsAt((IShellItem2)item, full, folder, name, out var deletedAt) && deletedAt >= bestTime)
                        {
                            if (best is not null) Marshal.FinalReleaseComObject(best);
                            best = (IShellItem)item;
                            bestTime = deletedAt;
                            keep = true;
                        }
                    }
                    finally
                    {
                        if (!keep) Marshal.FinalReleaseComObject(item);
                    }
                }
            }
            finally
            {
                Marshal.FinalReleaseComObject(enumerator);
            }
        }
        finally
        {
            Marshal.FinalReleaseComObject(bin);
        }
        return best;
    }

    /// <summary>
    /// The Bin names an item by the full path it had (Windows 11), or by its old name alone: either, in the right folder.
    /// </summary>
    private static bool IsAt(IShellItem2 item, string full, string folder, string name, out long deletedAt)
    {
        deletedAt = 0;
        string from;
        try
        {
            from = item.GetString(DeletedFrom);
        }
        catch (COMException)
        {
            return false; // not a recycled file: the Bin shows nothing else, but be safe
        }
        var shown = item.GetDisplayName(SIGDN_NORMALDISPLAY);
        if (!string.Equals(Path.TrimEndingDirectorySeparator(from), folder, StringComparison.OrdinalIgnoreCase)
            || !(string.Equals(shown, full, StringComparison.OrdinalIgnoreCase) || string.Equals(shown, name, StringComparison.OrdinalIgnoreCase)))
        {
            return false;
        }
        try
        {
            item.GetFileTime(DateDeleted, out var time);
            deletedAt = ((long)time.dwHighDateTime << 32) | (uint)time.dwLowDateTime;
        }
        catch (COMException)
        {
            // no date: still ours
        }
        return true;
    }

    /// <summary>The item's "Restore" (the verb <c>undelete</c>), found among its menu's commands, not guessed.</summary>
    private static void Undelete(IShellItem item)
    {
        var menu = (IContextMenu)item.BindToHandler(IntPtr.Zero, BHID_SFUIObject, IID_IContextMenu);
        var handle = CreatePopupMenu();
        try
        {
            const uint first = 1;
            Marshal.ThrowExceptionForHR(menu.QueryContextMenu(handle, 0, first, 0x7FFF, CMF_NORMAL));
            var command = -1;
            var count = GetMenuItemCount(handle);
            for (var i = 0; i < count && command < 0; i++)
            {
                var id = GetMenuItemID(handle, i);
                if (id == uint.MaxValue || id < first) continue;
                var verb = new char[64];
                var hr = menu.GetCommandString((UIntPtr)(id - first), GCS_VERBW, IntPtr.Zero, verb, (uint)verb.Length);
                if (hr >= 0 && new string(verb).TrimEnd('\0').Equals("undelete", StringComparison.OrdinalIgnoreCase))
                {
                    command = (int)(id - first);
                }
            }
            if (command < 0)
            {
                throw new IOException("the Recycle Bin offers no Restore for it");
            }
            var info = new CMINVOKECOMMANDINFO
            {
                cbSize = (uint)Marshal.SizeOf<CMINVOKECOMMANDINFO>(),
                fMask = CMIC_MASK_FLAG_NO_UI,
                lpVerb = (IntPtr)command,
                nShow = SW_SHOWNORMAL,
            };
            menu.InvokeCommand(ref info);
        }
        finally
        {
            DestroyMenu(handle);
            Marshal.FinalReleaseComObject(menu);
        }
    }

    private static IShellItem ItemAt(string full)
    {
        SHCreateItemFromParsingName(full, IntPtr.Zero, IID_IShellItem, out var item);
        return item;
    }

    /// <summary>
    /// Shell COM wants a single-threaded apartment, and the operation pumps messages while it runs: never the UI's
    /// thread (XAML must not be re-entered from a click handler), always a thread of its own. Callers in the UI
    /// get here from a Task.
    /// </summary>
    private static T Sta<T>(Func<T> body)
    {
        T result = default!;
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try
            {
                result = body();
            }
            catch (Exception e)
            {
                failure = e;
            }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        if (failure is not null)
        {
            System.Runtime.ExceptionServices.ExceptionDispatchInfo.Throw(failure);
        }
        return result;
    }

    private static void Sta(Action body) => Sta(() =>
    {
        body();
        return true;
    });

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    private static extern void SHCreateItemFromParsingName(string path, IntPtr bindContext, in Guid riid, out IShellItem item);

    [DllImport("shell32.dll", PreserveSig = false)]
    private static extern void SHGetKnownFolderItem(in Guid folderId, uint flags, IntPtr token, in Guid riid, out IShellItem item);

    [DllImport("user32.dll")]
    private static extern IntPtr CreatePopupMenu();

    [DllImport("user32.dll")]
    private static extern bool DestroyMenu(IntPtr menu);

    [DllImport("user32.dll")]
    private static extern int GetMenuItemCount(IntPtr menu);

    [DllImport("user32.dll")]
    private static extern uint GetMenuItemID(IntPtr menu, int position);

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct PROPERTYKEY
    {
        public Guid fmtid;
        public uint pid;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FILETIME
    {
        public int dwLowDateTime;
        public int dwHighDateTime;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct CMINVOKECOMMANDINFO
    {
        public uint cbSize;
        public uint fMask;
        public IntPtr hwnd;
        public IntPtr lpVerb;
        public IntPtr lpParameters;
        public IntPtr lpDirectory;
        public int nShow;
        public uint dwHotKey;
        public IntPtr hIcon;
    }

    [ComImport, Guid("3ad05575-8857-4850-9277-11b85bdb8e09")]
    private class FileOperation;

    [ComImport, Guid("947aab5f-0a5c-4c13-b4d6-4bf7836fc9f8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFileOperation
    {
        uint Advise(IntPtr sink);
        void Unadvise(uint cookie);
        void SetOperationFlags(uint flags);
        void SetProgressMessage([MarshalAs(UnmanagedType.LPWStr)] string message);
        void SetProgressDialog(IntPtr dialog);
        void SetProperties(IntPtr properties);
        void SetOwnerWindow(IntPtr owner);
        void ApplyPropertiesToItem(IShellItem item);
        void ApplyPropertiesToItems(IntPtr items);
        void RenameItem(IShellItem item, [MarshalAs(UnmanagedType.LPWStr)] string newName, IntPtr sink);
        void RenameItems(IntPtr items, [MarshalAs(UnmanagedType.LPWStr)] string newName);
        void MoveItem(IShellItem item, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string? newName, IntPtr sink);
        void MoveItems(IntPtr items, IShellItem destination);
        void CopyItem(IShellItem item, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string? copyName, IntPtr sink);
        void CopyItems(IntPtr items, IShellItem destination);
        void DeleteItem(IShellItem item, IntPtr sink);
        void DeleteItems(IntPtr items);
        void NewItem(IShellItem destination, uint attributes, [MarshalAs(UnmanagedType.LPWStr)] string name, [MarshalAs(UnmanagedType.LPWStr)] string? template, IntPtr sink);
        void PerformOperations();
        [return: MarshalAs(UnmanagedType.Bool)]
        bool GetAnyOperationsAborted();
    }

    [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItem
    {
        [return: MarshalAs(UnmanagedType.Interface)]
        object BindToHandler(IntPtr bindContext, in Guid handlerId, in Guid riid);
        IShellItem GetParent();
        [return: MarshalAs(UnmanagedType.LPWStr)]
        string GetDisplayName(uint form);
        uint GetAttributes(uint mask);
        int Compare(IShellItem other, uint hint);
    }

    /// <summary>IShellItem with its properties; the base's methods come first in the table, so they are repeated.</summary>
    [ComImport, Guid("7e9fb0d3-919f-4307-ab2e-9b1860310c93"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItem2
    {
        [return: MarshalAs(UnmanagedType.Interface)]
        object BindToHandler(IntPtr bindContext, in Guid handlerId, in Guid riid);
        IShellItem GetParent();
        [return: MarshalAs(UnmanagedType.LPWStr)]
        string GetDisplayName(uint form);
        uint GetAttributes(uint mask);
        int Compare(IShellItem other, uint hint);
        [return: MarshalAs(UnmanagedType.Interface)]
        object GetPropertyStore(uint flags, in Guid riid);
        [return: MarshalAs(UnmanagedType.Interface)]
        object GetPropertyStoreWithCreateObject(uint flags, [MarshalAs(UnmanagedType.IUnknown)] object creator, in Guid riid);
        [return: MarshalAs(UnmanagedType.Interface)]
        object GetPropertyStoreForKeys(IntPtr keys, uint count, uint flags, in Guid riid);
        [return: MarshalAs(UnmanagedType.Interface)]
        object GetPropertyDescriptionList(in PROPERTYKEY keyType, in Guid riid);
        void Update(IntPtr bindContext);
        void GetProperty(in PROPERTYKEY key, IntPtr value);
        void GetCLSID(in PROPERTYKEY key, out Guid clsid);
        void GetFileTime(in PROPERTYKEY key, out FILETIME time);
        void GetInt32(in PROPERTYKEY key, out int value);
        [return: MarshalAs(UnmanagedType.LPWStr)]
        string GetString(in PROPERTYKEY key);
        void GetUInt32(in PROPERTYKEY key, out uint value);
        void GetUInt64(in PROPERTYKEY key, out ulong value);
        void GetBool(in PROPERTYKEY key, [MarshalAs(UnmanagedType.Bool)] out bool value);
    }

    [ComImport, Guid("70629033-e363-4a28-a567-0db78006e6d7"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IEnumShellItems
    {
        [PreserveSig]
        int Next(uint count, [MarshalAs(UnmanagedType.Interface)] out object item, out uint fetched);
        void Skip(uint count);
        void Reset();
        IEnumShellItems Clone();
    }

    [ComImport, Guid("000214e4-0000-0000-c000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IContextMenu
    {
        [PreserveSig]
        int QueryContextMenu(IntPtr menu, uint index, uint firstId, uint lastId, uint flags);
        void InvokeCommand(ref CMINVOKECOMMANDINFO info);
        [PreserveSig]
        int GetCommandString(UIntPtr command, uint type, IntPtr reserved, [Out, MarshalAs(UnmanagedType.LPArray)] char[] name, uint length);
    }
}
