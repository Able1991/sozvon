using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Sozvon.App.Setup.Pages;

public sealed partial class DetailsPage : UserControl, ISetupPage
{
    private readonly SetupState _state;
    private readonly Settings.CallsFolderChanger _folder;
    private readonly Dictionary<string, CheckBox> _languages = [];
    private readonly CheckBox _auto = new();
    private bool _updating;

    internal DetailsPage(SetupState state, Settings.CallsFolderChanger folder)
    {
        InitializeComponent();
        _state = state;
        _folder = folder;
        FolderLabel.Text = Strings.L("Папка звонков");
        FolderButton.Content = Strings.L("Сменить папку…");
        folder.PropertyChanged += (_, _) => ShowFolder();
        ShowFolder();
        NameLabel.Text = Strings.L("Как тебя подписывать");
        AutomationProperties.SetName(NameBox, NameLabel.Text);
        NameBox.PlaceholderText = Strings.L("Аня");
        NameBox.Text = state.Name;
        LanguagesLabel.Text = Strings.L("Языки звонков");
        FootText.Text = Strings.L("Расшифровка уступает твоим программам: при звонке она не мешает Zoom и браузеру.");
        AddLanguage("ru", Strings.L("Русский"));
        AddLanguage("en", "English");
        AddLanguage("uk", Strings.L("Українська"));
        AddLanguage("de", "Deutsch");
        AddLanguage("es", "Español");
        AddAuto();
        ShowLanguages();
    }

    public event Action? Changed { add { } remove { } }
    public string Glyph => "";
    public string Title => Strings.L("Пара деталей");
    public string Subtitle => Strings.L("Имя пишется в расшифровке рядом с твоими репликами. Языки помогают модели не путать слова.");
    public SetupFooter Footer => new(true, Strings.L("Продолжить"));

    public void OnShown()
    {
    }

    public bool Primary()
    {
        _state.Name = NameBox.Text;
        _state.Save();
        return true;
    }

    private void ShowFolder()
    {
        FolderPath.Text = _folder.Shown;
        ToolTipService.SetToolTip(FolderPath, _folder.Current);
        FolderButton.IsEnabled = _folder.CanChange;
    }

    private async void OnChangeFolder(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        try
        {
            await _folder.ChangeAsync(XamlRoot);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            // A dialog already open, or a folder that went away meanwhile: the row keeps the folder in use.
            FolderPath.Text = error.Message;
        }
    }

    private void AddLanguage(string key, string title)
    {
        var box = new CheckBox { Content = title };
        AutomationProperties.SetAutomationId(box, "Language_" + key);
        box.Checked += (_, _) => OnLanguageChanged();
        box.Unchecked += (_, _) => OnLanguageChanged();
        _languages[key] = box;
        LanguageChoices.Children.Add(box);
    }

    // "Detect automatically" is the state with no language chosen, so unticking it alone changes nothing.
    private void AddAuto()
    {
        _auto.Content = Strings.L("Определять сам");
        AutomationProperties.SetAutomationId(_auto, "Language_auto");
        _auto.Checked += (_, _) =>
        {
            if (!_updating)
            {
                _state.Languages = [];
                ShowLanguages();
            }
        };
        _auto.Unchecked += (_, _) =>
        {
            if (!_updating)
            {
                ShowLanguages();
            }
        };
        LanguageChoices.Children.Add(_auto);
    }

    private void OnLanguageChanged()
    {
        if (!_updating)
        {
            _state.Languages = _languages.Where(pair => pair.Value.IsChecked == true).Select(pair => pair.Key).ToList();
            ShowLanguages();
        }
    }

    private void ShowLanguages()
    {
        _updating = true;
        foreach (var (key, box) in _languages)
        {
            box.IsChecked = _state.Languages.Contains(key);
        }
        _auto.IsChecked = _state.Languages.Count == 0;
        _updating = false;
    }
}
