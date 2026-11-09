using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using WinRT.Interop;

namespace Sozvon.App.Capsule;

/// <summary>The floating capsule: always on top, never takes focus, draws a <see cref="CapsuleModel"/>.</summary>
public sealed partial class CapsuleWindow : Window
{
    private const int LogicalHeight = 44, MinimumWidth = 120, Edge = 16;
    private const int BarsPerSide = 11, BarWidth = 3, BarStep = 6, WaveHeight = 28, MinBar = 3;
    private const double RestOpacity = 0.86;

    private readonly nint _hwnd;
    private readonly SolidColorBrush _meBrush = new(ColorHelper.FromArgb(255, 0x0F, 0x6C, 0xBD));
    private readonly SolidColorBrush _themBrush = new(ColorHelper.FromArgb(255, 0xC4, 0x50, 0x1B));
    private readonly Rectangle[] _me = new Rectangle[BarsPerSide];
    private readonly Rectangle[] _them = new Rectangle[BarsPerSide];
    private readonly double[] _meHistory = new double[BarsPerSide];
    private readonly double[] _themHistory = new double[BarsPerSide];
    private CapsuleModel _model = new(CapsulePhase.Idle);
    private bool _dragging;
    private NativeWindow.Point _dragCursor;
    private Windows.Graphics.PointInt32 _dragWindow;

    private readonly HashSet<UIElement> _shown = [];
    private bool _hovered;

    public event EventHandler? RecordClicked;
    public event EventHandler? StopClicked;
    public event EventHandler? MarkClicked;
    public event EventHandler? PrimaryClicked;
    public event EventHandler? SecondaryClicked;
    public event EventHandler? HideRequested;

    /// <summary>The user finished dragging the capsule to this position.</summary>
    public event EventHandler<Windows.Graphics.PointInt32>? Moved;

    public CapsuleWindow()
    {
        InitializeComponent();
        _hwnd = WindowNative.GetWindowHandle(this);
        var presenter = OverlappedPresenter.CreateForContextMenu();
        presenter.IsAlwaysOnTop = true;
        AppWindow.SetPresenter(presenter);
        AppWindow.IsShownInSwitchers = false;
        NativeWindow.MakeNonActivating(_hwnd);
        NativeWindow.RoundCorners(_hwnd);
        NativeWindow.RefuseActivationOnClick(_hwnd);

        HideItem.Text = CapsuleText.Hide;
        ToolTipService.SetToolTip(MarkButton, CapsuleText.Mark + " (Ctrl+Alt+I)");
        ToolTipService.SetToolTip(StopButton, CapsuleText.Stop);
        RecordButton.Click += (_, _) => RecordClicked?.Invoke(this, EventArgs.Empty);
        StopButton.Click += (_, _) => StopClicked?.Invoke(this, EventArgs.Empty);
        MarkButton.Click += (_, _) => MarkClicked?.Invoke(this, EventArgs.Empty);
        ActionButton.Click += (_, _) => PrimaryClicked?.Invoke(this, EventArgs.Empty);
        SecondButton.Click += (_, _) => SecondaryClicked?.Invoke(this, EventArgs.Empty);
        BuildWave();
        Render(_model);
    }

    public void ShowWithoutFocus()
    {
        AppWindow.Show(false);
        Root.Opacity = RestOpacity;
    }

    public void ApplyTheme(ElementTheme theme) => Root.RequestedTheme = theme;

    public void MoveTo(int x, int y) => AppWindow.Move(new(x, y));

    /// <summary>A remembered position is used only while a display still shows it: monitors come and go.</summary>
    public void MoveToIfOnScreen(int x, int y)
    {
        var area = DisplayArea.GetFromPoint(new(x, y), DisplayAreaFallback.None);
        if (area is not null)
        {
            MoveTo(x, y);
        }
    }

