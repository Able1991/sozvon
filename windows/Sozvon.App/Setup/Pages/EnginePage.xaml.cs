using System.ComponentModel;
using System.Diagnostics;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Sozvon.Core.Engine;

namespace Sozvon.App.Setup.Pages;

public sealed partial class EnginePage : UserControl, ISetupPage, IDisposable
{
    private const string PhasePrefix = "==> ";
    private const int MaxLogLines = 400;
    private const string AssistantGlyph = "";
    private readonly SetupContext _context;
    private readonly SetupState _state;
    private readonly EngineInstaller _installer;
    private readonly DispatcherQueue _dispatcher = DispatcherQueue.GetForCurrentThread();
    private readonly List<string> _log = [];

    /// <summary>Whether the assistant chosen two steps back answers, now that the engine can ask it (as the Mac's wizard).</summary>
    private readonly Settings.AssistantChecks _checks;
    private InstallPhase _current = InstallPhase.Stopped;
    private bool _stopRequested;
    private Task? _run;

    internal EnginePage(SetupContext context, SetupState state)
    {
        InitializeComponent();
        _context = context;
        _state = state;
        _installer = new EngineInstaller(context);
        _installer.LineReceived += line => _dispatcher.TryEnqueue(() => AddLine(line));
        _checks = new Settings.AssistantChecks(new Sozvon.Core.Engine.EngineLayout(context.DataFolder, Shell.AppPaths.CallsDir),
            () => new Sozvon.Core.Engine.EngineOptions(Strings.EngineLanguage), Strings.L);
        _checks.Changed += (_, _) =>
        {
            if (_current == InstallPhase.Done)
            {
                ShowDoneRows();
            }
        };
        LogExpander.Header = Strings.L("Подробности");
        OpenLogButton.Content = Strings.L("Открыть журнал");
        FailedBar.Title = Strings.L("Что-то пошло не так.");
        FailedBar.Message = Strings.L("Лог лежит в setup.log в папке данных.");
        StoppedBar.Message = Strings.L("Установка остановлена. Скачанное сохранится, продолжить можно в любой момент.");
    }

    public event Action? Changed;
    public string Glyph => _current switch { InstallPhase.Done => "", InstallPhase.Failed => "", _ => "" };
    public string Title => Strings.L(_current == InstallPhase.Done ? "Движок установлен" : "Установка движка");

    public string Subtitle => Strings.L(_current == InstallPhase.Done
        ? "Python, модель и разбивка по голосам на месте. Первая расшифровка займёт чуть дольше: модель прогревается."
        : "Python, модель Whisper и разбивка по голосам скачаются один раз, 2-4 ГБ. Обычно 5-10 минут.");

    /// <summary>
    /// The download can't be skipped, only taken back: no Stop, Continue only once everything is there, Back stops the
    /// download and returns to the model choice (what was downloaded stays).
    /// </summary>
    public SetupFooter Footer => SetupFlow.Footer(_current) switch
    {
        { Action: InstallAction.Retry } => new(true, Strings.L("Повторить")),
        { Action: InstallAction.ContinueInstall } => new(true, Strings.L("Продолжить установку")),
        { Enabled: var enabled } => new(true, Strings.L("Продолжить"), enabled),
    };

    public void OnShown() => _ = ShowAsync();

    private async Task ShowAsync()
    {
        if (_current == InstallPhase.Running && !_stopRequested)
        {
            return;
        }
        // Back, then forward again at once: the stopped install ends first, then the same model continues.
        if (_run is { IsCompleted: false } stopping)
        {
            await stopping;
        }
        if (_state.IsEngineReady && !_state.UseGpu)
        {
            Show(InstallPhase.Done);
        }
        else
        {
            _run = InstallAsync();
        }
    }

    public bool Primary()
    {
        if (_current == InstallPhase.Done)
        {
            return true;
        }
        if (_current != InstallPhase.Running)
        {
            _run = InstallAsync();
        }
        return false;
    }

    /// <summary>Back to the model choice: the download stops.</summary>
    public void Stop()
    {
        if (_current == InstallPhase.Running)
        {
            _stopRequested = true;
            _installer.Stop();
        }
    }

    /// <summary>The window closed: a download in progress stops, the next start continues on the model step.</summary>
    public void Dispose() => _installer.Stop();

