using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Windows.ApplicationModel.DataTransfer;
using static Sozvon.App.Strings.Loc;

namespace Sozvon.App.Calls;

public sealed partial class CallDetailView : UserControl
{
    private const string PlayGlyph = "", PauseGlyph = "";
    private CallDetailViewModel? _viewModel;
    private List<TranscriptLine> _matches = [];
    private int _matchIndex;

    public CallDetailView()
    {
        InitializeComponent();
        KeyboardAccelerators.Add(FindAccelerator());
    }

    public CallDetailViewModel? ViewModel
    {
        get => _viewModel;
        set
        {
            if (_viewModel is not null)
            {
                _viewModel.Player.PropertyChanged -= OnPlayerChanged;
            }
            _viewModel = value;
            Bindings.Update();
            if (value is not null)
            {
                value.Player.PropertyChanged += OnPlayerChanged;
                ShowCall(value);
            }
        }
    }

    public static string TaskGlyph(bool done) => done ? "" : "";

    private void ShowCall(CallDetailViewModel call)
    {
        StatusBar.Title = call.BannerText;
        StatusBar.IsOpen = call.BannerKind != CallBannerKind.None;
        StatusBar.Severity = call.BannerKind switch
        {
            CallBannerKind.Critical => InfoBarSeverity.Error,
            CallBannerKind.Caution => InfoBarSeverity.Warning,
            _ => InfoBarSeverity.Informational,
        };
        NoSummaryText.Visibility = call.HasSummary ? Visibility.Collapsed : Visibility.Visible;
        NoTranscriptText.Visibility = call.HasTranscript ? Visibility.Collapsed : Visibility.Visible;
        ShowFolderItem.IsEnabled = call.CanOpenFolder;
        LogItem.IsEnabled = call.HasLog;
        OpenTranscriptItem.IsEnabled = call.HasTranscriptFile;
        DiskSizeItem.Text = call.DiskSize;
        DiskSizeItem.Visibility = call.DiskSize.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        FindBox.Text = "";
        Tabs.SelectedItem = SummaryTab;

        var player = call.Player;
        BackButton.IsEnabled = PlayButton.IsEnabled = ForwardButton.IsEnabled = player.IsAvailable;
        PositionSlider.Visibility = player.IsAvailable ? Visibility.Visible : Visibility.Collapsed;
        UnavailableText.Visibility = player.IsAvailable ? Visibility.Collapsed : Visibility.Visible;
        UnavailableText.Text = player.Unavailable;
        ShowPlayState(false);
        ShowSpeed(player.RateIndex);
        SpeedPanel.Visibility = player.IsAvailable ? Visibility.Visible : Visibility.Collapsed;
        UpdatePosition(player);
    }

