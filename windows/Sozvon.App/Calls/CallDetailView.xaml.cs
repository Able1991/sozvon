using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Sozvon.Core.Calls;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;
using Windows.UI.Core;
using static Sozvon.App.Strings.Loc;

namespace Sozvon.App.Calls;

public sealed partial class CallDetailView : UserControl
{
    private const string PlayGlyph = "\uF5B0", PauseGlyph = "\uF8AE";
    private CallDetailViewModel? _viewModel;
    private List<TranscriptFind.Match> _found = [];
    private int _foundIndex;
    private List<TranscriptRow> _marked = [];
    private TranscriptRow? _playing;

    /// <summary>The tab last chosen, kept from call to call as on the Mac.</summary>
    private bool _wantsTranscript;

    public CallDetailView()
    {
        InitializeComponent();
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
            CloseFind();
            _viewModel = value;
            Bindings.Update();
            if (value is not null)
            {
                value.Player.PropertyChanged += OnPlayerChanged;
                ShowCall(value);
            }
        }
    }

    private bool ShowsTranscript => TranscriptContent.Visibility == Visibility.Visible;

    public static string TaskGlyph(bool done) => done ? "" : "";

    /// <summary>Ctrl+F: the find bar on the Transcript tab. False on the Summary tab, where Ctrl+F searches all calls.</summary>
    public bool OpenFind()
    {
        if (ViewModel is null || !ShowsTranscript)
        {
            return false;
        }
        FindBar.Visibility = Visibility.Visible;
        FindBox.Focus(FocusState.Keyboard);
        FindBox.SelectAll();
        return true;
    }

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
        DiskSizeItem.Visibility = DiskSizeSeparator.Visibility = call.DiskSize.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        // The chosen tab, or the other one when this call doesn't have it.
        var transcript = (_wantsTranscript || !call.HasSummary) && (call.HasTranscript || !call.HasSummary);
        var wanted = _wantsTranscript;
        Tabs.SelectedItem = transcript ? TranscriptTab : SummaryTab;
        ShowTab(transcript);
        _wantsTranscript = wanted;
        Scroller.ChangeView(null, 0, null, disableAnimation: true);

        // The player only for a call whose audio is there, as on the Mac; the page keeps room for it.
        var player = call.Player;
        PlayerBar.Visibility = player.IsAvailable ? Visibility.Visible : Visibility.Collapsed;
        Page.Padding = new Thickness(24, 16, 24, player.IsAvailable ? PlayerBar.Height + PlayerBar.Margin.Bottom + 24 : 24);
        PositionSlider.Visibility = Visibility.Visible;
        UnavailableText.Visibility = Visibility.Collapsed;
        ShowPlayState(false);
        ShowSpeed(player.RateIndex);
        UpdatePosition(player);
        _playing = null;
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
                FollowPlayingLine(player);
                break;
            case nameof(CallPlayer.Error) when player.Error.Length > 0:
                UnavailableText.Text = L("Запись недоступна") + ": " + player.Error;
                UnavailableText.Visibility = Visibility.Visible;
                PositionSlider.Visibility = Visibility.Collapsed;
                break;
            case nameof(CallPlayer.Position):
                UpdatePosition(player);
                ShowPlayingLine(player);
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
        RadioMenuFlyoutItem[] items = [Speed1, Speed15, Speed2];
        for (var i = 0; i < items.Length; i++)
        {
            items[i].IsChecked = i == rateIndex;
        }
        SpeedButton.Content = items[rateIndex].Text;
    }

    /// <summary>The paragraph being played gets the accent row; while playing, the page keeps it in view.</summary>
    private void ShowPlayingLine(CallPlayer player)
    {
        if (ViewModel is not { } call || call.Rows.Count == 0)
        {
            return;
        }
        var index = Transcript.LineIndex(player.Position, call.Starts);
        var row = index is { } i ? call.Rows[i] : null;
        if (row == _playing)
        {
            return;
        }
        if (_playing is not null)
        {
            _playing.IsPlaying = false;
        }
        _playing = row;
        if (row is null)
        {
            return;
        }
        row.IsPlaying = true;
        FollowPlayingLine(player);
    }

    private void FollowPlayingLine(CallPlayer player)
    {
        if (!player.IsPlaying || !ShowsTranscript || _playing is not { } row)
        {
            return;
        }
        if (TranscriptRepeater.TryGetElement(row.Ordinal) is FrameworkElement element)
        {
            // Scrolls only as much as needed, keeping the line clear of the player floating below.
            var below = PlayerBar.Height + PlayerBar.Margin.Bottom + 16;
            element.StartBringIntoView(new BringIntoViewOptions
            {
                AnimationDesired = true,
                TargetRect = new Windows.Foundation.Rect(0, 0, element.ActualWidth, element.ActualHeight + below),
            });
        }
        else
        {
            BringRowToCentre(row.Ordinal);
        }
    }

    private void OnTabChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        var transcript = sender.SelectedItem == TranscriptTab;
        _wantsTranscript = transcript;
        ShowTab(transcript);
    }

    /// <summary>Changing the tab closes the find bar, as changing the call does.</summary>
    private void ShowTab(bool transcript)
    {
        CloseFind();
        SummaryContent.Visibility = transcript ? Visibility.Collapsed : Visibility.Visible;
        TranscriptContent.Visibility = transcript ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnRowActivated(object? sender, TranscriptRow row)
    {
        if (ViewModel?.Player is { IsAvailable: true } player)
        {
            player.PlayFrom(row.Line.Start);
        }
    }

    private void OnFindChanged(object sender, TextChangedEventArgs e)
    {
        _found = ViewModel is null ? [] : TranscriptFind.Matches(FindBox.Text, ViewModel.Rows.Select(r => r.Line.Text).ToList());
        _foundIndex = 0;
        ShowFound(scroll: true);
    }

    /// <summary>Enter: the next match, Shift+Enter: the previous one, Esc: close.</summary>
    private void OnFindKeyDown(object sender, KeyRoutedEventArgs e)
    {
        switch (e.Key)
        {
            case VirtualKey.Enter:
                var shift = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(CoreVirtualKeyStates.Down);
                Step(shift ? -1 : 1);
                e.Handled = true;
                break;
            case VirtualKey.Escape:
                CloseFind();
                e.Handled = true;
                break;
        }
    }

    private void OnFindNext(object sender, RoutedEventArgs e) => Step(1);

    private void OnFindPrevious(object sender, RoutedEventArgs e) => Step(-1);

    private void OnFindClose(object sender, RoutedEventArgs e) => CloseFind();

    private void Step(int delta)
    {
        if (_found.Count > 0)
        {
            _foundIndex = TranscriptFind.Step(_foundIndex, delta, _found.Count);
            ShowFound(scroll: true);
        }
    }

    private void CloseFind()
    {
        if (FindBar.Visibility == Visibility.Collapsed && _found.Count == 0)
        {
            return;
        }
        FindBar.Visibility = Visibility.Collapsed;
        FindBox.Text = "";
        _found = [];
        ShowFound(scroll: false);
    }

    /// <summary>Marks the matches on their rows, the counter "3 из 12", and scrolls the current one to the centre.</summary>
    private void ShowFound(bool scroll)
    {
        foreach (var row in _marked)
        {
            row.Found = [];
            row.CurrentFound = null;
        }
        _marked = [];
        var current = _found.Count > 0 ? _found[_foundIndex] : null;
        if (ViewModel is { } call)
        {
            foreach (var line in _found.GroupBy(m => m.Line))
            {
                var row = call.Rows[line.Key];
                row.CurrentFound = current?.Line == line.Key ? current : null;
                row.Found = line.ToList();
                _marked.Add(row);
            }
        }
        FindCount.Text = FindBox.Text.Trim().Length == 0 ? ""
            : _found.Count == 0 ? L("Ничего не найдено")
            : L("%d из %d", _foundIndex + 1, _found.Count);
        FindPrevious.IsEnabled = FindNext.IsEnabled = _found.Count > 0;
        if (scroll && current is not null)
        {
            BringRowToCentre(current.Line);
        }
    }

    private void BringRowToCentre(int index)
    {
        if (TranscriptRepeater.GetOrCreateElement(index) is { } element)
        {
            element.UpdateLayout();
            element.StartBringIntoView(new BringIntoViewOptions { VerticalAlignmentRatio = 0.5, AnimationDesired = true });
        }
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
