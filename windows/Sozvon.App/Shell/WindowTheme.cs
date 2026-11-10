using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Sozvon.App.Settings;
using Windows.UI;

namespace Sozvon.App.Shell;

/// <summary>Applies the theme from Settings to a window's content and its title bar buttons.</summary>
public static class WindowTheme
{
    public static void Apply(Window window, FrameworkElement root, AppTheme theme)
    {
        root.RequestedTheme = theme switch
        {
            AppTheme.Light => ElementTheme.Light,
            AppTheme.Dark => ElementTheme.Dark,
            _ => ElementTheme.Default,
        };
        window.AppWindow.TitleBar.PreferredTheme = theme switch
        {
            AppTheme.Light => TitleBarTheme.Light,
            AppTheme.Dark => TitleBarTheme.Dark,
            _ => TitleBarTheme.UseDefaultAppMode,
        };
        // With the content extended into the title bar the caption buttons keep the system's colours, not the
        // app's theme: a light window under a dark system gets white glyphs on a light backdrop. Paint them here.
        PaintCaptionButtons(window.AppWindow.TitleBar, root.ActualTheme);
        root.ActualThemeChanged -= OnActualThemeChanged;
        root.ActualThemeChanged += OnActualThemeChanged;
    }

    /// <summary>"As in the system" follows a system switch while the window is open.</summary>
    private static void OnActualThemeChanged(FrameworkElement root, object args)
    {
        if (root.XamlRoot?.ContentIslandEnvironment is { } island && AppWindow.GetFromWindowId(island.AppWindowId) is { } window)
        {
            PaintCaptionButtons(window.TitleBar, root.ActualTheme);
        }
    }

    /// <summary>Fluent text and subtle fill tokens, the colours the caption buttons of Windows 11 apps use.</summary>
    private static void PaintCaptionButtons(AppWindowTitleBar bar, ElementTheme theme)
    {
        var dark = theme == ElementTheme.Dark;
        var text = dark ? Colors.White : Colors.Black;
        bar.ButtonBackgroundColor = bar.ButtonInactiveBackgroundColor = Colors.Transparent;
        bar.ButtonForegroundColor = bar.ButtonHoverForegroundColor = WithAlpha(text, dark ? 0xFF : 0xE4);
        bar.ButtonInactiveForegroundColor = WithAlpha(text, dark ? 0x8B : 0x72);
        bar.ButtonHoverBackgroundColor = WithAlpha(text, dark ? 0x0F : 0x09);
        bar.ButtonPressedBackgroundColor = WithAlpha(text, dark ? 0x0A : 0x06);
        bar.ButtonPressedForegroundColor = WithAlpha(text, dark ? 0xC5 : 0x9E);
    }

    private static Color WithAlpha(Color color, int alpha) => Color.FromArgb((byte)alpha, color.R, color.G, color.B);
}