    public void Render(CapsuleModel model)
    {
        _model = model;
        _shown.Clear();
        Spinner.IsActive = model.Phase is CapsulePhase.Starting or CapsulePhase.Processing;
        switch (model.Phase)
        {
            case CapsulePhase.Idle:
                Show(RecordButton);
                if (_hovered)
                {
                    Show(HideButton);
                }
                RecordLabel.Text = CapsuleText.Record;
                break;
            case CapsulePhase.Starting:
                Show(Spinner);
                Say(CapsuleText.Starting);
                break;
            case CapsulePhase.Processing:
                Show(Spinner);
                Say(CapsuleText.Processing);
                break;
            case CapsulePhase.Saved:
                Show(Check);
                Say(model.SavedMinutes is { } minutes ? CapsuleText.SavedMinutes(minutes) : CapsuleText.Saved);
                break;
            case CapsulePhase.Prompt:
                RenderPrompt(model);
                break;
            case CapsulePhase.Recording:
                RenderRecording(model);
                break;
        }
        ApplyVisibility();
        DispatcherQueue.TryEnqueue(FitToContent);
    }

    /// <summary>
    /// Only what really changed is touched: the timer renders every second, and collapsing a button
    /// even for a moment drops its pressed state and loses the click in progress.
    /// </summary>
    private void ApplyVisibility()
    {
        foreach (var part in new UIElement[] { RecordDot, Spinner, Check, RecordButton, Message, Timer, Wave, ActionButton, SecondButton, MarkArea, StopButton, HideButton })
        {
            var wanted = _shown.Contains(part) ? Visibility.Visible : Visibility.Collapsed;
            if (part.Visibility != wanted)
            {
                part.Visibility = wanted;
            }
        }
    }

    /// <summary>The newest level of each voice, 0 to 1. The wave moves away from the start of each side.</summary>
    public void PushLevels(double me, double them)
    {
        Push(_meHistory, me);
        Push(_themHistory, them);
        DrawSide(_me, _meHistory);
        DrawSide(_them, _themHistory);
    }

    private void RenderPrompt(CapsuleModel model)
    {
        if (model.AutoStartSeconds is { } seconds)
        {
            Say(CapsuleText.PromptAuto(model.CallApp, seconds));
            Action(CapsuleText.RecordNow, CapsuleText.DontRecord);
        }
        else
        {
            Say(CapsuleText.Prompt(model.CallApp));
            Action(CapsuleText.Record, CapsuleText.NotNow);
        }
    }

    private void RenderRecording(CapsuleModel model)
    {
        Show(RecordDot, Timer, MarkArea, StopButton);
        Timer.Text = model.Elapsed.TotalHours >= 1 ? model.Elapsed.ToString(@"h\:mm\:ss") : model.Elapsed.ToString(@"m\:ss");
        MarkIcon.Glyph = model.Marks > 0 ? "" : "";
        MarkBadge.Visibility = model.Marks > 0 ? Visibility.Visible : Visibility.Collapsed;
        MarkBadge.Value = model.Marks;
        var time = model.HintTime.ToString(@"m\:ss");
        switch (model.Hint)
        {
            case CapsuleHint.None:
                Show(Wave);
                break;
            case CapsuleHint.StopCountdown:
                Say(CapsuleText.StopIn((int)model.HintTime.TotalSeconds));
                Action(CapsuleText.Continue, null);
                break;
            case CapsuleHint.TellOthers:
                Say(CapsuleText.TellOthers);
                break;
            case CapsuleHint.MicSilent:
                Say(CapsuleText.MicSilent(time), warning: true);
                break;
            case CapsuleHint.SystemSilent:
                Say(CapsuleText.SystemSilent(time), warning: true);
                break;
        }
    }

    private void Say(string text, bool warning = false)
    {
        Show(Message);
        Message.Text = text;
        Message.Foreground = (Brush)Application.Current.Resources[warning ? "SystemFillColorCautionBrush" : "TextFillColorPrimaryBrush"];
    }

