using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using WinRT.Interop;

namespace Sozvon.App.Capsule;

public sealed partial class CapsuleWindow : Window
{
    private const int LogicalWidth = 340, LogicalHeight = 44;
    private readonly nint _hwnd;
    private readonly DispatcherTimer _demo = new() { Interval = TimeSpan.FromMilliseconds(80) };
    private readonly Random _random = new(7);
    private readonly Rectangle[] _bars = new Rectangle[22];

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
        var scale = NativeWindow.GetDpiForWindow(_hwnd) / 96.0;
        AppWindow.Resize(new((int)(LogicalWidth * scale), (int)(LogicalHeight * scale)));
        BuildWave();
        _demo.Tick += (_, _) => AnimateWave();
        _demo.Start();
    }

    public void ShowWithoutFocus() => AppWindow.Show(false);

    private void BuildWave()
    {
        var me = new SolidColorBrush(ColorHelper.FromArgb(255, 0x0F, 0x6C, 0xBD));
        var them = new SolidColorBrush(ColorHelper.FromArgb(255, 0xC4, 0x50, 0x1B));
        for (var i = 0; i < _bars.Length; i++)
        {
            var bar = new Rectangle { Width = 3, RadiusX = 1.5, RadiusY = 1.5, Fill = i < 11 ? me : them };
            Microsoft.UI.Xaml.Controls.Canvas.SetLeft(bar, i * 6 + (i < 11 ? 0 : 8));
            Wave.Children.Add(bar);
            _bars[i] = bar;
        }
    }

    private void AnimateWave()
    {
        foreach (var bar in _bars)
        {
            var height = 4 + _random.NextDouble() * 22;
            bar.Height = height;
            Microsoft.UI.Xaml.Controls.Canvas.SetTop(bar, (28 - height) / 2);
        }
    }
}
