using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Sozvon.App.Capsule;
using Sozvon.App.Settings;
using Sozvon.App.Setup.Pages;
using Sozvon.App.Shell;
using Windows.Foundation;
using WinRT.Interop;

namespace Sozvon.App.Setup;

/// <summary>The first-run wizard: seven steps in one fixed window 600 wide and as tall as the tallest step.</summary>
public sealed partial class SetupWindow : Window
{
    private const int LogicalWidth = 600, LogicalHeight = 680;
    private readonly ISetupPage[] _pages;
    private readonly Border[] _pips;
    private int _index;

    internal SetupWindow(SetupContext context)
    {
        // Added here and not in the window's own resources: the pages resolve these styles when they are created.
        Application.Current.Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("ms-appx:///Setup/SetupStyles.xaml") });
        InitializeComponent();
        ConfigureWindow();
        WindowTheme.Apply(this, Root, new SettingsStore(context.SettingsFile).Settings.Theme);

        var state = new SetupState(context, ModelCatalog.Load(context.ModelsManifest), MachineTools.FindAssistants());
        _pages =
        [
            new WelcomePage(),
            new AssistantPage(state),
            new DetailsPage(state),
            new ModelPage(context, state, MachineTools.FindNvidiaCard()),
            new EnginePage(context, state),
            new MicrophonePage(),
            new ReadyPage(),
        ];
        _pips = _pages.Select(_ => new Border()).ToArray();
        foreach (var pip in _pips)
        {
            Pips.Children.Add(pip);
        }
        foreach (var page in _pages)
        {
            page.Changed += Refresh;
        }
        Closed += (_, _) =>
        {
            foreach (var page in _pages.OfType<IDisposable>())
            {
                page.Dispose();
            }
        };
        Show(0);
        Root.Loaded += (_, _) => FitTallestStep();
    }

    private void ConfigureWindow()
    {
        Title = WindowTitle.Text = Strings.L("Настройка Sozvon");
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBarArea);
        // A fixed wizard: Windows drops the maximize button only when minimize is off as well.
        var presenter = OverlappedPresenter.Create();
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        AppWindow.SetPresenter(presenter);

        var scale = NativeWindow.GetDpiForWindow(WindowNative.GetWindowHandle(this)) / 96.0;
        CenterOnScreen((int)(LogicalWidth * scale), (int)(LogicalHeight * scale));
    }

    /// <summary>
    /// Sizes the window to the tallest step at its first layout, so no step leaves an empty band above the
    /// buttons; what grows later, like the install log, scrolls.
    /// </summary>
    private void FitTallestStep()
    {
        var shown = _index;
        var tallest = 0.0;
        for (var i = 0; i < _pages.Length; i++)
        {
            Present(i);
            Root.Measure(new Size(LogicalWidth, double.PositiveInfinity));
            tallest = Math.Max(tallest, Root.DesiredSize.Height);
        }
        Present(shown);
        var scale = Root.XamlRoot.RasterizationScale;
        AppWindow.ResizeClient(new((int)Math.Ceiling(LogicalWidth * scale), (int)Math.Ceiling(Math.Min(tallest, LogicalHeight) * scale)));
        CenterOnScreen(AppWindow.Size.Width, AppWindow.Size.Height);
    }

    private void CenterOnScreen(int width, int height)
    {
        var screen = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        AppWindow.MoveAndResize(new(screen.X + (screen.Width - width) / 2, screen.Y + (screen.Height - height) / 2, width, height));
    }

    private void Show(int index)
    {
        Present(index);
        _pages[index].OnShown();
        Refresh();
    }

    private void Present(int index)
    {
        _index = index;
        ErrorBar.IsOpen = false;
        Host.Content = _pages[index];
        Refresh();
    }

    private void Refresh()
    {
        var page = _pages[_index];
        StepText.Text = Strings.L("Шаг %@ из %@", _index + 1, _pages.Length);
        for (var i = 0; i < _pips.Length; i++)
        {
            _pips[i].Width = i == _index ? 32 : 16;
            _pips[i].Style = (Style)Application.Current.Resources[i <= _index ? "SetupPipOn" : "SetupPipOff"];
        }
        PageIcon.Glyph = page.Glyph;
        PageTitle.Text = page.Title;
        PageSubtitle.Text = page.Subtitle;

        var footer = page.Footer;
        BackButton.Content = Strings.L("Назад");
        BackButton.Visibility = footer.BackVisible ? Visibility.Visible : Visibility.Collapsed;
        PrimaryButton.Content = footer.PrimaryText;
        PrimaryButton.IsEnabled = footer.PrimaryEnabled;
        PrimaryButton.Style = footer.PrimaryIsAccent ? (Style)Application.Current.Resources["AccentButtonStyle"] : null;
    }

    private void OnBack(object sender, RoutedEventArgs e) => Show(_index - 1);

    private void OnPrimary(object sender, RoutedEventArgs e)
    {
        try
        {
            if (!_pages[_index].Primary())
            {
                return;
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            ErrorBar.Message = error.Message;
            ErrorBar.IsOpen = true;
            return;
        }

        if (_index == _pages.Length - 1)
        {
            Close();
        }
        else
        {
            Show(_index + 1);
        }
    }
}