    private void Action(string primary, string? secondary)
    {
        Show(ActionButton);
        ActionButton.Content = primary;
        if (secondary is null)
        {
            return;
        }
        Show(SecondButton);
        SecondButton.Content = secondary;
    }

    private void Show(params UIElement[] elements) => _shown.UnionWith(elements);

    private void FitToContent()
    {
        Content.Measure(new Size(double.PositiveInfinity, LogicalHeight));
        var scale = NativeWindow.GetDpiForWindow(_hwnd) / 96.0;
        var width = Math.Max(MinimumWidth, Content.DesiredSize.Width + 2);
        AppWindow.Resize(new((int)Math.Ceiling(width * scale), (int)Math.Ceiling(LogicalHeight * scale)));
    }

    private void BuildWave()
    {
        var divider = new Rectangle { Width = 1, Height = 14, Fill = (Brush)Application.Current.Resources["DividerStrokeColorDefaultBrush"] };
        Canvas.SetLeft(divider, BarStep * BarsPerSide + 3);
        Canvas.SetTop(divider, (WaveHeight - 14) / 2);
        Wave.Children.Add(divider);
        for (var i = 0; i < BarsPerSide; i++)
        {
            _me[i] = AddBar(_meBrush, i * BarStep);
            _them[i] = AddBar(_themBrush, BarStep * BarsPerSide + 8 + i * BarStep);
        }
        DrawSide(_me, _meHistory);
        DrawSide(_them, _themHistory);
    }

    private Rectangle AddBar(Brush brush, double left)
    {
        var bar = new Rectangle { Width = BarWidth, RadiusX = 1.5, RadiusY = 1.5, Fill = brush };
        Canvas.SetLeft(bar, left);
        Wave.Children.Add(bar);
        return bar;
    }

    private static void Push(double[] history, double level)
    {
        Array.Copy(history, 0, history, 1, history.Length - 1);
        history[0] = Math.Clamp(level, 0, 1);
    }

    private static void DrawSide(Rectangle[] bars, double[] history)
    {
        for (var i = 0; i < bars.Length; i++)
        {
            var height = MinBar + history[i] * (WaveHeight - MinBar);
            bars[i].Height = height;
            Canvas.SetTop(bars[i], (WaveHeight - height) / 2);
        }
    }

    private void OnEntered(object sender, PointerRoutedEventArgs e)
    {
        Root.Opacity = 1;
        _hovered = true;
        Render(_model);
    }

    private void OnExited(object sender, PointerRoutedEventArgs e)
    {
        if (_dragging)
        {
            return;
        }
        Root.Opacity = RestOpacity;
        _hovered = false;
        Render(_model);
    }

    private void OnPressed(object sender, PointerRoutedEventArgs e)
    {
        if (e.Pointer.PointerDeviceType != PointerDeviceType.Mouse || !e.GetCurrentPoint(Root).Properties.IsLeftButtonPressed)
        {
            return;
        }
        _dragging = true;
        _dragCursor = NativeWindow.CursorPosition();
        _dragWindow = AppWindow.Position;
        Root.CapturePointer(e.Pointer);
    }

    private void OnMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_dragging)
        {
            return;
        }
        var cursor = NativeWindow.CursorPosition();
        NativeWindow.MoveWithoutActivating(_hwnd, _dragWindow.X + cursor.X - _dragCursor.X, _dragWindow.Y + cursor.Y - _dragCursor.Y);
    }

    private void OnReleased(object sender, PointerRoutedEventArgs e)
    {
        if (_dragging)
        {
            Moved?.Invoke(this, AppWindow.Position);
        }
        _dragging = false;
        Root.ReleasePointerCaptures();
    }

    private void OnHide(object sender, RoutedEventArgs e) => HideRequested?.Invoke(this, EventArgs.Empty);

    /// <summary>Where the capsule goes by default: the top middle of the screen it is on.</summary>
    public void PlaceDefault()
    {
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        AppWindow.Move(new(area.X + (area.Width - AppWindow.Size.Width) / 2, area.Y + Edge));
    }
}
