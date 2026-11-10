using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace Sozvon.App.Setup;

/// <summary>
/// Opens the wizard when the app was started with --setup [--data-dir folder] [--engine folder]. Without --data-dir it
/// works on the app's own folder, SOZVON_DATA_DIR included: the app opens it with --setup alone and the wizard of a
/// test run or a second profile must not install into the user's real folder.
/// </summary>
public static partial class SetupLauncher
{
    private const string InstanceKey = "sozvon-setup";
    private const uint MB_ICONERROR = 0x10;
    private static SetupWindow? _window;

    public static bool TryShow()
    {
        var args = Environment.GetCommandLineArgs();
        if (!args.Contains("--setup"))
        {
            return false;
        }
        // Two wizards would run two installers over the same folder: the second start brings the first to the front.
        var instance = AppInstance.FindOrRegisterForKey(Shell.AppPaths.InstanceKey(InstanceKey));
        if (!instance.IsCurrent)
        {
            Task.Run(async () => await instance.RedirectActivationToAsync(AppInstance.GetCurrent().GetActivatedEventArgs())).Wait();
            // Windows lets only the process the user just started take the foreground: the first wizard's own Activate()
            // merely flashes, so this process brings it up before it leaves (as in the App SDK's single-instance sample).
            try
            {
                using var first = Process.GetProcessById((int)instance.ProcessId);
                if (first.MainWindowHandle != 0)
                {
                    SetForegroundWindow(first.MainWindowHandle);
                }
            }
            catch (Exception e) when (e is ArgumentException or InvalidOperationException)
            {
                // The first wizard closed in the meantime.
            }
            Environment.Exit(0);
        }
        instance.Activated += (_, _) => _window?.DispatcherQueue.TryEnqueue(() => _window.Activate());
        // The data folder first: the wizard's language, even the error below, is the app's setting kept there.
        var data = Path.GetFullPath(ArgumentAfter(args, "--data-dir") ?? Shell.AppPaths.DataDir);
        Strings.Initialize(data);
        var engine = ArgumentAfter(args, "--engine") ?? SetupContext.FindEngineFolder();
        if (engine is null || !File.Exists(Path.Combine(engine, "setup.ps1")))
        {
            MessageBox(0, Strings.L("Не нашёл файлы движка. Переустанови Sozvon."), "Sozvon", MB_ICONERROR);
            Application.Current.Exit();
            return true;
        }
        _window = new SetupWindow(new SetupContext(data, Path.GetFullPath(engine)));
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

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetForegroundWindow(nint window);
}
