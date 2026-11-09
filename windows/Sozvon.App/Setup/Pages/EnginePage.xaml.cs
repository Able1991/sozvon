using System.ComponentModel;
using System.Diagnostics;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Sozvon.App.Setup.Pages;

public sealed partial class EnginePage : UserControl, ISetupPage, IDisposable
{
    private enum InstallState { Running, Failed, Stopped, Done }

    private const string PhasePrefix = "==> ";
    private const int MaxLogLines = 400;
    private readonly SetupContext _context;
    private readonly SetupState _state;
    private readonly EngineInstaller _installer;
    private readonly DispatcherQueue _dispatcher = DispatcherQueue.GetForCurrentThread();
    private readonly List<string> _log = [];
    private InstallState _current = InstallState.Stopped;
    private bool _stopRequested;

    internal EnginePage(SetupContext context, SetupState state)
    {
        InitializeComponent();
        _context = context;
        _state = state;
        _installer = new EngineInstaller(context);
        _installer.LineReceived += line => _dispatcher.TryEnqueue(() => AddLine(line));
        LogExpander.Header = Strings.L("Подробности");
        OpenLogButton.Content = Strings.L("Открыть журнал");
        FailedBar.Title = Strings.L("Что-то пошло не так.");
        FailedBar.Message = Strings.L("Лог лежит в setup.log в папке данных.");
        StoppedBar.Message = Strings.L("Установка остановлена. Скачанное сохранится, продолжить можно в любой момент.");
    }

    public event Action? Changed;
    public string Glyph => _current switch { InstallState.Done => "", InstallState.Failed => "", _ => "" };
    public string Title => Strings.L(_current == InstallState.Done ? "Движок установлен" : "Установка движка");

    public string Subtitle => Strings.L(_current == InstallState.Done
        ? "Python, модель и разбивка по голосам на месте. Первая расшифровка займёт чуть дольше: модель прогревается."
        : "Python, модель Whisper и разбивка по голосам скачаются один раз, 2-4 ГБ. Обычно 5-10 минут.");

    public SetupFooter Footer => _current switch
    {
        InstallState.Running => new(false, Strings.L("Остановить"), PrimaryIsAccent: false),
        InstallState.Done => new(false, Strings.L("Продолжить")),
        _ => new(true, Strings.L("Продолжить установку")),
    };

    public void OnShown()
    {
        if (_current == InstallState.Running)
        {
            return;
        }
        if (_state.IsEngineReady && !_state.UseGpu)
        {
            Show(InstallState.Done);
        }
        else
        {
            _ = InstallAsync();
        }
    }

    public bool Primary()
    {
        switch (_current)
        {
            case InstallState.Done:
                return true;
            case InstallState.Running:
                _stopRequested = true;
                _installer.Stop();
                return false;
            default:
                _ = InstallAsync();
                return false;
        }
    }

    public void Dispose() => _installer.Stop();

    private async Task InstallAsync()
    {
        _stopRequested = false;
        _log.Clear();
        LogText.Text = "";
        PhaseText.Text = Strings.L("Начинаю установку…");
        Show(InstallState.Running);

        var succeeded = false;
        try
        {
            succeeded = await _installer.RunAsync(_state.UseGpu) == 0 && _state.IsEngineReady;
        }
        catch (Exception error) when (error is Win32Exception or IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            AddLine(error.Message);
        }

        Show(succeeded ? InstallState.Done : _stopRequested ? InstallState.Stopped : InstallState.Failed);
    }

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

    private void Show(InstallState state)
    {
        _current = state;
        RunningCard.Visibility = state == InstallState.Running ? Visibility.Visible : Visibility.Collapsed;
        FailedBar.IsOpen = state == InstallState.Failed;
        StoppedBar.IsOpen = state == InstallState.Stopped;
        LogExpander.Visibility = state != InstallState.Done && (state == InstallState.Running || _log.Count > 0) ? Visibility.Visible : Visibility.Collapsed;
        LogExpander.IsExpanded |= state == InstallState.Failed;
        DoneCard.Visibility = state == InstallState.Done ? Visibility.Visible : Visibility.Collapsed;
        if (state == InstallState.Done)
        {
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
