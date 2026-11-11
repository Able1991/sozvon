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
    private const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
    private const int DWMWA_COLOR_NONE = unchecked((int)0xFFFFFFFE);
    private const uint SWP_NOMOVE = 0x2, SWP_NOSIZE = 0x1, SWP_NOZORDER = 0x4, SWP_NOACTIVATE = 0x10, SWP_FRAMECHANGED = 0x20;
    private const uint WM_MOUSEACTIVATE = 0x0021, WM_EXITSIZEMOVE = 0x0232, WM_HOTKEY = 0x0312;

    // What each subclassed window wants to know when a system move of it has ended.
    private static readonly Dictionary<nint, Action> MoveEnded = [];
    // What each subclassed window does with a system-wide shortcut registered on it, by the shortcut's id.
    private static readonly Dictionary<nint, Action<int>> HotKeyPressed = [];
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
    /// <param name="moveEnded">Called when a system move of the window (Alt+Space, Move) has ended.</param>
    public static void RefuseActivationOnClick(nint hwnd, Action moveEnded)
    {
        MoveEnded[hwnd] = moveEnded;
        SetWindowSubclass(hwnd, RefuseActivation, SubclassId, 0);
    }

    /// <summary>WM_HOTKEY for a shortcut registered on this window (RegisterHotKey) goes to <paramref name="pressed"/>.</summary>
    public static void OnHotKey(nint hwnd, Action<int> pressed)
    {
        HotKeyPressed[hwnd] = pressed;
        SetWindowSubclass(hwnd, RefuseActivation, SubclassId, 0);
    }

    private static nint OnSubclassMessage(nint hwnd, uint message, nint wParam, nint lParam, nuint id, nuint data)
    {
        switch (message)
        {
            case WM_MOUSEACTIVATE:
                return MA_NOACTIVATE;
            case WM_EXITSIZEMOVE:
                if (MoveEnded.TryGetValue(hwnd, out var moveEnded))
                {
                    moveEnded();
                }
                return DefSubclassProc(hwnd, message, wParam, lParam);
            case WM_HOTKEY:
                if (HotKeyPressed.TryGetValue(hwnd, out var pressed))
                {
                    pressed((int)wParam);
                }
                return 0;
            case WM_ERASEBKGND:
                // Black under DWM glass is clear; the class background (white in light mode) would show around the shape.
                GetClientRect(hwnd, out var client);
                FillRect(wParam, ref client, GetStockObject(BLACK_BRUSH));
                return 1;
            default:
                return DefSubclassProc(hwnd, message, wParam, lParam);
        }
    }

    private const uint WM_ERASEBKGND = 0x0014;
    private const int BLACK_BRUSH = 4;

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect
    {
        public int Left, Top, Right, Bottom;
    }

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetClientRect(nint hwnd, out Rect rect);

    [LibraryImport("user32.dll")]
    private static partial int FillRect(nint hdc, ref Rect rect, nint brush);

    [LibraryImport("gdi32.dll")]
    private static partial nint GetStockObject(int index);

    public static void MoveWithoutActivating(nint hwnd, int x, int y) =>
        SetWindowPos(hwnd, 0, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);

    public static Point CursorPosition()
    {
        GetCursorPos(out var point);
        return point;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Margins
    {
        public int Left, Right, Top, Bottom;
    }

    [LibraryImport("dwmapi.dll")]
    private static partial int DwmExtendFrameIntoClientArea(nint hwnd, ref Margins margins);

    /// <summary>
    /// Without it DWM fills the client area with the theme's black or white under the content, so the transparent
    /// pixels outside the drawn shape come out opaque. Applied once the window is on screen.
    /// </summary>
    public static void ComposeWithBackground(nint hwnd)
    {
        // In light mode DWM paints the glass with the light frame colour; the dark frame is the one that stays clear.
        // The capsule has no frame, so this changes nothing else.
        var dark = 1;
        DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref dark, sizeof(int));
        var glass = new Margins { Left = -1, Right = -1, Top = -1, Bottom = -1 };
        DwmExtendFrameIntoClientArea(hwnd, ref glass);
    }

    private const long WS_EX_LAYERED = 0x00080000, WS_EX_TRANSPARENT = 0x00000020;
    private const uint LWA_ALPHA = 0x2;

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetLayeredWindowAttributes(nint hwnd, uint colorKey, byte alpha, uint flags);

    /// <summary>Lets mouse input fall through to the window underneath; a layered window is required for it.</summary>
    public static void SetClickThrough(nint hwnd, bool through)
    {
        var style = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
        style = through ? style | (nint)WS_EX_TRANSPARENT : style & ~(nint)WS_EX_TRANSPARENT;
        SetWindowLongPtr(hwnd, GWL_EXSTYLE, style);
    }

    /// <summary>The window draws its own shape: no system rounding and no system border around the transparent area.</summary>
    public static void RemoveFrame(nint hwnd)
    {
        // Layered so that the shadow's margin can let clicks through (see SetClickThrough).
        var layered = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
        SetWindowLongPtr(hwnd, GWL_EXSTYLE, layered | (nint)WS_EX_LAYERED);
        SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA);
        var preference = DWMWCP_DONOTROUND;
        DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref preference, sizeof(int));
        var none = DWMWA_COLOR_NONE;
        DwmSetWindowAttribute(hwnd, DWMWA_BORDER_COLOR, ref none, sizeof(int));
    }
}
