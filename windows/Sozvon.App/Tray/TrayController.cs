using System.Drawing;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using CommunityToolkit.Mvvm.Input;
using H.NotifyIcon;
using Microsoft.UI.Xaml.Controls;
using Sozvon.App.Shell;
using static Sozvon.App.Strings.Loc;

namespace Sozvon.App.Tray;

/// <summary>The notification area icon and its native menu, rebuilt from the view model each time it opens.</summary>
public sealed partial class TrayController(AppHost host, TrayViewModel state) : IDisposable
{
    private const int SM_CXSMICON = 49;
    private TaskbarIcon? _icon;
    private Icon? _ready;
    private Icon? _recording;

    [LibraryImport("user32.dll")]
    private static partial int GetSystemMetrics(int index);

    private static string NotConnected => "\t" + L("пока не подключено");

    public void Start()
    {
        var size = GetSystemMetrics(SM_CXSMICON);
        _ready = new Icon(AppPaths.Asset("Sozvon.ico"), size, size);
        _recording = new Icon(AppPaths.Asset("SozvonRecording.ico"), size, size);
        _icon = new TaskbarIcon
        {
            Id = StableGuid(),
            ContextMenuMode = H.NotifyIcon.ContextMenuMode.PopupMenu,
            NoLeftClickDelay = true,
            LeftClickCommand = new RelayCommand(() => host.OpenWindow(AppPage.Calls)),
            RightClickCommand = new RelayCommand(Refresh),
            ToolTipText = state.ToolTip,
            ContextFlyout = BuildMenu(),
        };
        _icon.UpdateIcon(CurrentIcon());
        _icon.ForceCreate(enablesEfficiencyMode: false);
    }

    public void Dispose()
    {
        _icon?.Dispose();
        _icon = null;
        _ready?.Dispose();
        _recording?.Dispose();
    }

    /// <summary>
    /// Windows binds a tray GUID to the executable's path and refuses it from another path,
    /// so the GUID comes from the path: the icon appears wherever the app is installed.
    /// </summary>
    private static Guid StableGuid()
    {
        var path = (Environment.ProcessPath ?? "sozvon").ToLowerInvariant();
        return new Guid(MD5.HashData(Encoding.UTF8.GetBytes(path)));
    }

    private void Refresh()
    {
        state.Refresh();
        _icon!.ContextFlyout = BuildMenu();
        _icon.ToolTipText = state.ToolTip;
        _icon.UpdateIcon(CurrentIcon());
    }

    private Icon CurrentIcon() => state.State == TrayState.Recording ? _recording! : _ready!;

    private MenuFlyout BuildMenu()
    {
        var menu = new MenuFlyout();
        Add(menu, new MenuFlyoutItem { Text = "Sozvon · " + state.StatusText, IsEnabled = false });
        if (state.State == TrayState.SetupNeeded)
        {
            AddSeparator(menu);
            AddNotConnected(menu, "Завершить настройку…");
            AddSeparator(menu);
            AddAction(menu, "Выход", host.Exit);
            return menu;
        }

        AddAction(menu, "Открыть", () => host.OpenWindow(AppPage.Calls));
        AddSeparator(menu);
        if (state.State == TrayState.Recording)
        {
            AddNotConnected(menu, "Остановить и расшифровать");
            AddNotConnected(menu, "Отметить важное");
            AddNotConnected(menu, "Проект и собеседники…");
        }
        else
        {
            AddNotConnected(menu, "Начать запись");
        }
        AddSeparator(menu);
        AddCallItems(menu);
        AddAction(menu, "Звонки…", () => host.OpenWindow(AppPage.Calls));
        AddAction(menu, "Проекты…", () => host.OpenWindow(AppPage.Projects));
        AddSeparator(menu);
        AddStored(menu, "Плавающая панель", state.FloatingPanel);
        AddStored(menu, "Открывать при входе", state.OpenAtSignIn);
        AddSeparator(menu);
        AddAction(menu, "Настройки…", () => host.OpenWindow(AppPage.Settings));
        AddAction(menu, "Выход", host.Exit);
        return menu;
    }

    private void AddCallItems(MenuFlyout menu)
    {
        if (state.WaitingForDescription > 0)
        {
            var text = L("Ждут описания: %d", state.WaitingForDescription);
            menu.Items.Add(new MenuFlyoutItem { Text = text, Command = new RelayCommand(() => host.OpenWindow(AppPage.Calls)) });
        }
        if (state.LatestCallId is { } id)
        {
            AddAction(menu, "Последняя расшифровка", () => host.OpenCall(id));
            AddNotConnected(menu, "Расшифровать заново…");
        }
    }

    private static void Add(MenuFlyout menu, MenuFlyoutItemBase item) => menu.Items.Add(item);

    private static void AddSeparator(MenuFlyout menu) => Add(menu, new MenuFlyoutSeparator());

    private static void AddAction(MenuFlyout menu, string key, Action action) =>
        Add(menu, new MenuFlyoutItem { Text = L(key), Command = new RelayCommand(action) });

    private static void AddNotConnected(MenuFlyout menu, string key) =>
        Add(menu, new MenuFlyoutItem { Text = L(key) + NotConnected, IsEnabled = false });

    private static void AddStored(MenuFlyout menu, string key, bool isChecked) =>
        Add(menu, new ToggleMenuFlyoutItem { Text = L(key) + NotConnected, IsChecked = isChecked, IsEnabled = false });
}
