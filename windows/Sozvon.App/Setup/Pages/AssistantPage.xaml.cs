using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Sozvon.App.Setup.Pages;

public sealed partial class AssistantPage : UserControl, ISetupPage
{
    private const string Group = "assistant";
    private const string UnverifiedWarning = "Этот ассистент не проверялся на Windows с настоящей программой, его песочница тоже. Текст звонка уходит выбранному ассистенту.";
    private const string CursorWarning = UnverifiedWarning + " У Cursor на Windows может не быть файловой песочницы.";
    private readonly SetupState _state;

    internal AssistantPage(SetupState state)
    {
        InitializeComponent();
        _state = state;
        foreach (var assistant in state.Assistants)
        {
            AddChoice(assistant.Key, assistant.Title, Strings.L(assistant.IsInstalled ? "установлен" : "не найден"), assistant.Description, assistant.IsInstalled);
        }
        AddChoice(SetupState.NoAssistant, Strings.L("Без саммари"), "", Strings.L("Только расшифровка. Ничего не покидает компьютер. Можно включить позже в Настройках."), true);
        WarningBar.Title = Strings.L("Не проверено на Windows");
        SummaryLanguageLabel.Text = Strings.L("Язык саммари");
        AutomationProperties.SetName(SummaryLanguageBox, Strings.L("Язык саммари"));
        foreach (var code in SetupState.SummaryLanguages)
        {
            SummaryLanguageBox.Items.Add(new ComboBoxItem { Content = LanguageTitle(code) });
        }
        SummaryLanguageBox.SelectedIndex = SetupState.SummaryLanguages.ToList().IndexOf(state.SummaryLanguage);
        ShowWarning();
    }

    /// <summary>As the call languages are named on the next step; the summary follows the conversation by default.</summary>
    private static string LanguageTitle(string code) => code switch
    {
        "ru" => Strings.L("Русский"),
        "en" => "English",
        "uk" => Strings.L("Українська"),
        "de" => "Deutsch",
        "es" => "Español",
        _ => Strings.L("Как в разговоре"),
    };

    private void OnSummaryLanguageChanged(object sender, SelectionChangedEventArgs e)
    {
        if (SummaryLanguageBox.SelectedIndex >= 0)
        {
            _state.SummaryLanguage = SetupState.SummaryLanguages[SummaryLanguageBox.SelectedIndex];
        }
    }

    public event Action? Changed { add { } remove { } }
    public string Glyph => "";
    public string Title => Strings.L("Помощник для саммари");
    public string Subtitle => Strings.L("Кто будет писать «Коротко», «Решения» и «Задачи». Текст звонка уходит в сервис помощника, аудио остаётся на компьютере.");
    public SetupFooter Footer => new(true, Strings.L("Продолжить"));

    public void OnShown()
    {
    }

    public bool Primary()
    {
        _state.Save();
        return true;
    }

    private void AddChoice(string key, string title, string note, string detail, bool enabled)
    {
        var choice = new RadioButton
        {
            GroupName = Group,
            Content = new ChoiceLabel(title, note, detail),
            IsEnabled = enabled,
            IsChecked = enabled && key == _state.Assistant,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        AutomationProperties.SetAutomationId(choice, "Assistant_" + key);
        choice.Checked += (_, _) =>
        {
            _state.Assistant = key;
            ShowWarning();
        };
        Choices.Children.Add(choice);
    }

    private void ShowWarning()
    {
        // As on the Mac: the summary's language is asked only when there will be a summary.
        SummaryLanguageCard.Visibility = _state.Assistant == SetupState.NoAssistant ? Visibility.Collapsed : Visibility.Visible;
        var cursor = _state.Assistant == "cursor";
        WarningBar.IsOpen = cursor || _state.Assistant == "codex";
        WarningBar.Message = Strings.L(cursor ? CursorWarning : UnverifiedWarning);
    }
}
