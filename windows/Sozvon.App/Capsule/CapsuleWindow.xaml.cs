using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Shapes;
using System.Numerics;
using Windows.Foundation;
using Windows.UI;
using WinRT.Interop;

namespace Sozvon.App.Capsule;

/// <summary>The floating capsule: always on top, never takes focus, draws a <see cref="CapsuleModel"/>.</summary>
public sealed partial class CapsuleWindow : Window
{
    private const int MinimumWidth = 96, Edge = 16;
    private const int BarsPerSide = 9, BarWidth = 4, BarStep = 8, SideGap = 12, WaveHeight = 32, MinBar = 4, MaxBar = 24;
    /// <summary>Transparent room around the shape for its shadow: 16 DIP blur, 3 DIP down.</summary>
    private const int ShadowSide = 16, ShadowTop = 12, ShadowBottom = 20;
    private const float ShadowBlur = 16, ShadowDrop = 3;
    private const double VisualCentre = 20, TextEdge = 16;
    private static readonly TimeSpan Motion = TimeSpan.FromMilliseconds(167);

    private readonly nint _hwnd;
    private readonly CapsuleStyle _style;
    private readonly SolidColorBrush _meBrush = new();
    private readonly SolidColorBrush _themBrush = new();
    private readonly SolidColorBrush _markedBrush = new();
    private readonly SolidColorBrush _unmarkedBrush = new();
    private readonly Rectangle[] _me = new Rectangle[BarsPerSide];
    private readonly Rectangle[] _them = new Rectangle[BarsPerSide];
    private readonly double[] _meHistory = new double[BarsPerSide];
    private readonly double[] _themHistory = new double[BarsPerSide];
    private readonly HashSet<UIElement> _shown = [];
    private readonly DispatcherTimer _hideFade = new() { Interval = Motion };
    private CapsuleModel _model = new(CapsulePhase.Idle);
    private Storyboard? _widthAnimation;
    private readonly DispatcherTimer _pointerWatch = new() { Interval = TimeSpan.FromMilliseconds(50) };
    private Microsoft.UI.Composition.LayerVisual? _shadowLayer;
    private Microsoft.UI.Composition.ShapeVisual? _shadowShape;
    private Microsoft.UI.Composition.CompositionRoundedRectangleGeometry? _shadowGeometry;
    private Microsoft.UI.Composition.CompositionColorBrush? _shadowFill;
    private Microsoft.UI.Composition.DropShadow? _shadow;
    private bool? _clickThrough;
    private double _width;
    private bool _hovered;
    private int? _centre;
    private bool _anchorLeft;
    private bool _revealPending;
    private bool _pressed;
    private bool _dragged;
    private bool _dragging;
    private NativeWindow.Point _dragCursor;

    public event EventHandler? RecordClicked;
    public event EventHandler? StopClicked;
    public event EventHandler? MarkClicked;
    public event EventHandler? PrimaryClicked;
    public event EventHandler? SecondaryClicked;
    public event EventHandler? HideRequested;

    /// <summary>A new state was drawn: whether the capsule is on screen may change with it.</summary>
    public event EventHandler? Rendered;

    /// <summary>The user finished dragging the capsule: its centre and its window's top, in screen pixels.</summary>
    public event EventHandler<Windows.Graphics.PointInt32>? Moved;

