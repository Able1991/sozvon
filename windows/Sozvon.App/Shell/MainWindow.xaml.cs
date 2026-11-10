using System.Runtime.InteropServices;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.System;
using Windows.Foundation;
using Windows.Graphics;
using Sozvon.App.Calls;
using Sozvon.App.Settings;
using static Sozvon.App.Strings.Loc;

namespace Sozvon.App.Shell;

public enum AppPage { Calls, Projects, Voices, Settings }

/// <summary>The one main window. Closing it only hides it: the app keeps running in the tray.</summary>
public sealed partial class MainWindow : Window
{
    private const int LogicalWidth = 1100, LogicalHeight = 720;
    private const double TitleBarGap = 16;
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
        TitleBarIcon.Source = new BitmapImage(new Uri(AppPaths.Asset("Sozvon.ico")));
        Root.Loaded += (_, _) => Root.XamlRoot.Changed += (_, _) => UpdateTitleBar();
        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        AppWindow.Resize(new((int)(LogicalWidth * scale), (int)(LogicalHeight * scale)));
        AppWindow.Closing += OnClosing;

        ApplyTheme(settings.Settings.Theme);
        Root.KeyboardAccelerators.Add(Accelerator(VirtualKeyModifiers.Control, OnFind));
        Root.KeyboardAccelerators.Add(Accelerator(VirtualKeyModifiers.Control | VirtualKeyModifiers.Menu, SearchCalls));
        Show(AppPage.Calls);
    }

    private static KeyboardAccelerator Accelerator(VirtualKeyModifiers modifiers, Action action)
    {
        var accelerator = new KeyboardAccelerator { Key = VirtualKey.F, Modifiers = modifiers };
        accelerator.Invoked += (_, args) =>
        {
            action();
            args.Handled = true;
        };
        return accelerator;
    }

    /// <summary>Ctrl+F: inside the transcript on its tab, otherwise the search across calls.</summary>
    private void OnFind()
    {
        if (!ReferenceEquals(PageHost.Content, _callsPage) || !_callsPage.OpenTranscriptFind())
        {
            SearchCalls();
        }
    }

    /// <summary>Ctrl+Alt+F, and Ctrl+F away from a transcript: the search across calls.</summary>
    private void SearchCalls()
    {
        Navigation.SelectedItem = ItemFor(AppPage.Calls);
        SearchBox.Focus(FocusState.Keyboard);
    }

    public void ApplyTheme(AppTheme theme) => WindowTheme.Apply(this, Root, theme);

    public void Show(AppPage page)
    {
        Navigation.SelectedItem = ItemFor(page);
        AppWindow.Show();
        Activate();
    }

    /// <summary>A question in this window: whether the destructive answer was chosen.</summary>
    public async Task<bool> ConfirmAsync(string title, string text, string destructive)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Title = title,
            Content = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap },
            PrimaryButtonText = destructive,
            CloseButtonText = L("Отмена"),
            DefaultButton = ContentDialogButton.Close,
        };
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
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

    private void OnTitleBarSizeChanged(object sender, SizeChangedEventArgs e) => UpdateTitleBar();

    /// <summary>
    /// Centres the search on the whole window, as File Explorer and Settings do: equal side margins wide enough to
    /// clear both the icon and title on the left and the caption buttons on the right. The box is the one place in
    /// the title bar that takes clicks; the rest drags the window.
    /// </summary>
    private void UpdateTitleBar()
    {
        if (AppTitleBar.XamlRoot is not { } xamlRoot)
        {
            return;
        }
        var scale = xamlRoot.RasterizationScale;
        var header = TitleBarHeader.Margin.Left + TitleBarHeader.ActualWidth;
        var side = Math.Max(header, AppWindow.TitleBar.RightInset / scale) + TitleBarGap;
        SearchBox.Margin = new Thickness(side, 0, side, 0);

        var width = Math.Max(0, Math.Min(SearchBox.MaxWidth, AppTitleBar.ActualWidth - 2 * side));
        var bounds = new Rect((AppTitleBar.ActualWidth - width) / 2, (AppTitleBar.ActualHeight - SearchBox.ActualHeight) / 2, width, SearchBox.ActualHeight);
        InputNonClientPointerSource.GetForWindowId(AppWindow.Id).SetRegionRects(NonClientRegionKind.Passthrough,
        [
            new RectInt32((int)Math.Round(bounds.X * scale), (int)Math.Round(bounds.Y * scale),
                (int)Math.Round(bounds.Width * scale), (int)Math.Round(bounds.Height * scale)),
        ]);
    }

    private void OnSearchChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args) => _calls.SearchText = sender.Text;
}