    private async Task InstallAsync()
    {
        _stopRequested = false;
        _log.Clear();
        LogText.Text = "";
        PhaseText.Text = Strings.L("Начинаю установку…");
        Show(InstallPhase.Running);

        var succeeded = false;
        try
        {
            succeeded = await _installer.RunAsync(_state.UseGpu) == 0 && _state.IsEngineReady;
        }
        catch (Exception error) when (error is Win32Exception or IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            AddLine(error.Message);
        }

        // The engine is there now: a fresh check of the chosen assistant, whatever an earlier look found.
        if (succeeded && ChosenAssistant is { } chosen)
        {
            _checks.Run(chosen);
        }
        Show(succeeded ? InstallPhase.Done : _stopRequested ? InstallPhase.Stopped : InstallPhase.Failed);
    }

    private Sozvon.Core.Settings.Assistant? ChosenAssistant =>
        Sozvon.Core.Settings.Assistants.FromKey(_state.Assistant) is { } a and not Sozvon.Core.Settings.Assistant.None ? a : null;

    private void AddLine(string line)
    {
        if (line.StartsWith(PhasePrefix, StringComparison.Ordinal))
        {
            PhaseText.Text = line[PhasePrefix.Length..];
        }
        _log.Add(line);
        if (_log.Count > MaxLogLines)
        {
            _log.RemoveAt(0);
        }
        LogText.Text = string.Join('\n', _log);
        LogScroll.ChangeView(null, double.MaxValue, null, disableAnimation: true);
    }

    private void Show(InstallPhase state)
    {
        _current = state;
        RunningCard.Visibility = state == InstallPhase.Running ? Visibility.Visible : Visibility.Collapsed;
        FailedBar.IsOpen = state == InstallPhase.Failed;
        StoppedBar.IsOpen = state == InstallPhase.Stopped;
        LogExpander.Visibility = state != InstallPhase.Done && (state == InstallPhase.Running || _log.Count > 0) ? Visibility.Visible : Visibility.Collapsed;
        LogExpander.IsExpanded |= state == InstallPhase.Failed;
        DoneCard.Visibility = state == InstallPhase.Done ? Visibility.Visible : Visibility.Collapsed;
        if (state == InstallPhase.Done)
        {
            if (ChosenAssistant is { } chosen)
            {
                _checks.RunOnce(chosen);
            }
            ShowDoneRows();
        }
        Changed?.Invoke();
    }

    private void ShowDoneRows()
    {
        var hasDiarization = EngineStatus.HasDiarization(_context);
        DoneRows.Children.Clear();
        DoneRows.Children.Add(new DoneRow("", "Python", Strings.L("Своя копия внутри Sozvon, системный Python не трогается"), true));
        DoneRows.Children.Add(new DoneRow("", _state.Model.Title, Strings.L("%@, скачана и проверена", _state.Model.Size), true));
        DoneRows.Children.Add(new DoneRow("", Strings.L("Разбивка по голосам"),
            Strings.L(hasDiarization ? "pyannote, работает на этом компьютере" : "Модели не скачались, расшифровка будет без разбивки по голосам"), hasDiarization));
        if (ChosenAssistant is { } chosen && _checks.Result(chosen) is { } check)
        {
            var title = Sozvon.Core.Assistants.AssistantCli.Title(chosen);
            var row = check.State switch
            {
                Sozvon.Core.Assistants.AssistantCheckState.Running => new DoneRow(AssistantGlyph, title, Strings.L("Проверяю, отвечает ли ассистент…"), DoneRow.Mark.Working),
                Sozvon.Core.Assistants.AssistantCheckState.Ok => new DoneRow(AssistantGlyph, title, Strings.L("Отвечает"), DoneRow.Mark.Done),
                _ => new DoneRow(AssistantGlyph, title, _checks.Problem(chosen) ?? "", DoneRow.Mark.Problem),
            };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(row, "AssistantCheckRow");
            DoneRows.Children.Add(row);
        }
    }

    private void OnOpenLog(object sender, RoutedEventArgs e)
    {
        try
        {
            Process.Start(new ProcessStartInfo(_context.LogFile) { UseShellExecute = true })?.Dispose();
        }
        catch (Win32Exception error)
        {
            AddLine(error.Message);
        }
    }
}
