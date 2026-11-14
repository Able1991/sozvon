using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Sozvon.App.Setup.Pages;

public sealed partial class ModelPage : UserControl, ISetupPage
{
    private const string Group = "model";
    private readonly SetupContext _context;
    private readonly SetupState _state;

    internal ModelPage(SetupContext context, SetupState state, string? nvidiaCard)
    {
        InitializeComponent();
        _context = context;
        _state = state;
        foreach (var model in state.Models)
        {
            AddChoice(model);
        }
        var gigaam = state.Models.FirstOrDefault(m => m.Key == "gigaam");
        RussianTitle.Text = Strings.L("Русские разговоры через GigaAM");
        RussianNote.Text = Strings.L("Ещё %@. Whisper определит язык каждой дорожки, русскую расшифрует GigaAM.", gigaam?.Size ?? "");
        AutomationProperties.SetName(RussianSwitch, RussianTitle.Text);
        RussianSwitch.IsOn = state.ModelRu == "gigaam";
        ShowRussian();
        if (nvidiaCard is not null)
        {
            GpuCard.Visibility = Visibility.Visible;
            GpuTitle.Text = Strings.L("Ускорить на видеокарте NVIDIA");
            GpuNote.Text = Strings.L("Найдена %@. Скачается ещё несколько ГБ. Без ускорения всё работает на процессоре, только медленнее.", nvidiaCard);
        }
    }

    public event Action? Changed;
    public string Glyph => "";
    public string Title => Strings.L("Модель распознавания");
    public string Subtitle => Strings.L("Модель скачается один раз и будет работать на этом компьютере. Точнее обычно значит медленнее.");
    public SetupFooter Footer => new(true, Strings.L(_state.IsEngineReady && !_state.UseGpu ? "Продолжить" : "Скачать и продолжить"));

    public void OnShown()
    {
    }

    public bool Primary()
    {
        _state.Save();
        return true;
    }

    private void AddChoice(SpeechModel model)
    {
        var notes = new List<string>();
        if (model.Recommended)
        {
            notes.Add(Strings.L("рекомендуем"));
        }
        notes.Add(model.Size);
        if (EngineStatus.IsDownloaded(_context, model))
        {
            notes.Add(Strings.L("скачана"));
        }
        var choice = new RadioButton
        {
            GroupName = Group,
            Content = new ChoiceLabel(model.Title, string.Join(" · ", notes), model.Description),
            IsChecked = model == _state.Model,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        AutomationProperties.SetAutomationId(choice, "Model_" + model.Key);
        choice.Checked += (_, _) =>
        {
            _state.Model = model;
            ShowRussian();
            Changed?.Invoke();
        };
        Choices.Children.Add(choice);
    }

    /// <summary>Only after a Whisper model: GigaAM and Parakeet can't tell the languages of the tracks apart.</summary>
    private void ShowRussian() =>
        RussianCard.Visibility = _state.Model.Vad is null ? Visibility.Visible : Visibility.Collapsed;

    private void OnRussianToggled(object sender, RoutedEventArgs e)
    {
        var chosen = RussianSwitch.IsOn ? "gigaam" : (_state.ModelRu == "gigaam" ? "" : _state.ModelRu);
        if (chosen != _state.ModelRu)
        {
            _state.ModelRu = chosen;
            Changed?.Invoke();
        }
    }

    private void OnGpuClick(object sender, RoutedEventArgs e)
    {
        _state.UseGpu = GpuBox.IsChecked == true;
        Changed?.Invoke();
    }
}
