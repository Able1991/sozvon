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
            LeftClickCommand = new RelayCommand(() => host.OpenWindow(null)),
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

    public void Notify(string text) => _icon?.ShowNotification("Sozvon", text);

    public void Refresh()
    {
        if (_icon is null)
        {
            return;
        }
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
            AddAction(menu, "Завершить настройку…", host.OpenSetup);
            AddSeparator(menu);
            AddAction(menu, "Выход", host.Exit);
            return menu;
        }

        AddAction(menu, "Открыть", () => host.OpenWindow(null));
        AddSeparator(menu);
        if (state.State == TrayState.Recording)
        {
            AddAction(menu, "Остановить и расшифровать", () => host.Recording?.Stop());
            AddAction(menu, "Отметить важное", () => host.Recording?.Mark());
            AddAction(menu, "Проект и собеседники…", () => host.Recording?.EditInfo());
        }
        else
        {
            AddAction(menu, "Начать запись", () => host.Recording?.Begin());
        }
        AddSeparator(menu);
        AddCallItems(menu);
        AddAction(menu, "Звонки…", () => host.OpenWindow(AppPage.Calls));
        AddAction(menu, "Проекты…", () => host.OpenWindow(AppPage.Projects));
        AddSeparator(menu);
        Add(menu, new ToggleMenuFlyoutItem
        {
            Text = L("Плавающая панель"),
            IsChecked = state.FloatingPanel,
            Command = new RelayCommand(() => host.SetFloatingPanel(!state.FloatingPanel)),
        });
        Add(menu, new ToggleMenuFlyoutItem
        {
            Text = L("Открывать при входе"),
            IsChecked = host.SignIn.IsOn,
            Command = new RelayCommand(() => host.SignIn.IsOn = !host.SignIn.IsOn),
        });
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
            menu.Items.Add(new MenuFlyoutItem { Text = text, Command = new RelayCommand(() => host.Recording?.DescribePending()) });
        }
        if (state.LatestCallId is { } id)
        {
            AddAction(menu, "Последняя расшифровка", () => host.OpenCall(id));
            if (state.LatestAudioFolder is { } folder)
            {
                AddAction(menu, "Расшифровать заново…", () => host.Recording?.Retranscribe(folder));
            }
        }
    }

    private static void Add(MenuFlyout menu, MenuFlyoutItemBase item) => menu.Items.Add(item);

    private static void AddSeparator(MenuFlyout menu) => Add(menu, new MenuFlyoutSeparator());

    private static void AddAction(MenuFlyout menu, string key, Action action) =>
        Add(menu, new MenuFlyoutItem { Text = L(key), Command = new RelayCommand(action) });
}
