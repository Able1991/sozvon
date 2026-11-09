using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Sozvon.App.Capsule;
using Sozvon.App.Setup.Pages;
using WinRT.Interop;

namespace Sozvon.App.Setup;

/// <summary>The first-run wizard: seven steps in one fixed 600 x 680 window.</summary>
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
    }

    private void ConfigureWindow()
    {
        Title = WindowTitle.Text = Strings.L("Настройка Sozvon");
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBarArea);
        var presenter = OverlappedPresenter.Create();
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        AppWindow.SetPresenter(presenter);

        var scale = NativeWindow.GetDpiForWindow(WindowNative.GetWindowHandle(this)) / 96.0;
        var width = (int)(LogicalWidth * scale);
        var height = (int)(LogicalHeight * scale);
        var screen = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        AppWindow.MoveAndResize(new(screen.X + (screen.Width - width) / 2, screen.Y + (screen.Height - height) / 2, width, height));
    }

    private void Show(int index)
    {
        _index = index;
        ErrorBar.IsOpen = false;
        Host.Content = _pages[index];
        _pages[index].OnShown();
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
