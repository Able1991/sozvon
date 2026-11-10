using System.Runtime.InteropServices;

namespace Sozvon.App.Capsule;

/// <summary>Win32 settings WinUI 3 has no API for: a window that never takes focus and stays out of Alt+Tab.</summary>
internal static partial class NativeWindow
{
    private const int GWL_EXSTYLE = -20;
    private const long WS_EX_TOOLWINDOW = 0x00000080;
    private const long WS_EX_NOACTIVATE = 0x08000000;
    private const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
    private const int DWMWCP_DONOTROUND = 1;
    private const int DWMWA_BORDER_COLOR = 34;
    private const int DWMWA_COLOR_NONE = unchecked((int)0xFFFFFFFE);
    private const uint SWP_NOMOVE = 0x2, SWP_NOSIZE = 0x1, SWP_NOZORDER = 0x4, SWP_NOACTIVATE = 0x10, SWP_FRAMECHANGED = 0x20;
    private const uint WM_MOUSEACTIVATE = 0x0021;
    private const nint MA_NOACTIVATE = 3;
    private const nuint SubclassId = 1;

    public struct Point
    {
        public int X;
        public int Y;
    }

    private delegate nint SubclassProc(nint hwnd, uint message, nint wParam, nint lParam, nuint id, nuint data);

    // Held for the life of the process: the window keeps calling it.
    private static readonly SubclassProc RefuseActivation = OnSubclassMessage;

    [LibraryImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    private static partial nint GetWindowLongPtr(nint hwnd, int index);

    [LibraryImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    private static partial nint SetWindowLongPtr(nint hwnd, int index, nint value);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetWindowPos(nint hwnd, nint after, int x, int y, int cx, int cy, uint flags);

    [LibraryImport("user32.dll")]
    public static partial uint GetDpiForWindow(nint hwnd);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetCursorPos(out Point point);

    [LibraryImport("dwmapi.dll")]
    private static partial int DwmSetWindowAttribute(nint hwnd, int attribute, ref int value, int size);

    [DllImport("comctl32.dll")]
    private static extern bool SetWindowSubclass(nint hwnd, SubclassProc proc, nuint id, nuint data);

    [DllImport("comctl32.dll")]
    private static extern nint DefSubclassProc(nint hwnd, uint message, nint wParam, nint lParam);

    public static void MakeNonActivating(nint hwnd)
    {
        var style = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
        SetWindowLongPtr(hwnd, GWL_EXSTYLE, style | (nint)(WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW));
        SetWindowPos(hwnd, 0, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
    }

    /// <summary>A click on the window must not take the focus from the app the user is typing in.</summary>
    public static void RefuseActivationOnClick(nint hwnd) => SetWindowSubclass(hwnd, RefuseActivation, SubclassId, 0);

    private static nint OnSubclassMessage(nint hwnd, uint message, nint wParam, nint lParam, nuint id, nuint data) =>
        message == WM_MOUSEACTIVATE ? MA_NOACTIVATE : DefSubclassProc(hwnd, message, wParam, lParam);

    public static void MoveWithoutActivating(nint hwnd, int x, int y) =>
        SetWindowPos(hwnd, 0, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);

    public static Point CursorPosition()
    {
        GetCursorPos(out var point);
        return point;
    }

    /// <summary>The window draws its own shape: no system rounding and no system border around the transparent area.</summary>
    public static void RemoveFrame(nint hwnd)
    {
        var preference = DWMWCP_DONOTROUND;
        DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref preference, sizeof(int));
        var none = DWMWA_COLOR_NONE;
        DwmSetWindowAttribute(hwnd, DWMWA_BORDER_COLOR, ref none, sizeof(int));
    }
}