    private void OnPlayerChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (sender is not CallPlayer player)
        {
            return;
        }
        switch (e.PropertyName)
        {
            case nameof(CallPlayer.IsPlaying):
                ShowPlayState(player.IsPlaying);
                break;
            case nameof(CallPlayer.Error) when player.Error.Length > 0:
                UnavailableText.Text = L("Запись недоступна") + ": " + player.Error;
                UnavailableText.Visibility = Visibility.Visible;
                PositionSlider.Visibility = Visibility.Collapsed;
                break;
            default:
                UpdatePosition(player);
                break;
        }
    }

    private void ShowPlayState(bool isPlaying)
    {
        PlayIcon.Glyph = isPlaying ? PauseGlyph : PlayGlyph;
        var name = L(isPlaying ? "Пауза" : "Воспроизвести");
        ToolTipService.SetToolTip(PlayButton, name);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(PlayButton, name);
    }

    private void UpdatePosition(CallPlayer player)
    {
        PositionText.Text = CallFormat.Clock(player.Position);
        DurationText.Text = CallFormat.Clock(player.Duration);
        PositionSlider.Maximum = Math.Max(player.Duration, 1);
        PositionSlider.Value = player.Position;
    }

    private void OnSliderChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        if (ViewModel?.Player is { } player && Math.Abs(e.NewValue - player.Position) > 1)
        {
            player.Seek(e.NewValue);
        }
    }

    private void OnSpeedClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel?.Player is { } player)
        {
            player.RateIndex = Array.IndexOf([Speed1, Speed15, Speed2], sender);
            ShowSpeed(player.RateIndex);
        }
    }

    private void ShowSpeed(int rateIndex)
    {
        ToggleButton[] buttons = [Speed1, Speed15, Speed2];
        for (var i = 0; i < buttons.Length; i++)
        {
            buttons[i].IsChecked = i == rateIndex;
        }
    }

    private void OnTabChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        var showSummary = sender.SelectedItem == SummaryTab;
        SummaryPane.Visibility = showSummary ? Visibility.Visible : Visibility.Collapsed;
        TranscriptPane.Visibility = showSummary ? Visibility.Collapsed : Visibility.Visible;
    }

    private void OnLineClick(object sender, ItemClickEventArgs e)
    {
        if (ViewModel?.Player is { IsAvailable: true } player && e.ClickedItem is TranscriptLine line)
        {
            player.Seek(line.Start);
        }
    }

    private void OnFindChanged(object sender, TextChangedEventArgs e)
    {
        var query = FindBox.Text.Trim();
        _matches = query.Length == 0 || ViewModel is null
            ? []
            : ViewModel.Lines.Where(l => l.Text.Contains(query, StringComparison.CurrentCultureIgnoreCase)).ToList();
        _matchIndex = 0;
        ShowMatch();
    }

    private void OnFindNext(object sender, RoutedEventArgs e) => MoveMatch(1);

    private void OnFindPrevious(object sender, RoutedEventArgs e) => MoveMatch(-1);

    private void MoveMatch(int step)
    {
        if (_matches.Count > 0)
        {
            _matchIndex = (_matchIndex + step + _matches.Count) % _matches.Count;
            ShowMatch();
        }
    }

    private void ShowMatch()
    {
        FindCount.Text = _matches.Count > 0 ? L("%d из %d", _matchIndex + 1, _matches.Count) : "";
        if (_matches.Count > 0)
        {
            TranscriptList.SelectedItem = _matches[_matchIndex];
            TranscriptList.ScrollIntoView(_matches[_matchIndex]);
        }
    }

    private Microsoft.UI.Xaml.Input.KeyboardAccelerator FindAccelerator()
    {
        var accelerator = new Microsoft.UI.Xaml.Input.KeyboardAccelerator
        {
            Key = Windows.System.VirtualKey.F,
            Modifiers = Windows.System.VirtualKeyModifiers.Control,
        };
        accelerator.Invoked += (_, args) =>
        {
            Tabs.SelectedItem = TranscriptTab;
            FindBox.Focus(FocusState.Programmatic);
            args.Handled = true;
        };
        return accelerator;
    }

    private void OnCopySummary(object sender, RoutedEventArgs e) => CopyText(ViewModel?.Summary);

    private void OnCopyTranscript(object sender, RoutedEventArgs e) => CopyText(ViewModel?.Transcript);

    private static void CopyText(string? text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return;
        }
        var package = new DataPackage();
        package.SetText(text);
        Clipboard.SetContent(package);
    }

    private void OnOpenTranscript(object sender, RoutedEventArgs e)
    {
        if (ViewModel is { HasTranscriptFile: true } call)
        {
            OpenInShell(call.TranscriptPath);
        }
    }

    private void OnOpenLog(object sender, RoutedEventArgs e)
    {
        if (ViewModel is { HasLog: true } call)
        {
            OpenInShell(call.LogPath);
        }
    }

    private void OnShowFolder(object sender, RoutedEventArgs e)
    {
        if (ViewModel is { CanOpenFolder: true } call)
        {
            Process.Start("explorer.exe", $"\"{Path.GetFullPath(call.Call.Folder)}\"");
        }
    }

    private static void OpenInShell(string path) =>
        Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
}
