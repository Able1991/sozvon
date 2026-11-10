using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Sozvon.App.Shell;
using Sozvon.Core.Calls;
using static Sozvon.App.Strings.Loc;

namespace Sozvon.App.Projects;

/// <summary>A voice saved for a project's person, as the Mac's project sheet shows it: the name and a delete that asks first.</summary>
internal static class ProjectVoiceRow
{
    /// <param name="enabled">False while a voice.py run goes on.</param>
    /// <param name="delete">Runs when the deletion is confirmed.</param>
    public static Grid Create(VoiceRecord voice, bool enabled, Action delete)
    {
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var icon = new FontIcon { Glyph = "\uE720", FontSize = 14, VerticalAlignment = VerticalAlignment.Center };
        var name = new TextBlock { Text = voice.Name, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap };
        ToolTipService.SetToolTip(name, L("Голос сохранён"));
        var button = new Button
        {
            Content = new FontIcon { Glyph = "\uE74D", FontSize = 14 },
            Padding = new Thickness(8),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            IsEnabled = enabled,
            Flyout = Dialogs.ConfirmFlyout(L("Удалить голос «%@»?", voice.Name),
                L("Sozvon перестанет узнавать этого человека по голосу. Голос снова сохранится, когда ты подпишешь его в расшифровке."),
                L("Удалить"), delete),
        };
        ToolTipService.SetToolTip(button, L("Удалить голос"));
        AutomationProperties.SetName(button, L("Удалить голос «%@»", voice.Name));
        Grid.SetColumn(name, 1);
        Grid.SetColumn(button, 2);
        row.Children.Add(icon);
        row.Children.Add(name);
        row.Children.Add(button);
        return row;
    }
}
