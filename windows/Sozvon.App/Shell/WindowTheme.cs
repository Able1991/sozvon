using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Sozvon.App.Settings;

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
    }
}
