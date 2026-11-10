using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace Sozvon.App.Shell;

/// <summary>
/// A Fluent brush for the theme an element really shows. Application.Current.Resources answers for the app's
/// theme, which stays the system's, while the window follows the theme chosen in Settings: code that builds its
/// controls (the dialogs) asks here with the window's theme.
/// </summary>
public static class ThemeBrush
{
    public static Brush Get(string key, ElementTheme theme)
    {
        // XAML names the dark theme dictionary "Default"; some libraries also add a "Dark" one.
        var names = theme == ElementTheme.Dark ? new[] { "Default", "Dark" } : ["Light"];
        foreach (var name in names)
        {
            if (Find(Application.Current.Resources, key, name) is { } brush)
            {
                return brush;
            }
        }
        return (Brush)Application.Current.Resources[key];
    }

    private static Brush? Find(ResourceDictionary dictionary, string key, string theme)
    {
        if (dictionary.ThemeDictionaries.TryGetValue(theme, out var themed) && themed is ResourceDictionary d
            && d.TryGetValue(key, out var value) && value is Brush brush)
        {
            return brush;
        }
        foreach (var merged in dictionary.MergedDictionaries)
        {
            if (Find(merged, key, theme) is { } found)
            {
                return found;
            }
        }
        return null;
    }
}
