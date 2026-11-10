using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using static Sozvon.App.Strings.Loc;

namespace Sozvon.App.Shell;

/// <summary>The questions and messages of the main window's pages, as the Mac's alerts.</summary>
public static class Dialogs
{
    /// <summary>Whether the destructive answer was chosen; Cancel is the default, as on the Mac.</summary>
    public static async Task<bool> ConfirmAsync(XamlRoot root, string title, string text, string destructive)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = root,
            RequestedTheme = ThemeOf(root),
            Title = title,
            Content = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap },
            PrimaryButtonText = destructive,
            CloseButtonText = L("Отмена"),
            DefaultButton = ContentDialogButton.Close,
        };
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }

    /// <summary>Something did not work: what, and the reason.</summary>
    public static async Task ShowProblemAsync(XamlRoot root, string title, string reason)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = root,
            RequestedTheme = ThemeOf(root),
            Title = title,
            Content = new TextBlock { Text = reason, TextWrapping = TextWrapping.Wrap },
            CloseButtonText = L("OK"),
            DefaultButton = ContentDialogButton.Close,
        };
        await dialog.ShowAsync();
    }

    /// <summary>The theme the window shows: a dialog does not take it on by itself.</summary>
    public static ElementTheme ThemeOf(XamlRoot root) => (root.Content as FrameworkElement)?.ActualTheme ?? ElementTheme.Default;

    /// <summary>
    /// A question on a button inside a dialog, where a second dialog cannot open: a flyout with the text and the
    /// destructive button. <paramref name="confirmed"/> runs when it is pressed.
    /// </summary>
    public static Flyout ConfirmFlyout(string title, string text, string destructive, Action confirmed)
    {
        var flyout = new Flyout();
        var button = new Button { Content = destructive, HorizontalAlignment = HorizontalAlignment.Right };
        button.Click += (_, _) =>
        {
            flyout.Hide();
            confirmed();
        };
        flyout.Content = new StackPanel
        {
            MaxWidth = 320,
            Spacing = 12,
            Children =
            {
                new TextBlock { Text = title, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"], TextWrapping = TextWrapping.Wrap },
                new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap },
                button,
            },
        };
        return flyout;
    }
}