    public CapsuleWindow(CapsuleStyle style)
    {
        _style = style;
        InitializeComponent();
        _hwnd = WindowNative.GetWindowHandle(this);
        var presenter = OverlappedPresenter.CreateForContextMenu();
        presenter.IsAlwaysOnTop = true;
        presenter.SetBorderAndTitleBar(hasBorder: false, hasTitleBar: false);
        AppWindow.SetPresenter(presenter);
        AppWindow.IsShownInSwitchers = false;
        SystemBackdrop = new TransparentBackdrop();
        NativeWindow.MakeNonActivating(_hwnd);
        NativeWindow.RemoveFrame(_hwnd);
        NativeWindow.RefuseActivationOnClick(_hwnd, OnSystemMoveEnded);
        ApplyStyle();

        HideItem.Text = CapsuleText.Hide;
        ToolTipService.SetToolTip(MarkButton, CapsuleText.Mark + " (Ctrl+Alt+I)");
        ToolTipService.SetToolTip(StopButton, CapsuleText.Stop);
        ToolTipService.SetToolTip(HideButton, CapsuleText.Hide);
        RecordButton.Click += (_, _) => Click(RecordClicked);
        StopButton.Click += (_, _) => Click(StopClicked);
        MarkButton.Click += (_, _) => Click(MarkClicked);
        ActionButton.Click += (_, _) => Click(PrimaryClicked);
        SecondButton.Click += (_, _) => Click(SecondaryClicked);
        _hideFade.Tick += (_, _) =>
        {
            _hideFade.Stop();
            Render(_model, anchorLeft: true);
        };
        // Handled events too: a press on a button still starts a drag once the pointer has moved far enough,
        // and until then the button keeps its click.
        Root.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler(OnPressed), handledEventsToo: true);
        Root.AddHandler(UIElement.PointerMovedEvent, new PointerEventHandler(OnMoved), handledEventsToo: true);
        Root.AddHandler(UIElement.PointerReleasedEvent, new PointerEventHandler(OnReleased), handledEventsToo: true);
        Root.AddHandler(UIElement.PointerCaptureLostEvent, new PointerEventHandler(OnReleased), handledEventsToo: true);
        Root.Margin = new Thickness(ShadowSide, ShadowTop, ShadowSide, ShadowBottom);
        Root.ActualThemeChanged += (_, _) =>
        {
            ApplyWaveColors();
            ApplyShadowColors();
        };
        Root.Loaded += (_, _) =>
        {
            DrawWave();
            BuildShadow();
        };
        // Layout, not SizeChanged: the width animation changes the size every frame and SizeChanged lags behind it.
        Shape.LayoutUpdated += (_, _) => SizeShadow();
        _pointerWatch.Tick += (_, _) => PassClicksOutsideShape();
        _pointerWatch.Start();
        // A button shown for the first time gets its template during layout, after the first measure: fit again then.
        foreach (FrameworkElement part in Bar.Children)
        {
            part.SizeChanged += (_, _) => FitToContent();
        }
        BuildWave();
        ApplyWaveColors();
        Render(_model);
    }

    public void ShowWithoutFocus()
    {
        AppWindow.Show(false);
        NativeWindow.ComposeWithBackground(_hwnd);
    }

    public void ApplyTheme(ElementTheme theme) => Root.RequestedTheme = theme;

    /// <summary>For screenshots of the demo states: draws the capsule as it looks under the pointer.</summary>
    public void ShowAsHovered() => SetHovered(true);

    /// <summary>What the pointer entering or leaving does; the demo also calls it to show the transition.</summary>
    public void SetHovered(bool hovered)
    {
        _hovered = hovered;
        Render(_model, anchorLeft: true);
    }

    /// <summary>
    /// A remembered place: the capsule's centre and its window's top, in screen pixels. Used only while a display
    /// still shows that point, because monitors come and go.
    /// </summary>
    public void MoveToIfOnScreen(int centre, int top)
    {
        if (DisplayArea.GetFromPoint(new(centre, top), DisplayAreaFallback.None) is null)
        {
            return;
        }
        // Kept on screen at the next resize, when the window has its real width.
        _centre = centre;
        AppWindow.Move(new(centre - AppWindow.Size.Width / 2, top));
    }

    public void Render(CapsuleModel model) => Render(model, anchorLeft: false);

    /// <param name="anchorLeft">
    /// The cross coming and going on hover grows the capsule to the right, so what the pointer is over stays put;
    /// a change of state grows it from its centre.
    /// </param>
    private void Render(CapsuleModel model, bool anchorLeft)
    {
        _model = model;
        _anchorLeft = anchorLeft;
        _shown.Clear();
        if (model.Phase is CapsulePhase.Starting or CapsulePhase.Processing)
        {
            SpinnerTurning.Begin();
        }
        else
        {
            SpinnerTurning.Stop();
        }
        switch (model.Phase)
        {
            case CapsulePhase.Idle:
                Show(RecordButton);
                if (_hovered || _hideFade.IsEnabled)
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
        ShowHideButton(_hovered && model.Phase == CapsulePhase.Idle);
        DispatcherQueue.TryEnqueue(FitToContent);
        Rendered?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>What the capsule shows now.</summary>
    public CapsuleModel Model => _model;

    /// <summary>
    /// The capsule shows the panel's rule (<see cref="Sozvon.Core.Settings.PanelVisibility"/>) on screen: shown when it
    /// should be and not yet visible, hidden the other way round. Showing never takes the focus.
    /// </summary>
    public void SetOnScreen(bool visible)
    {
        if (visible && !AppWindow.IsVisible)
        {
            ShowWithoutFocus();
        }
        else if (!visible && AppWindow.IsVisible)
        {
            AppWindow.Hide();
        }
    }

    /// <summary>The newest level of each voice, 0 to 1. The wave moves away from the start of each side.</summary>
    public void PushLevels(double me, double them)
    {
        Push(_meHistory, me);
        Push(_themHistory, them);
        DrawWave();
    }

    /// <summary>Where the capsule goes by default: the top middle of the screen it is on.</summary>
    public void PlaceDefault()
    {
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var scale = NativeWindow.GetDpiForWindow(_hwnd) / 96.0;
        _centre = area.X + area.Width / 2;
        AppWindow.Move(new(_centre.Value - AppWindow.Size.Width / 2, area.Y + (int)Math.Round((Edge - ShadowTop) * scale)));
    }

    private void ApplyStyle()
    {
        Shape.Height = _style.Height;
        Shape.CornerRadius = new CornerRadius(_style.Radius);
        foreach (var button in new[] { RecordButton, MarkButton, StopButton, HideButton, ActionButton, SecondButton })
        {
            button.CornerRadius = new CornerRadius(_style.ButtonRadius);
        }
    }

    /// <summary>
    /// Only what really changed is touched: the timer renders every second, and collapsing a button
    /// even for a moment drops its pressed state and loses the click in progress.
    /// </summary>
    private void ApplyVisibility()
    {
        foreach (var part in new UIElement[] { RecordDot, Spinner, Check, RecordButton, Message, Warning, Timer, Wave, ActionButton, SecondButton, MarkArea, StopButton, HideButton })
        {
            var wanted = _shown.Contains(part) ? Visibility.Visible : Visibility.Collapsed;
            if (part.Visibility != wanted)
            {
                part.Visibility = wanted;
            }
        }
        var first = Bar.Children.FirstOrDefault(c => c.Visibility == Visibility.Visible);
        var last = Bar.Children.LastOrDefault(c => c.Visibility == Visibility.Visible);
        Bar.Margin = new Thickness(EndAir(first), 0, EndAir(last), 0);
    }

    /// <summary>
    /// The air at an end of the row, chosen by what stands there so that the eye sees the same margin on both sides:
    /// a dot, a ring or an icon has its visual centre 20 DIP from the edge, text starts 16 DIP from it.
    /// </summary>
    private double EndAir(UIElement? part) => part switch
    {
        null => _style.Padding,
        _ when part == RecordDot || part == Spinner || part == Check => VisualCentre - 8,
        _ when part == RecordButton || part == MarkArea || part == StopButton || part == HideButton => VisualCentre - 16,
        _ => TextEdge,
    };

    /// <summary>The cross fades and grows in; on the way out it fades first and leaves the row afterwards.</summary>
    private void ShowHideButton(bool visible)
    {
        if (visible)
        {
            _hideFade.Stop();
            // Fades in once the shape has grown to hold it: earlier it would poke out of the pill's edge.
            _revealPending = HideButton.Opacity < 1;
        }
        else
        {
            _revealPending = false;
            if (HideButton.Opacity > 0)
            {
                HideButton.Opacity = 0;
                HideButton.Scale = new(0.6f, 0.6f, 1);
                _hideFade.Start();
            }
        }
    }

    private void RevealHideButtonIfPending()
    {
        if (!_revealPending)
        {
            return;
        }
        _revealPending = false;
        HideButton.Opacity = 1;
        HideButton.Scale = new(1, 1, 1);
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
        MarkIcon.Foreground = model.Marks > 0 ? _markedBrush : _unmarkedBrush;
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
                Warn(CapsuleText.MicSilent(time));
                break;
            case CapsuleHint.SystemSilent:
                Warn(CapsuleText.SystemSilent(time));
                break;
        }
    }

    private void Say(string text)
    {
        Show(Message);
        Message.Text = text;
    }

    private void Warn(string text)
    {
        Show(Warning);
        Warning.Text = text;
    }

    private void Action(string primary, string? secondary)
    {
        Show(ActionButton);
        ActionButton.Content = Label(primary);
        if (secondary is null)
        {
            return;
        }
        Show(SecondButton);
        SecondButton.Content = Label(secondary);
    }

    /// <summary>Text centred by its letters, not by the font's line box, which sits low in a 32 DIP button.</summary>
    private static TextBlock Label(string text) => new() { Text = text, TextLineBounds = TextLineBounds.Tight };

    private void Show(params UIElement[] elements) => _shown.UnionWith(elements);

    /// <summary>
    /// The window is resized at once to the larger of the two widths, which costs nothing because it is transparent,
    /// and the drawn shape follows smoothly; a shrinking window catches up when the animation ends.
    /// </summary>
    private void FitToContent()
    {
        // The shape is exactly as wide as the window, in whole pixels: no sliver of the pill falls outside it.
        var scale = NativeWindow.GetDpiForWindow(_hwnd) / 96.0;
        var target = Math.Ceiling(Math.Max(MinimumWidth, ContentWidth()) * scale) / scale;
        if (target == _width)
        {
            RevealHideButtonIfPending();
            return;
        }
        var from = _width;
        _width = target;
        _widthAnimation?.Stop();
        Root.HorizontalAlignment = _anchorLeft ? HorizontalAlignment.Left : HorizontalAlignment.Center;
        ResizeWindow(Math.Max(from, target));
        if (from == 0 || !Root.IsLoaded)
        {
            Root.Width = target;
            RevealHideButtonIfPending();
            return;
        }
        var animation = new DoubleAnimation
        {
            From = from,
            To = target,
            Duration = Motion,
            EnableDependentAnimation = true,
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
        };
        Storyboard.SetTarget(animation, Root);
        Storyboard.SetTargetProperty(animation, "Width");
        var storyboard = new Storyboard();
        storyboard.Children.Add(animation);
        storyboard.Completed += (_, _) =>
        {
            Root.Width = target;
            if (_width == target)
            {
                ResizeWindow(target);
                RevealHideButtonIfPending();
            }
        };
        _widthAnimation = storyboard;
        storyboard.Begin();
    }

    /// <summary>
    /// Each visible part measured without limits and added up: measuring the row as a whole returns a size
    /// already clipped to the shape's current width, so a growing capsule would come out too narrow.
    /// </summary>
    private double ContentWidth()
    {
        var unlimited = new Size(double.PositiveInfinity, double.PositiveInfinity);
        var parts = 0;
        var width = 0.0;
        foreach (FrameworkElement part in Bar.Children)
        {
            if (part.Visibility != Visibility.Visible)
            {
                continue;
            }
            part.Measure(unlimited);
            width += part.DesiredSize.Width;
            parts++;
        }
        return width + Bar.Spacing * Math.Max(0, parts - 1) + Bar.Margin.Left + Bar.Margin.Right + Shape.BorderThickness.Left + Shape.BorderThickness.Right;
    }

    /// <summary>
    /// The capsule keeps its centre: it grows and shrinks to both sides, like the shape drawn inside it. The centre is
    /// kept as a number rather than read back from the window, whose first size is WinUI's large default.
    /// </summary>
    private void ResizeWindow(double width)
    {
        var scale = NativeWindow.GetDpiForWindow(_hwnd) / 96.0;
        var pixels = (int)Math.Round((width + 2 * ShadowSide) * scale);
        var centre = _centre ??= AppWindow.Position.X + AppWindow.Size.Width / 2;
        var x = _anchorLeft ? AppWindow.Position.X : centre - pixels / 2;
        AppWindow.MoveAndResize(new(x, AppWindow.Position.Y, pixels, (int)Math.Round((_style.Height + ShadowTop + ShadowBottom) * scale)));
        KeepOnScreen();
    }

    /// <summary>The whole capsule stays inside the work area of its display, whatever was remembered or dragged.</summary>
    private void KeepOnScreen()
    {
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Nearest).WorkArea;
        var size = AppWindow.Size;
        var x = Math.Clamp(AppWindow.Position.X, area.X, Math.Max(area.X, area.X + area.Width - size.Width));
        var y = Math.Clamp(AppWindow.Position.Y, area.Y, Math.Max(area.Y, area.Y + area.Height - size.Height));
        if (x != AppWindow.Position.X || y != AppWindow.Position.Y)
        {
            AppWindow.Move(new(x, y));
        }
        _centre = x + size.Width / 2;
    }

    private void BuildWave()
    {
        Wave.Width = 2 * BarsPerSide * BarStep - (BarStep - BarWidth) + SideGap;
        Canvas.SetLeft(WaveDivider, BarsPerSide * BarStep - (BarStep - BarWidth) + SideGap / 2);
        Canvas.SetTop(WaveDivider, (WaveHeight - WaveDivider.Height) / 2);
        for (var i = 0; i < BarsPerSide; i++)
        {
            _me[i] = AddBar(_meBrush, i * BarStep);
            _them[i] = AddBar(_themBrush, BarsPerSide * BarStep - (BarStep - BarWidth) + SideGap + i * BarStep);
        }
    }

    private Rectangle AddBar(Brush brush, double left)
    {
        var bar = new Rectangle { Width = BarWidth, RadiusX = BarWidth / 2.0, RadiusY = BarWidth / 2.0, Fill = brush };
        Canvas.SetLeft(bar, left);
        Wave.Children.Add(bar);
        return bar;
    }

    /// <summary>Me in blue, them in red, as on the Mac; the dark theme takes the lighter shades.</summary>
    private void ApplyWaveColors()
    {
        var dark = Root.ActualTheme == ElementTheme.Dark;
        _meBrush.Color = dark ? Color.FromArgb(255, 0x6C, 0xB8, 0xFF) : Color.FromArgb(255, 0x00, 0x67, 0xD4);
        _themBrush.Color = dark ? Color.FromArgb(255, 0xFF, 0x5A, 0x52) : Color.FromArgb(255, 0xD9, 0x2D, 0x20);
        _markedBrush.Color = dark ? Color.FromArgb(255, 0xFF, 0xC8, 0x3D) : Color.FromArgb(255, 0xC2, 0x8A, 0x00);
        _unmarkedBrush.Color = dark ? Color.FromArgb(0xC5, 0xFF, 0xFF, 0xFF) : Color.FromArgb(0x9E, 0x00, 0x00, 0x00);
    }

    private static void Push(double[] history, double level)
    {
        Array.Copy(history, 0, history, 1, history.Length - 1);
        history[0] = Math.Clamp(level, 0, 1);
    }

    private void DrawWave()
    {
        var scale = Root.XamlRoot?.RasterizationScale ?? 1;
        DrawSide(_me, _meHistory, scale);
        DrawSide(_them, _themHistory, scale);
    }

    /// <summary>Heights are whole even pixels, so each bar sits exactly on the centre line at any scale.</summary>
    private static void DrawSide(Rectangle[] bars, double[] history, double scale)
    {
        for (var i = 0; i < bars.Length; i++)
        {
            var height = MinBar + history[i] * (MaxBar - MinBar);
            var pixels = Math.Max(2, Math.Round(height * scale / 2) * 2);
            bars[i].Height = pixels / scale;
            Canvas.SetTop(bars[i], (WaveHeight * scale - pixels) / 2 / scale);
        }
    }

    private void OnEntered(object sender, PointerRoutedEventArgs e) => SetHovered(true);

    private void OnExited(object sender, PointerRoutedEventArgs e)
    {
        if (_dragging)
        {
            return;
        }
        SetHovered(false);
    }

    /// <summary>Pixels of movement that turn a press into a drag; less than that is a click on whatever was pressed.</summary>
    private const int DragThreshold = 4;

    private void OnPressed(object sender, PointerRoutedEventArgs e)
    {
        if (e.Pointer.PointerDeviceType != PointerDeviceType.Mouse || !e.GetCurrentPoint(Root).Properties.IsLeftButtonPressed)
        {
            return;
        }
        _pressed = true;
        _dragged = false;
        _dragCursor = NativeWindow.CursorPosition();
    }

    private void OnMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_pressed)
        {
            return;
        }
        var cursor = NativeWindow.CursorPosition();
        if (Math.Abs(cursor.X - _dragCursor.X) < DragThreshold && Math.Abs(cursor.Y - _dragCursor.Y) < DragThreshold)
        {
            return;
        }
        // From here on it is a drag, and the system does it. The button underneath still sees the release as the end
        // of its press, so its click is thrown away (see Click) until the next press.
        _pressed = false;
        _dragged = true;
        _dragging = true;
        NativeWindow.DragWithSystem(_hwnd);
        _dragging = false;
    }

    /// <summary>A button's click counts only when the press that ended on it was not a drag of the capsule.</summary>
    private void Click(EventHandler? handler)
    {
        if (_dragged)
        {
            return;
        }
        handler?.Invoke(this, EventArgs.Empty);
    }

    private void OnReleased(object sender, PointerRoutedEventArgs e) => _pressed = false;

    /// <summary>The system move has ended: the capsule stays on screen and the place is remembered.</summary>
    private void OnSystemMoveEnded()
    {
        KeepOnScreen();
        Moved?.Invoke(this, new(_centre!.Value, AppWindow.Position.Y));
    }

    /// <summary>A shadow as on Windows 11 flyouts: a rounded shape of the capsule's own colour casting a soft drop shadow.</summary>
    private void BuildShadow()
    {
        if (_shadowLayer is not null)
        {
            return;
        }
        var compositor = ElementCompositionPreview.GetElementVisual(ShadowHost).Compositor;
        _shadowGeometry = compositor.CreateRoundedRectangleGeometry();
        _shadowGeometry.CornerRadius = new Vector2(_style.Radius);
        _shadowFill = compositor.CreateColorBrush();
        var sprite = compositor.CreateSpriteShape(_shadowGeometry);
        sprite.FillBrush = _shadowFill;
        _shadowShape = compositor.CreateShapeVisual();
        _shadowShape.Shapes.Add(sprite);
        _shadow = compositor.CreateDropShadow();
        _shadow.BlurRadius = ShadowBlur;
        _shadow.Offset = new Vector3(0, ShadowDrop, 0);
        _shadowLayer = compositor.CreateLayerVisual();
        _shadowLayer.Children.InsertAtTop(_shadowShape);
        _shadowLayer.Shadow = _shadow;
        ElementCompositionPreview.SetElementChildVisual(ShadowHost, _shadowLayer);
        ApplyShadowColors();
        SizeShadow();
    }

    private void SizeShadow()
    {
        if (_shadowLayer is null)
        {
            return;
        }
        // The visual hung under a XAML element works in physical pixels, not in DIP.
        var scale = (float)(Root.XamlRoot?.RasterizationScale ?? 1);
        var size = new Vector2((float)Shape.ActualWidth, (float)Shape.ActualHeight) * scale;
        if (_shadowLayer.Size == size)
        {
            return;
        }
        _shadowLayer.Size = size;
        _shadowShape!.Size = size;
        _shadowGeometry!.Size = size;
        _shadowGeometry.CornerRadius = new Vector2(_style.Radius * scale);
        _shadow!.BlurRadius = ShadowBlur * scale;
        _shadow.Offset = new Vector3(0, ShadowDrop * scale, 0);
    }

    private void ApplyShadowColors()
    {
        if (_shadow is null)
        {
            return;
        }
        var strength = Root.ActualTheme == ElementTheme.Dark ? 0.32 : 0.15;
        // The strength goes into the colour: a layer visual's shadow ignores DropShadow.Opacity.
        _shadow.Color = Color.FromArgb((byte)Math.Round(strength * 255), 0, 0, 0);
        _shadowFill!.Color = Shape.Background is SolidColorBrush fill ? fill.Color : Colors.Transparent;
    }

    /// <summary>
    /// The window is larger than the shape by the shadow's margin; clicks there belong to the window underneath,
    /// so the window lets the mouse through whenever the pointer is not over the shape.
    /// </summary>
    private void PassClicksOutsideShape()
    {
        var cursor = NativeWindow.CursorPosition();
        var scale = NativeWindow.GetDpiForWindow(_hwnd) / 96.0;
        var position = AppWindow.Position;
        var size = AppWindow.Size;
        var shapeWidth = Shape.ActualWidth * scale;
        var left = position.X + (size.Width - shapeWidth) / 2;
        var top = position.Y + ShadowTop * scale;
        var over = cursor.X >= left && cursor.X < left + shapeWidth && cursor.Y >= top && cursor.Y < top + _style.Height * scale;
        var through = !over && !_dragging;
        if (_clickThrough != through)
        {
            _clickThrough = through;
            NativeWindow.SetClickThrough(_hwnd, through);
        }
    }

    private void OnHide(object sender, RoutedEventArgs e) => Click(HideRequested);
}
