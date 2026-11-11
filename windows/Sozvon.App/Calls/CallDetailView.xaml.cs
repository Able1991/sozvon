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
    private CallNote? _deletedNote;
    private (string Id, double Offset)? _shown;

    /// <summary>The tab last chosen, kept from call to call as on the Mac.</summary>
    private bool _wantsTranscript;

    public CallDetailView()
    {
        InitializeComponent();
    }

    /// <summary>
    /// The find bar has its own close button and Esc; the text box's built-in clear cross next to it would be a second
    /// cross. The template shows it through a visual state, so it is held at zero width rather than collapsed.
    /// </summary>
    private static void RemoveClearButton(TextBox box)
    {
        if (FindChild(box, "DeleteButton") is Button clear)
        {
            clear.MaxWidth = 0;
            clear.IsTabStop = false;
            clear.IsHitTestVisible = false;
        }
    }

    private static DependencyObject? FindChild(DependencyObject parent, string name)
    {
        for (var i = 0; i < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(parent); i++)
        {
            var child = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(parent, i);
            if (child is FrameworkElement { Name: var childName } && childName == name)
            {
                return child;
            }
            if (FindChild(child, name) is { } found)
            {
                return found;
            }
        }
        return null;
    }

    public CallDetailViewModel? ViewModel
    {
        get => _viewModel;
        set
        {
            if (_viewModel is not null)
            {
                _viewModel.Player.PropertyChanged -= OnPlayerChanged;
                _viewModel.Actions.Voices.Changed -= OnVoicesChanged;
            }
            CloseFind();
            if (_viewModel is not null)
            {
                _shown = (_viewModel.Call.Id, Scroller.VerticalOffset);
            }
            _viewModel = value;
            Bindings.Update();
            if (value is not null)
            {
                value.Player.PropertyChanged += OnPlayerChanged;
                value.Actions.Voices.Changed += OnVoicesChanged;
                ShowCall(value);
                // The same call read again after an edit keeps its place on the page.
                if (_shown is { } shown && shown.Id == value.Call.Id)
                {
                    DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,
                        () => Scroller.ChangeView(null, shown.Offset, null, disableAnimation: true));
                }
            }
        }
    }

    private bool ShowsTranscript => TranscriptContent.Visibility == Visibility.Visible;

    /// <summary>"Move to Recycle Bin" in the More menu: the page deletes it and picks the next call.</summary>
    public event EventHandler? TrashRequested;

    /// <summary>"Undo delete" in the More menu: the page brings the last deleted call back.</summary>
    public event EventHandler? UndoTrashRequested;

    /// <summary>A ticked or an empty checkbox, as the task's "- [x]" or "- [ ]" says.</summary>
    public static string TaskGlyph(bool done) => done ? "" : "";

    /// <summary>Ctrl+F: the find bar on the Transcript tab. False on the Summary tab, where Ctrl+F searches all calls.</summary>
    public bool OpenFind()
    {
        if (ViewModel is null || !ShowsTranscript)
        {
            return false;
        }
        FindBar.Visibility = Visibility.Visible;
        // The bar starts collapsed, so the box gets its template only now.
        FindBox.ApplyTemplate();
        RemoveClearButton(FindBox);
        FindBox.Focus(FocusState.Keyboard);
        FindBox.SelectAll();
        return true;
    }

    /// <summary>The menu shows the shortcuts too, as the Mac's Edit menu does; it finds only on the Transcript tab.</summary>
    private void OnMoreOpening(object? sender, object e)
    {
        FindItem.IsEnabled = ShowsTranscript;
        UndoTrashItem.Visibility = ViewModel?.Actions.CanUndoTrash == true ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnFindItem(object sender, RoutedEventArgs e) => OpenFind();

    private void ShowCall(CallDetailViewModel call)
    {
        ShowBanner(call);
        ShowVoices(call);
        NoSummaryText.Visibility = call.HasSummary ? Visibility.Collapsed : Visibility.Visible;
        NoTranscriptText.Visibility = call.HasTranscript ? Visibility.Collapsed : Visibility.Visible;
        ShowFolderItem.IsEnabled = call.CanOpenFolder;
        LogItem.IsEnabled = call.HasLog;
        OpenTranscriptItem.IsEnabled = call.HasTranscriptFile;
        TranscribeItem.Text = call.TranscribeTitle;
        TranscribeItem.Visibility = call.TranscribeTitle.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        RemoveFromQueueItem.Visibility = call.CanRemoveFromQueue ? Visibility.Visible : Visibility.Collapsed;
        ResummarizeItem.Visibility = call.HasTranscript && call.Actions.CanTranscribe ? Visibility.Visible : Visibility.Collapsed;
        ResummarizeItem.IsEnabled = call.CanResummarize;
        TrashItem.Visibility = TrashSeparator.Visibility = call.CanOpenFolder ? Visibility.Visible : Visibility.Collapsed;
        TrashItem.IsEnabled = !call.Actions.IsBusy(call.Call);
        DiskSizeItem.Text = call.DiskSize;
        DiskSizeItem.Visibility = DiskSizeSeparator.Visibility = call.DiskSize.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        ParticipantsLine.Visibility = call.Participants.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        ShowNotes(call);
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

    private async void OnRenameRequested(object? sender, TranscriptRow row)
    {
        if (ViewModel is not { } call)
        {
            return;
        }
        var dialog = new RenameSpeakerDialog(row, call.Rows, Suggestions(call, row.Speaker)) { XamlRoot = XamlRoot, RequestedTheme = Shell.Dialogs.ThemeOf(XamlRoot) };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || dialog.Action is not { } action)
        {
            return;
        }
        var actions = call.Actions;
        var error = action switch
        {
            RenameAction.Swap swap => actions.SwapSpeakers(call.Call, row.Speaker, swap.With),
            RenameAction.Line line => actions.ReassignLine(call.Call, row, line.To),
            _ => actions.RenameSpeaker(call.Call, row.Speaker, action.Name),
        };
        await ShowProblem(error);
        // The speaker was named precisely: learn the voice from this call (a single line is not enough to go on).
        if (error is null && action is not RenameAction.Line)
        {
            var names = action is RenameAction.Swap ? new[] { action.Name, row.Speaker } : [action.Name];
            await actions.RememberVoicesAsync(call.Call, names);
        }
    }

    private async void OnRememberVoiceRequested(object? sender, TranscriptRow row)
    {
        if (ViewModel is { } call)
        {
            await call.Actions.RememberVoicesAsync(call.Call, [row.Speaker]);
        }
    }

    /// <summary>Fix the word; then, as on the Mac, offer to fix it in new transcripts of the project too.</summary>
    private async void OnFixRequested(object? sender, TranscriptRow row)
    {
        if (ViewModel is not { } call)
        {
            return;
        }
        var dialog = new FixWordDialog(row) { XamlRoot = XamlRoot, RequestedTheme = Shell.Dialogs.ThemeOf(XamlRoot) };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary)
        {
            return;
        }
        var (wrong, right) = (dialog.Wrong, dialog.Right);
        if (call.Actions.FixWord(call.Call, row, wrong, right) is { } error)
        {
            await ShowProblem(error);
            return;
        }
        var project = call.Actions.ProjectOf(call.Call);
        var learn = new ContentDialog
        {
            XamlRoot = XamlRoot,
            RequestedTheme = Shell.Dialogs.ThemeOf(XamlRoot),
            Title = project is null ? L("Запоминать для всех звонков?") : L("Запоминать для проекта «%@»?", project.ShortTitle),
            Content = new TextBlock { Text = L("В новых расшифровках «%@» будет сразу заменяться на «%@».", wrong, right), TextWrapping = TextWrapping.Wrap },
            PrimaryButtonText = L("Запоминать"),
            CloseButtonText = L("Не надо"),
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await learn.ShowAsync() == ContentDialogResult.Primary)
        {
            await ShowProblem(call.Actions.Remember(wrong, right, project));
        }
    }

    private async Task ShowProblem(string? problem)
    {
        if (problem is not null && XamlRoot is { } root)
        {
            await new ContentDialog { XamlRoot = root, RequestedTheme = Shell.Dialogs.ThemeOf(root), Title = problem, CloseButtonText = "OK" }.ShowAsync();
        }
    }

    /// <summary>
    /// Names to offer: the other people speaking in this transcript, the user, the call's participants, then the
    /// people of its project; each once, without generic labels and without the speaker itself.
    /// </summary>
    private static List<string> Suggestions(CallDetailViewModel call, string speaker)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { speaker };
        var named = call.Rows.Select(r => r.Speaker).Where(s => !Voices.IsGenericLabel(s, call.Me));
        var people = call.Call.People.Concat(call.Actions.ProjectOf(call.Call)?.People ?? []);
        return named.Append(call.Me).Concat(people)
            .Select(Transcript.CleanSpeaker).OfType<string>()
            .Where(seen.Add)
            .Take(16)
            .ToList();
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

    private void ShowNotes(CallDetailViewModel call)
    {
        call.Notes.CollectionChanged += (_, _) => ShowNoNotes();
        NotesSection.Visibility = call.CanEditNotes || call.Notes.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        AddNoteButton.Visibility = call.CanEditNotes ? Visibility.Visible : Visibility.Collapsed;
        NoteBox.Text = "";
        NoteBox.Visibility = NoteError.Visibility = NoteDeleted.Visibility = Visibility.Collapsed;
        _deletedNote = null;
        ShowNoNotes();
    }

    private void ShowNoNotes()
    {
        var empty = ViewModel is { Notes.Count: 0 };
        NotesList.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
        NoNotesText.Visibility = empty && NoteBox.Visibility == Visibility.Collapsed && NoteDeleted.Visibility == Visibility.Collapsed
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    /// <summary>"Add": the field appears; Enter adds, Esc cancels.</summary>
    private void OnAddNote(object sender, RoutedEventArgs e)
    {
        NoteDeleted.Visibility = Visibility.Collapsed;
        NoteBox.Visibility = Visibility.Visible;
        ShowNoNotes();
        NoteBox.Focus(FocusState.Programmatic);
    }

    private void OnNoteKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter)
        {
            e.Handled = true;
            if (NoteBox.Text.Trim().Length == 0)
            {
                CancelNote();
            }
            else if (ViewModel?.AddNote(NoteBox.Text) is { } error)
            {
                NoteError.Text = error;
                NoteError.Visibility = Visibility.Visible;
            }
            else
            {
                CancelNote();
            }
        }
        else if (e.Key == VirtualKey.Escape)
        {
            e.Handled = true;
            CancelNote();
        }
    }

    private void CancelNote()
    {
        NoteBox.Text = "";
        NoteBox.Visibility = NoteError.Visibility = Visibility.Collapsed;
        ShowNoNotes();
    }

    private void OnCopyNote(object sender, RoutedEventArgs e) => CopyText(((sender as FrameworkElement)?.Tag as NoteRow)?.Text);

    /// <summary>Deletes at once, as on the Mac; "Вернуть" adds it back with its text, time and source.</summary>
    private void OnDeleteNote(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is NoteRow row && ViewModel is { } call)
        {
            if (call.DeleteNote(row))
            {
                _deletedNote = row.Note;
                NoteDeleted.Visibility = Visibility.Visible;
            }
            else
            {
                NoteError.Text = L("Не получилось удалить заметку");
                NoteError.Visibility = Visibility.Visible;
            }
            ShowNoNotes();
        }
    }

    private void OnUndoDeleteNote(object sender, RoutedEventArgs e)
    {
        if (_deletedNote is { } note && ViewModel is { } call)
        {
            var error = call.AddNote(note.Text, note.Source.Length > 0 ? note.Source : "app", note.Date);
            NoteError.Text = error ?? "";
            NoteError.Visibility = error is null ? Visibility.Collapsed : Visibility.Visible;
        }
        _deletedNote = null;
        NoteDeleted.Visibility = Visibility.Collapsed;
        ShowNoNotes();
    }

    /// <summary>The status banner: progress, the queue, a failed run, a summary older than the transcript.</summary>
    private void ShowBanner(CallDetailViewModel call)
    {
        var banner = call.Banner;
        StatusBar.IsOpen = banner.Kind != CallBannerKind.None;
        StatusBar.Title = banner.Title;
        StatusBar.Message = banner.Message;
        StatusBar.Severity = banner.Kind switch
        {
            CallBannerKind.Critical => InfoBarSeverity.Error,
            CallBannerKind.Caution => InfoBarSeverity.Warning,
            _ => InfoBarSeverity.Informational,
        };
        StatusBar.Content = banner.Progress ? new ProgressBar { IsIndeterminate = true, Margin = new Thickness(0, 0, 0, 12) } : null;
        StatusBar.ActionButton = banner.Action switch
        {
            CallBannerAction.RemoveFromQueue => BannerButton(L("Убрать из очереди"), () => call.Actions.RemoveFromQueue(call.Call)),
            CallBannerAction.Retranscribe => BannerButton(L("Расшифровать заново…"), () => call.Actions.Retranscribe(call.Call)),
            CallBannerAction.Resummarize => BannerButton(L("Обновить саммари"), () => call.Actions.Resummarize(call.Call)),
            _ => null,
        };
    }

    /// <summary>"Names right?" with the speakers to remember, and what the last voice run did.</summary>
    private void ShowVoices(CallDetailViewModel call)
    {
        VoicesBar.IsOpen = call.OffersVoices;
        VoicesBar.Visibility = call.OffersVoices ? Visibility.Visible : Visibility.Collapsed;
        VoicesBar.Message = L("Запомни голоса (%@), и в следующих звонках имена подставятся сами.", string.Join(", ", call.Unsaved));
        var enroller = call.Actions.Voices;
        RememberVoicesButton.IsEnabled = !enroller.IsBusy;
        var notice = enroller.IsBusy ? (Ok: true, Text: L("Запоминаю голос…")) : enroller.Notice;
        VoiceNotice.Visibility = notice is null ? Visibility.Collapsed : Visibility.Visible;
        VoiceNotice.IsOpen = notice is not null;
        VoiceNotice.Title = notice?.Text ?? "";
        VoiceNotice.Severity = enroller.IsBusy ? InfoBarSeverity.Informational : notice is { Ok: false } ? InfoBarSeverity.Warning : InfoBarSeverity.Success;
    }

    private void OnVoicesChanged(object? sender, EventArgs e)
    {
        if (ViewModel is { } call)
        {
            ShowVoices(call);
        }
    }

    private void OnVoicesNotNow(InfoBar sender, object args)
    {
        if (ViewModel is { } call)
        {
            call.Actions.VoicesDismissed.Add(call.Call.Id);
            ShowVoices(call);
        }
    }

    private async void OnRememberVoices(object sender, RoutedEventArgs e)
    {
        if (ViewModel is { } call)
        {
            await call.Actions.RememberVoicesAsync(call.Call, call.Unsaved);
        }
    }

    private static Button BannerButton(string text, Action action)
    {
        var button = new Button { Content = text };
        button.Click += (_, _) => action();
        return button;
    }

    private void OnRetranscribe(object sender, RoutedEventArgs e)
    {
        if (ViewModel is { } call)
        {
            call.Actions.Retranscribe(call.Call);
        }
    }

    private void OnRemoveFromQueue(object sender, RoutedEventArgs e)
    {
        if (ViewModel is { } call)
        {
            call.Actions.RemoveFromQueue(call.Call);
        }
    }

    private void OnResummarize(object sender, RoutedEventArgs e)
    {
        if (ViewModel is { } call)
        {
            call.Actions.Resummarize(call.Call);
        }
    }

    private void OnTrash(object sender, RoutedEventArgs e) => AfterMoreMenuCloses(() => TrashRequested?.Invoke(this, EventArgs.Empty));

    private void OnUndoTrash(object sender, RoutedEventArgs e) => AfterMoreMenuCloses(() => UndoTrashRequested?.Invoke(this, EventArgs.Empty));

    /// <summary>The card changes or goes away after these commands: the menu finishes closing first.</summary>
    private void AfterMoreMenuCloses(Action action)
    {
        if (!MoreMenu.IsOpen)
        {
            action();
            return;
        }
        void Once(object? sender, object e)
        {
            MoreMenu.Closed -= Once;
            DispatcherQueue.TryEnqueue(() => action());
        }
        MoreMenu.Closed += Once;
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
