using System.Runtime.InteropServices;
using Sozvon.App.Capsule;

namespace Sozvon.App.Shell;

/// <summary>
/// A system-wide shortcut through Win32 RegisterHotKey: it works whatever program is in front and needs no keyboard
/// hook. The press arrives as WM_HOTKEY at the window given, on its thread.
/// </summary>
public sealed partial class HotKey : IDisposable
{
    private const uint MOD_ALT = 0x0001, MOD_CONTROL = 0x0002, MOD_NOREPEAT = 0x4000;
    private const int Id = 1;

    private readonly nint _hwnd;
    private readonly uint _modifiers;
    private readonly uint _key;

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool RegisterHotKey(nint hwnd, int id, uint modifiers, uint key);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool UnregisterHotKey(nint hwnd, int id);

    private HotKey(nint hwnd, uint modifiers, uint key, Action pressed)
    {
        _hwnd = hwnd;
        _modifiers = modifiers;
        _key = key;
        NativeWindow.OnHotKey(hwnd, id =>
        {
            if (id == Id)
            {
                pressed();
            }
        });
    }

    /// <summary>Ctrl+Alt+I, "important": marks the moment, as ⌃⌥I does on the Mac.</summary>
    public static HotKey Important(nint hwnd, Action pressed) => new(hwnd, MOD_CONTROL | MOD_ALT, 'I', pressed);

    /// <summary>The keys are ours until <see cref="Unregister"/>.</summary>
    public bool IsRegistered { get; private set; }

    /// <summary>Asks Windows for the keys. False when another program holds them: a press would reach that program, not us.</summary>
    public bool Register()
    {
        if (!IsRegistered)
        {
            IsRegistered = RegisterHotKey(_hwnd, Id, _modifiers | MOD_NOREPEAT, _key);
        }
        return IsRegistered;
    }

    public void Unregister()
    {
        if (IsRegistered)
        {
            UnregisterHotKey(_hwnd, Id);
            IsRegistered = false;
        }
    }

    public void Dispose() => Unregister();
}
