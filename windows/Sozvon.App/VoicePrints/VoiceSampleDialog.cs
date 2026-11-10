using System.Diagnostics;
using System.IO;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Sozvon.App.Shell;
using Sozvon.Audio;
using Sozvon.Audio.Sample;
using Sozvon.Core.Calls;
using Sozvon.Core.Settings;
using Windows.UI;
using static Sozvon.App.Strings.Loc;
using Path = System.IO.Path;

namespace Sozvon.App.VoicePrints;

/// <summary>
/// "Record your voice", as the Mac's sheet: read a short text aloud in a call language, 10 to 25 seconds, then the
/// engine makes the own voice print from it. A long enough recording is saved as soon as it stops; the sample file
/// is deleted either way. With SOZVON_SILENT_CAPTURE=1 it records silence, never the room.
/// </summary>
public sealed partial class VoiceSampleDialog : ContentDialog
{
    // The capsule's wave: 4 DIP bars every 8 DIP, from 4 to 24 DIP high on a 32 DIP line.
    private const int Bars = 28, BarWidth = 4, BarGap = 4, MinBar = 4, MaxBar = 24, WaveHeight = 32;
    private readonly VoiceStore _store;
    private readonly string _dataDir;
    private readonly string _name;
    private readonly bool _add;
    private readonly IReadOnlyList<SpeechLanguage> _languages;
    private readonly DispatcherTimer _ticker = new() { Interval = TimeSpan.FromMilliseconds(50) };
    private readonly double[] _levels = new double[Bars];
    private readonly Rectangle[] _bars = new Rectangle[Bars];
    private readonly TextBlock _subtitle = new() { TextWrapping = TextWrapping.Wrap };
    private readonly SelectorBar _languageBar = new() { Margin = new Thickness(-12, 0, 0, 0) };
    private readonly TextBlock _languageName = new() { Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"], FontWeight = Microsoft.UI.Text.FontWeights.SemiBold };
    private readonly TextBlock _sample = new() { TextWrapping = TextWrapping.Wrap, FontSize = 18, IsTextSelectionEnabled = true };
    private readonly Ellipse _dot = new() { Width = 8, Height = 8, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _clock = new() { FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
    private readonly StackPanel _saving = new() { Orientation = Orientation.Horizontal, Spacing = 8, Visibility = Visibility.Collapsed };
    private readonly InfoBar _problem = new() { IsClosable = false, Severity = InfoBarSeverity.Warning };
    private readonly ElementTheme _theme;
    private SpeechLanguage _language;
    private SampleRecorder? _recorder;
    private string? _file;
    private bool _enrolling;

    /// <param name="add">One more sample merged into the voice print instead of replacing it.</param>
    /// <param name="theme">The window's theme: a dialog does not take it on by itself.</param>
    public VoiceSampleDialog(VoiceStore store, string dataDir, string name, IEnumerable<SpeechLanguage> callLanguages, bool add, ElementTheme theme)
    {
        _theme = theme;
        RequestedTheme = theme;
        _subtitle.Foreground = _languageName.Foreground = Secondary;
        _store = store;
        _dataDir = dataDir;
        _name = name;
        _add = add;
        _languages = VoiceSample.Languages(callLanguages);
        _language = _languages[0];
        CloseButtonText = L("Отмена");
        DefaultButton = ContentDialogButton.Primary;
        Content = Layout();
        _ticker.Tick += (_, _) => Tick();
        PrimaryButtonClick += OnPrimary;
        Closing += OnClosing;
        Closed += async (_, _) => await DiscardAsync();
        ShowLanguage();
        ShowState();
    }

    private Brush Secondary => Themed("TextFillColorSecondaryBrush");

    private Brush Themed(string key) => ThemeBrush.Get(key, _theme);

    private bool IsRecording => _recorder is not null;

    /// <summary>What to do, the language, the text to read, the meter, the state, and where the sample stays.</summary>
    private StackPanel Layout()
    {
        var content = new StackPanel { Spacing = 16, Width = 480 };
        content.Children.Add(_subtitle);
        if (_languages.Count > 1)
        {
            foreach (var language in _languages)
            {
                _languageBar.Items.Add(new SelectorBarItem { Text = LanguageTitle(language), Tag = language, IsSelected = language == _language });
            }
            AutomationProperties.SetName(_languageBar, L("Язык"));
            _languageBar.SelectionChanged += (_, _) =>
            {
                if (_languageBar.SelectedItem?.Tag is SpeechLanguage language && !IsRecording && !_enrolling)
                {
                    _language = language;
                    ShowLanguage();
                }
            };
            content.Children.Add(_languageBar);
        }
        var box = new StackPanel { Spacing = 8 };
        if (_languages.Count == 1)
        {
            box.Children.Add(_languageName);
        }
        box.Children.Add(_sample);
        content.Children.Add(new Border
        {
            Padding = new Thickness(14),
            CornerRadius = new CornerRadius(8),
            Background = Themed("ControlAltFillColorTertiaryBrush"),
            Child = box,
        });
        content.Children.Add(Meter());
        _saving.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
        _saving.Children.Add(new TextBlock { Text = L("Сохраняю голос…"), Foreground = Secondary });
        content.Children.Add(_saving);
        content.Children.Add(_problem);
        content.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            Children =
            {
                new FontIcon { Glyph = "\uE72E", FontSize = 14, Foreground = Secondary },
                new TextBlock { Text = L("Образец остаётся на этом компьютере"), Foreground = Secondary },
            },
        });
        return content;
    }

    /// <summary>Dot, timer, the live level and the limit.</summary>
    private Grid Meter()
    {
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var wave = new StackPanel { Orientation = Orientation.Horizontal, Spacing = BarGap, Height = WaveHeight, VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetAccessibilityView(wave, AccessibilityView.Raw);
        for (var i = 0; i < Bars; i++)
        {
            _bars[i] = new Rectangle { Width = BarWidth, Height = MinBar, RadiusX = BarWidth / 2.0, RadiusY = BarWidth / 2.0, VerticalAlignment = VerticalAlignment.Center };
            wave.Children.Add(_bars[i]);
        }
        var limit = new TextBlock
        {
            Text = "/ " + VoiceSample.Clock(VoiceSample.MaxDuration),
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = Secondary,
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetAccessibilityView(limit, AccessibilityView.Raw);
        Grid.SetColumn(_clock, 1);
        Grid.SetColumn(wave, 2);
        Grid.SetColumn(limit, 3);
        grid.Children.Add(_dot);
        grid.Children.Add(_clock);
        grid.Children.Add(wave);
        grid.Children.Add(limit);
        return grid;
    }

    private static string LanguageTitle(SpeechLanguage language) => language switch
    {
        SpeechLanguage.Ru => "Русский",
        SpeechLanguage.En => "English",
        SpeechLanguage.Uk => "Українська",
        SpeechLanguage.De => "Deutsch",
        SpeechLanguage.Es => "Español",
        _ => language.Code(),
    };

    private void ShowLanguage()
    {
        var text = VoiceSample.Text(_language);
        Title = text is null ? L("Расскажи что-нибудь вслух") : L("Прочитай вслух текст ниже");
        _subtitle.Text = (text is null
                ? L("Секунд двадцать на этом языке обычным голосом, как на звонке: о себе, о работе, о чём угодно.")
                : L("Секунд двадцать обычным голосом, как на звонке. Текст на языке звонков из настроек."))
            + (_add ? " " + L("Образец добавится к записанному голосу, а не заменит его.") : "");
        _languageName.Text = LanguageTitle(_language).ToUpper(Culture);
        ShowSample();
    }

    /// <summary>While recording, the part already due is in the primary colour and the rest dimmer, at an easy pace.</summary>
    private void ShowSample()
    {
        _sample.Inlines.Clear();
        if (VoiceSample.Text(_language) is not { } text)
        {
            _sample.Inlines.Add(new Run { Text = L("Для этого языка нет текста: говори свободно."), Foreground = Secondary });
            return;
        }
        var words = text.Split(' ');
        var done = VoiceSample.WordsRead(text, _recorder?.Elapsed ?? TimeSpan.Zero, IsRecording);
        _sample.Inlines.Add(new Run { Text = string.Join(' ', words.Take(done)) });
        if (done < words.Length)
        {
            _sample.Inlines.Add(new Run { Text = (done > 0 ? " " : "") + string.Join(' ', words.Skip(done)), Foreground = Secondary });
        }
    }

    private void ShowState()
    {
        var elapsed = _recorder?.Elapsed ?? TimeSpan.Zero;
        PrimaryButtonText = IsRecording ? L("Остановить") : _problem.IsOpen ? L("Записать заново") : L("Записать");
        // Stop works at any time while recording: a sample under the minimum is dropped with a message, as on the Mac.
        IsPrimaryButtonEnabled = !_enrolling;
        _languageBar.IsEnabled = !IsRecording && !_enrolling;
        _saving.Visibility = _enrolling ? Visibility.Visible : Visibility.Collapsed;
        _dot.Fill = IsRecording ? new SolidColorBrush(Colors.Red) : Themed("ControlStrongFillColorDisabledBrush");
        _clock.Text = VoiceSample.Clock(elapsed);
        _clock.Foreground = IsRecording ? Themed("TextFillColorPrimaryBrush") : Secondary;
        AutomationProperties.SetName(_clock, L("Записано %@ из %@", VoiceSample.Clock(elapsed), VoiceSample.Clock(VoiceSample.MaxDuration)));
        // The user's own voice is blue in the capsule's wave too; the line is dim until the recording starts.
        var fill = IsRecording ? new SolidColorBrush(_theme == ElementTheme.Dark ? Color.FromArgb(255, 0x6C, 0xB8, 0xFF) : Color.FromArgb(255, 0x00, 0x67, 0xD4))
            : Themed("ControlStrongFillColorDisabledBrush");
        for (var i = 0; i < Bars; i++)
        {
            _bars[i].Fill = fill;
            _bars[i].Height = MinBar + (MaxBar - MinBar) * Math.Pow(_levels[i], 1.4);
        }
    }

    private void Tick()
    {
        if (_recorder is not { } recorder)
        {
            return;
        }
        Array.Copy(_levels, 1, _levels, 0, Bars - 1);
        _levels[^1] = VoiceSample.Level(recorder.TakeRms());
        ShowSample();
        ShowState();
        if (recorder.Elapsed >= VoiceSample.MaxDuration || recorder.Failure is not null)
        {
            _ = StopAsync();
        }
    }

    /// <summary>The main button: start, or stop (then a long enough sample is saved).</summary>
    private async void OnPrimary(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        args.Cancel = true;
        if (IsRecording)
        {
            await StopAsync();
        }
        else if (!_enrolling)
        {
            await StartAsync();
        }
    }

    private async Task StartAsync()
    {
        await DiscardAsync();
        SetProblem(null);
        var dir = Path.Combine(_dataDir, "tmp");
        Directory.CreateDirectory(dir);
        _file = Path.Combine(dir, $"voice-sample-{Guid.NewGuid():N}.wav");
        var recorder = new SampleRecorder(_file, Environment.GetEnvironmentVariable("SOZVON_SILENT_CAPTURE") == "1");
        try
        {
            await recorder.StartAsync();
        }
        catch (RecorderStartException e)
        {
            await recorder.StopAsync();
            await DiscardAsync();
            SetProblem(e.AccessDenied ? L("Нет доступа к микрофону") : L("Не получилось начать запись: %@", e.Message), e.AccessDenied);
            ShowState();
            return;
        }
        _recorder = recorder;
        Array.Clear(_levels);
        _ticker.Start();
        ShowState();
    }

    private async Task StopAsync()
    {
        if (_recorder is not { } recorder)
        {
            return;
        }
        _recorder = null;
        _ticker.Stop();
        await recorder.StopAsync();
        Array.Clear(_levels);
        if (recorder.Failure is { } failure)
        {
            await DiscardAsync();
            SetProblem(L("Не получилось начать запись: %@", failure.Message));
        }
        else if (recorder.Elapsed < VoiceSample.MinDuration)
        {
            await DiscardAsync();
            SetProblem(L("Слишком коротко: нужно хотя бы %@ секунд", (int)VoiceSample.MinDuration.TotalSeconds));
        }
        else
        {
            await SaveAsync();
            return;
        }
        ShowSample();
        ShowState();
    }

    /// <summary>The engine makes (or extends) the own voice print from the sample; success closes the dialog.</summary>
    private async Task SaveAsync()
    {
        if (_file is not { } file)
        {
            return;
        }
        _enrolling = true;
        ShowSample();
        ShowState();
        var outcome = await _store.EnrollMeAsync(file, _name, _add);
        await DiscardAsync();
        _enrolling = false;
        if (outcome.IsOk)
        {
            Hide();
            return;
        }
        SetProblem(outcome.Message.Length > 0 ? outcome.Message : L("Не получилось сохранить голос. Подробности в voice.log"));
        ShowState();
    }

    private void SetProblem(string? text, bool microphoneDenied = false)
    {
        _problem.IsOpen = text is not null;
        _problem.Title = text ?? "";
        _problem.ActionButton = microphoneDenied ? MicrophoneSettingsButton() : null;
    }

    private static Button MicrophoneSettingsButton()
    {
        var button = new Button { Content = L("Открыть параметры конфиденциальности") };
        button.Click += (_, _) => Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone") { UseShellExecute = true });
        return button;
    }

    /// <summary>Not while saving: the engine is still reading the recording.</summary>
    private void OnClosing(ContentDialog sender, ContentDialogClosingEventArgs args)
    {
        if (_enrolling)
        {
            args.Cancel = true;
        }
    }

    /// <summary>Stops a recording that is still going and deletes the sample file.</summary>
    private async Task DiscardAsync()
    {
        _ticker.Stop();
        if (_recorder is { } recorder)
        {
            _recorder = null;
            await recorder.StopAsync();
        }
        if (_file is { } file)
        {
            _file = null;
            try
            {
                File.Delete(file);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                Shell.AppHost.Log(e);
            }
        }
    }
}
