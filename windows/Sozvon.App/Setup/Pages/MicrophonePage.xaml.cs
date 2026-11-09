using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.System;

namespace Sozvon.App.Setup.Pages;

public sealed partial class MicrophonePage : UserControl, ISetupPage, IDisposable
{
    private enum TestState { Idle, Running, Passed, Failed }

    private readonly DispatcherTimer _permissionTimer = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly CancellationTokenSource _closing = new();
    private TestState _test;

    public MicrophonePage()
    {
        InitializeComponent();
        MicTitle.Text = Strings.L("Микрофон");
        MicDetail.Text = Strings.L("Твой голос");
        SettingsButton.Content = Strings.L("Открыть настройки");
        TestTitle.Text = Strings.L("Пробная запись");
        PassedText.Text = Strings.L("Получилось");
        ConsentText.Text = Strings.L("Согласие собеседников на запись на тебе.");
        BlockedBar.Title = Strings.L("Микрофон заблокирован.");
        BlockedBar.Message = Strings.L("Разреши его в Параметрах: Конфиденциальность и защита > Микрофон.");
        ShowTest(TestState.Idle, Strings.L("Три секунды с микрофона, в память. Ничего не сохраняется"));
        _permissionTimer.Tick += (_, _) => ShowPermission();
        Loaded += (_, _) => _permissionTimer.Start();
        Unloaded += (_, _) => _permissionTimer.Stop();
    }

    public event Action? Changed;
    public string Glyph => "";
    public string Title => Strings.L("Разрешения");
    public string Subtitle => Strings.L("Без микрофона звонок не записать. Звук компьютера разрешения не требует.");
    public SetupFooter Footer => new(false, Strings.L(_test == TestState.Passed ? "Продолжить" : "Пропустить"), _test != TestState.Running);

    public void OnShown() => ShowPermission();

    public bool Primary() => true;

    public void Dispose()
    {
        _permissionTimer.Stop();
        _closing.Cancel();
    }

    private void ShowPermission()
    {
        var allowed = MicrophonePermission.IsAllowed;
        MicStatus.Text = Strings.L(allowed ? "Разрешено" : "Запрещено");
        BlockedBar.IsOpen = !allowed;
    }

    private async void OnOpenSettings(object sender, RoutedEventArgs e) =>
        await Launcher.LaunchUriAsync(new Uri("ms-settings:privacy-microphone"));

    private async void OnTest(object sender, RoutedEventArgs e)
    {
        ShowTest(TestState.Running, Strings.L("Пишу три секунды…"));
        var level = new Progress<double>(value => LevelMeter.Value = value);
        try
        {
            await MicrophoneTest.RunAsync(level, _closing.Token);
            ShowTest(TestState.Passed, Strings.L("Микрофон записывается"));
        }
        catch (MicrophoneTestException error)
        {
            ShowTest(TestState.Failed, error.Message);
        }
        catch (OperationCanceledException)
        {
            // The window is closing.
        }
    }

    private void ShowTest(TestState state, string detail)
    {
        _test = state;
        TestDetail.Text = detail;
        LevelMeter.Visibility = state == TestState.Running ? Visibility.Visible : Visibility.Collapsed;
        PassedMark.Visibility = state == TestState.Passed ? Visibility.Visible : Visibility.Collapsed;
        TestButton.Visibility = state is TestState.Idle or TestState.Failed ? Visibility.Visible : Visibility.Collapsed;
        TestButton.Content = Strings.L(state == TestState.Failed ? "Ещё раз" : "Проверить");
        Changed?.Invoke();
    }
}
