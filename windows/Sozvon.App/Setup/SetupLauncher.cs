using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;

namespace Sozvon.App.Setup;

/// <summary>Opens the wizard when the app was started with --setup [--data-dir folder] [--engine folder].</summary>
public static partial class SetupLauncher
{
    private const uint MB_ICONERROR = 0x10;
    private static SetupWindow? _window;

    public static bool TryShow()
    {
        var args = Environment.GetCommandLineArgs();
        if (!args.Contains("--setup"))
        {
            return false;
        }
        var engine = ArgumentAfter(args, "--engine") ?? SetupContext.FindEngineFolder();
        if (engine is null || !File.Exists(Path.Combine(engine, "setup.ps1")))
        {
            MessageBox(0, Strings.L("Не нашёл файлы движка. Переустанови Sozvon."), "Sozvon", MB_ICONERROR);
            Application.Current.Exit();
            return true;
        }
        var data = ArgumentAfter(args, "--data-dir") ?? SetupContext.DefaultDataFolder;
        _window = new SetupWindow(new SetupContext(Path.GetFullPath(data), Path.GetFullPath(engine)));
        _window.Activate();
        return true;
    }

    private static string? ArgumentAfter(string[] args, string name)
    {
        var index = Array.IndexOf(args, name);
        return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
    }

    [LibraryImport("user32.dll", EntryPoint = "MessageBoxW", StringMarshalling = StringMarshalling.Utf16)]
    private static partial int MessageBox(nint owner, string text, string caption, uint type);
}
