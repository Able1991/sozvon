using System.ComponentModel;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Sozvon.App.Strings;
using Sozvon.Core.Calls;
using Sozvon.Core.Foundation;
using Windows.Foundation;
using Windows.System;
using Windows.UI.Core;

namespace Sozvon.App.Calls;

/// <summary>
/// Trim mode, as on the Mac (TrimPanel.swift): the whole call's waveform with the kept range, the playhead and two
/// handles; play, "Listen to the end", the times and what remains, Cancel and Trim; then the confirmation and the
/// engine's progress. The panel takes the keyboard when it opens and when a handle is pressed: ←/→ move the last handle
/// taken by a second, with Shift by ten, and Escape cancels. The state itself is Core's <see cref="TrimState"/>.
/// </summary>
public sealed partial class TrimPanel : UserControl
{
    /// <summary>"Listen to the end" plays this much before the end handle.</summary>
    private const double EndPreview = 5;

    private const double BarWidth = 2, BarGap = 1;

    private TrimState _state = new(0, null);
    private CallPlayer? _player;
    private double _duration;
    private float[]? _peaks;
    private TrimHandle _active = TrimHandle.Start;
    private CancellationTokenSource? _loading;

    // A handle's drag: the handle follows the pointer's movement from where it was pressed, not its position.
    private TrimHandle? _dragging;
    private double _dragFromTime;
    private double _dragFromX;
    private bool _wasPlaying;

    public TrimPanel()
    {
        InitializeComponent();
    }

    /// <summary>Cancel while editing: the panel closes and the player bar comes back.</summary>
    public event EventHandler? Closed;

    /// <summary>"Trim and Transcribe": the card lets the files go and runs the cut.</summary>
    public event EventHandler<(double Start, double End)>? TrimRequested;

    public bool IsWorking => _state.Phase == TrimPhase.Working;

    /// <summary>Opens on the silence hint's handles, or on the whole call.</summary>
    /// <param name="remakes">The call has a transcript: the confirmation says it will be made again.</param>
    public void Open(CallRecord call, CallPlayer player, string ffmpeg, bool remakes)
    {
        Detach();
        _duration = Math.Max(call.DurationSeconds, player.Duration);
        _state = new TrimState(_duration, call.TrimHint);
        _active = TrimHandle.Start;
        _player = player;
        _player.PropertyChanged += OnPlayerChanged;
        ConfirmText.Text = Loc.L(remakes
            ? "Отрезанный звук удалится, вернуть его нельзя. Расшифровка и саммари будут сделаны заново."
            : "Отрезанный звук удалится, вернуть его нельзя.");
        ShowPhase();
        _peaks = null;
        WaveMessage.Text = Loc.L("Строю волну…");
        _ = LoadAsync(call, ffmpeg);
        Layout();
        TakeKeyboard();
    }

    /// <summary>The panel is no longer shown: the waveform's decoding stops, the player is left alone.</summary>
    public void Detach()
    {
        _loading?.Cancel();
        _loading = null;
        if (_player is not null)
        {
            _player.PropertyChanged -= OnPlayerChanged;
            _player = null;
        }
    }

    /// <summary>The cut failed: the handles can be moved again.</summary>
    public void BackToEditing()
    {
        _state.Phase = TrimPhase.Editing;
        ShowPhase();
    }

