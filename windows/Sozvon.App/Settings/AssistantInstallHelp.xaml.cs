using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Sozvon.Core.Assistants;
using Sozvon.Core.Settings;

namespace Sozvon.App.Settings;

/// <summary>
/// "How to install an assistant", in the setup assistant and in Settings, as the Mac's AssistantInstallHelp: what "not
/// installed" means, the PowerShell command for each missing assistant with Copy, and Check again. Folded unless the
/// caller opens it.
/// </summary>
public sealed partial class AssistantInstallHelp : UserControl
{
    private static readonly FontFamily Mono = new("Cascadia Mono, Consolas");
    private readonly Dictionary<Assistant, Button> _copy = [];
    private Func<string, object[], string> _l = (key, _) => key;

    public AssistantInstallHelp()
    {
        InitializeComponent();
    }

    /// <summary>"Check again" pressed: the caller looks for the programs again and calls <see cref="Show"/>.</summary>
    public event EventHandler? Recheck;

    /// <param name="l">The text table of the process: Loc in the app, the wizard's own Strings in the setup process.</param>
    public void Initialize(Func<string, object[], string> l)
    {
        _l = l;
        HeaderText.Text = l("Как установить помощника", []);
        AutomationProperties.SetName(Box, HeaderText.Text);
        Explanation.Text = l(AssistantInstall.HelpText, []);
        RecheckButton.Content = l("Проверить снова", []);
    }

    /// <summary>The missing assistants, one row each; hidden when none is missing. <paramref name="open"/> unfolds or folds it, null keeps it.</summary>
    public void Show(IReadOnlyList<Assistant> missing, bool? open = null)
    {
        Rows.Children.Clear();
        _copy.Clear();
        foreach (var a in missing)
        {
            if (AssistantInstall.Command(a) is { } command)
            {
                Rows.Children.Add(Row(a, command));
            }
        }
        Visibility = Rows.Children.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (open is { } value)
        {
            Box.IsExpanded = value;
        }
    }

    private Grid Row(Assistant a, string command)
    {
        var row = new Grid { ColumnSpacing = 12 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(96) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var title = new TextBlock { Text = AssistantCli.Title(a), VerticalAlignment = VerticalAlignment.Center };
        var text = new TextBlock
        {
            Text = command,
            FontFamily = Mono,
            IsTextSelectionEnabled = true,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };
        ToolTipService.SetToolTip(text, command);
        AutomationProperties.SetAutomationId(text, "InstallCommand_" + a);
        var copy = new Button { Content = _l("Скопировать", []), MinWidth = 110 };
        AutomationProperties.SetName(copy, _l("Скопировать команду для %@", [AssistantCli.Title(a)]));
        AutomationProperties.SetAutomationId(copy, "CopyInstall_" + a);
        copy.Click += (_, _) =>
        {
            ServerViewModel.Copy(command);
            foreach (var (other, button) in _copy)
            {
                button.Content = _l(other == a ? "Скопировано" : "Скопировать", []);
            }
        };
        _copy[a] = copy;
        Grid.SetColumn(text, 1);
        Grid.SetColumn(copy, 2);
        row.Children.Add(title);
        row.Children.Add(text);
        row.Children.Add(copy);
        return row;
    }

    private void OnRecheck(object sender, RoutedEventArgs e) => Recheck?.Invoke(this, EventArgs.Empty);
}
