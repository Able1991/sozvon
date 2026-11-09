using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Sozvon.App.Calls;
using Sozvon.App.Settings;
using static Sozvon.App.Strings.Loc;

namespace Sozvon.App.Shell;

public enum AppPage { Calls, Projects, Voices, Settings }

/// <summary>The one main window. Closing it only hides it: the app keeps running in the tray.</summary>
public sealed partial class MainWindow : Window
{
    private const int LogicalWidth = 1100, LogicalHeight = 720;
    private readonly CallsViewModel _calls;
    private readonly CallsPage _callsPage;
    private readonly SettingsPage _settingsPage;
    private bool _allowClose;

    [LibraryImport("user32.dll")]
    private static partial uint GetDpiForWindow(nint hwnd);

    public MainWindow(CallsViewModel calls, SettingsViewModel settings)
    {
        _calls = calls;
        InitializeComponent();
        _callsPage = new CallsPage(calls);
        _settingsPage = new SettingsPage(settings);

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        AppWindow.SetIcon(AppPaths.Asset("Sozvon.ico"));
        AppTitleBar.IconSource = new ImageIconSource { ImageSource = new BitmapImage(new Uri(AppPaths.Asset("Sozvon.ico"))) };
        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        AppWindow.Resize(new((int)(LogicalWidth * scale), (int)(LogicalHeight * scale)));
        AppWindow.Closing += OnClosing;

        ApplyTheme(settings.Settings.Theme);
        Show(AppPage.Calls);
    }

    public void ApplyTheme(AppTheme theme) => WindowTheme.Apply(this, Root, theme);

    public void Show(AppPage page)
    {
        Navigation.SelectedItem = ItemFor(page);
        AppWindow.Show();
        Activate();
    }

    public void CloseForExit()
    {
        _allowClose = true;
        Close();
    }

    private void OnClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (!_allowClose)
        {
            args.Cancel = true;
            sender.Hide();
        }
    }

    private NavigationViewItem ItemFor(AppPage page)
    {
        var tag = page.ToString().ToLowerInvariant();
        return Navigation.MenuItems.Concat(Navigation.FooterMenuItems).OfType<NavigationViewItem>().First(i => (string)i.Tag == tag);
    }

    private void OnNavigationChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        PageHost.Content = (args.SelectedItem as NavigationViewItem)?.Tag switch
        {
            "calls" => _callsPage,
            "settings" => _settingsPage,
            "projects" => Placeholder(L("Проекты")),
            "voices" => Placeholder(L("Голоса")),
            _ => null,
        };
    }

    private static StackPanel Placeholder(string title) => new()
    {
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
        Spacing = 8,
        Children =
        {
            new TextBlock { Text = title, Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"], HorizontalAlignment = HorizontalAlignment.Center },
            new TextBlock { Text = L("Пока не подключено"), HorizontalAlignment = HorizontalAlignment.Center },
        },
    };

    private void OnSearchChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args) => _calls.SearchText = sender.Text;
}