    private async Task LoadAsync(CallRecord call, string ffmpeg)
    {
        var cancel = _loading = new CancellationTokenSource();
        float[]? peaks;
        try
        {
            peaks = await Task.Run(() => WaveformLoader.PeaksAsync(call, ffmpeg, cancel.Token), cancel.Token);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        if (cancel.IsCancellationRequested)
        {
            return;
        }
        _peaks = peaks;
        WaveMessage.Text = peaks is null ? Loc.L("Волну не получилось построить: звук не читается.") : "";
        Layout();
    }

    /// <summary>The keys go to the handle last taken: the start when the panel opens. Tab reaches the other one.</summary>
    private void TakeKeyboard() => DispatcherQueue.TryEnqueue(() => HandleOf(_active).Focus(FocusState.Programmatic));

    private Control HandleOf(TrimHandle h) => h == TrimHandle.Start ? StartHandle : EndHandle;

    private void OnHandleFocused(object sender, RoutedEventArgs e)
    {
        _active = ReferenceEquals(sender, StartHandle) ? TrimHandle.Start : TrimHandle.End;
        Layout();
    }

    // Layout

    private void OnWaveSizeChanged(object sender, SizeChangedEventArgs e) => Layout();

    private double Width_ => Math.Max(1, WaveArea.ActualWidth);

    private double X(double t) => _duration > 0 ? t / _duration * Width_ : 0;

    private double Time(double x) => _duration > 0 ? Math.Clamp(x / Width_, 0, 1) * _duration : 0;

    private void Layout()
    {
        var w = Width_;
        var h = WaveArea.ActualHeight > 0 ? WaveArea.ActualHeight : WaveArea.Height;
        var start = X(_state.Start);
        var end = X(_state.End);
        CutBefore.Width = Math.Max(0, start);
        CutAfter.Width = Math.Max(0, w - end);
        Place(StartHandle, start);
        Place(EndHandle, end);
        StartKnob.BorderThickness = new Thickness(_active == TrimHandle.Start ? 2 : 0);
        EndKnob.BorderThickness = new Thickness(_active == TrimHandle.End ? 2 : 0);
        AutomationNames();
        DrawBars(w, h, start, end);
        MovePlayhead();
        TimesText.Text = Call.Clock((int)Math.Round(_state.Start), "0:00") + " – " + Call.Clock((int)Math.Round(_state.End), "0:00")
            + " · " + Loc.L("останется %@", Call.Clock((int)Math.Round(_state.End - _state.Start), "0:00"));
    }

    private static void Place(FrameworkElement handle, double x) => handle.Margin = new Thickness(x - handle.Width / 2, 0, 0, 0);

    private void AutomationNames()
    {
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(StartHandle, Loc.L("Начало, %@", Call.Clock((int)Math.Round(_state.Start), "0:00")));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(EndHandle, Loc.L("Конец, %@", Call.Clock((int)Math.Round(_state.End), "0:00")));
    }

    /// <summary>One bar per few pixels, the loudest peak of its group; the kept ones in the accent color.</summary>
    private void DrawBars(double w, double h, double start, double end)
    {
        var kept = new GeometryGroup();
        var cut = new GeometryGroup();
        if (_peaks is { Length: > 0 } peaks)
        {
            var count = Math.Max(1, (int)(w / (BarWidth + BarGap)));
            for (var i = 0; i < count; i++)
            {
                var from = i * peaks.Length / count;
                var to = Math.Max(from + 1, (i + 1) * peaks.Length / count);
                var v = 0f;
                for (var j = from; j < to && j < peaks.Length; j++)
                {
                    v = Math.Max(v, peaks[j]);
                }
                var barHeight = Math.Max(1, v * (h - 4));
                var x = i * (BarWidth + BarGap);
                var bar = new RectangleGeometry { Rect = new Rect(x, (h - barHeight) / 2, BarWidth, barHeight) };
                var middle = x + BarWidth / 2;
                (middle >= start && middle <= end ? kept : cut).Children.Add(bar);
            }
        }
        KeptBars.Data = kept;
        CutBars.Data = cut;
    }

    private void OnPlayerChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(CallPlayer.Position) or nameof(CallPlayer.IsPlaying))
        {
            MovePlayhead();
            PlayIcon.Glyph = _player?.IsPlaying == true ? "" : "";
            var label = Loc.L(_player?.IsPlaying == true ? "Пауза" : "Слушать с начала обрезки");
            ToolTipService.SetToolTip(PlayButton, label);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(PlayButton, label);
        }
    }

    private void MovePlayhead()
    {
        if (_player is not { IsAvailable: true } player || (!player.IsPlaying && player.Position <= 0))
        {
            Playhead.Visibility = Visibility.Collapsed;
            return;
        }
        Playhead.Visibility = Visibility.Visible;
        Playhead.Margin = new Thickness(X(player.Position) - 1, 0, 0, 0);
    }

    // Phases

    private void ShowPhase()
    {
        EditingRow.Visibility = _state.Phase == TrimPhase.Editing ? Visibility.Visible : Visibility.Collapsed;
        ConfirmRow.Visibility = _state.Phase == TrimPhase.Confirming ? Visibility.Visible : Visibility.Collapsed;
        WorkingRow.Visibility = _state.Phase == TrimPhase.Working ? Visibility.Visible : Visibility.Collapsed;
        var editing = _state.Phase == TrimPhase.Editing;
        StartHandle.IsHitTestVisible = editing;
        EndHandle.IsHitTestVisible = editing;
        WaveArea.IsHitTestVisible = _state.Phase != TrimPhase.Working;
    }

    private void OnCancel(object sender, RoutedEventArgs e) => Cancel();

    private void Cancel()
    {
        switch (_state.Cancel())
        {
            case TrimCancelResult.Close:
                _player?.Pause();
                Closed?.Invoke(this, EventArgs.Empty);
                break;
            case TrimCancelResult.BackToEditing:
                ShowPhase();
                TakeKeyboard();
                break;
        }
    }

    private void OnTrim(object sender, RoutedEventArgs e)
    {
        _player?.Pause();
        _state.Phase = TrimPhase.Confirming;
        ShowPhase();
        ConfirmButton.Focus(FocusState.Programmatic);
    }

    private void OnConfirm(object sender, RoutedEventArgs e)
    {
        _state.Phase = TrimPhase.Working;
        ShowPhase();
        _loading?.Cancel(); // ffmpeg must let the files go too
        TrimRequested?.Invoke(this, (_state.Start, _state.End));
    }

    // Playback

    private void OnPlay(object sender, RoutedEventArgs e)
    {
        if (_player is not { } player)
        {
            return;
        }
        if (player.IsPlaying)
        {
            player.Pause();
        }
        else
        {
            player.PlayRange(_state.Start, _state.End);
        }
    }

    private void OnListenToEnd(object sender, RoutedEventArgs e) => ListenToEnd();

    private void ListenToEnd() => _player?.PlayRange(Math.Max(_state.Start, _state.End - EndPreview), _state.End);

    /// <summary>The player follows a moved handle: to the start itself, or to the end's last seconds.</summary>
    private void HandleMoved(TrimHandle h)
    {
        if (_player is not { IsAvailable: true } player)
        {
            return;
        }
        player.Seek(h == TrimHandle.Start ? _state.Start : Math.Max(_state.Start, _state.End - EndPreview));
    }

    // The keyboard

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var shift = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(CoreVirtualKeyStates.Down);
        switch (e.Key)
        {
            case VirtualKey.Left or VirtualKey.Right when (StartHandle.FocusState != FocusState.Unfocused || EndHandle.FocusState != FocusState.Unfocused)
                                                          && _state.Move(_active, e.Key == VirtualKey.Left ? -1 : 1, shift, _duration):
                HandleMoved(_active);
                Layout();
                e.Handled = true;
                break;
            case VirtualKey.Escape when _state.Phase != TrimPhase.Working:
                Cancel();
                e.Handled = true;
                break;
        }
    }

    // The pointer

    private void OnWavePressed(object sender, PointerRoutedEventArgs e)
    {
        if (_state.Phase != TrimPhase.Editing || e.OriginalSource is not FrameworkElement source || IsHandle(source))
        {
            return;
        }
        _player?.Seek(Time(e.GetCurrentPoint(WaveArea).Position.X));
        TakeKeyboard();
    }

    private bool IsHandle(FrameworkElement element) =>
        element == StartHandle || element == EndHandle || element == StartKnob || element == EndKnob;

    private void OnHandlePressed(object sender, PointerRoutedEventArgs e)
    {
        var handle = ReferenceEquals(sender, StartHandle) ? TrimHandle.Start : TrimHandle.End;
        _active = handle;
        _dragging = handle;
        _dragFromTime = _state.Value(handle);
        _dragFromX = e.GetCurrentPoint(WaveArea).Position.X;
        _wasPlaying = _player?.IsPlaying == true;
        _player?.Pause();
        ((UIElement)sender).CapturePointer(e.Pointer);
        HandleOf(handle).Focus(FocusState.Pointer);
        Layout();
        e.Handled = true;
    }

    private void OnHandleMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_dragging is not { } handle)
        {
            return;
        }
        var dx = e.GetCurrentPoint(WaveArea).Position.X - _dragFromX;
        _state.Set(handle, _dragFromTime + dx / Width_ * _duration, _duration);
        HandleMoved(handle);
        Layout();
        e.Handled = true;
    }

    private void OnHandleReleased(object sender, PointerRoutedEventArgs e)
    {
        ((UIElement)sender).ReleasePointerCapture(e.Pointer);
        EndDrag();
        e.Handled = true;
    }

    private void OnHandleCaptureLost(object sender, PointerRoutedEventArgs e) => EndDrag();

    /// <summary>When it was playing as the drag began, the moved handle is heard: the start plays on, the end plays its last seconds.</summary>
    private void EndDrag()
    {
        if (_dragging is not { } handle)
        {
            return;
        }
        _dragging = null;
        if (!_wasPlaying)
        {
            return;
        }
        if (handle == TrimHandle.Start)
        {
            _player?.PlayRange(_state.Start, _state.End);
        }
        else
        {
            ListenToEnd();
        }
    }

    /// <summary>
    /// "Первые 6 минут тишина.", "Последние 4 минуты тишина.", "В начале 6 минут и в конце 4 минуты тишина.", as on the Mac.
    /// </summary>
    public static string HintText(TrimHint hint)
    {
        static string Minutes(int n) => Plural.Count(n, ("минута", "минуты", "минут"), ("minute", "minutes"), Loc.IsRussian);
        static bool One(int n) => n % 10 == 1 && n % 100 != 11; // "21 минута": the singular phrase
        var (head, tail) = (hint.HeadMinutes, hint.TailMinutes);
        if (head > 0 && tail > 0)
        {
            return Loc.L("В начале %@ и в конце %@ тишина.", Minutes(head), Minutes(tail));
        }
        if (head > 0)
        {
            return head == 1 ? Loc.L("Первая минута тишина.")
                : One(head) ? Loc.L("Первая %@ тишина.", Minutes(head)) : Loc.L("Первые %@ тишина.", Minutes(head));
        }
        return tail == 1 ? Loc.L("Последняя минута тишина.")
            : One(tail) ? Loc.L("Последняя %@ тишина.", Minutes(tail)) : Loc.L("Последние %@ тишина.", Minutes(tail));
    }
}
