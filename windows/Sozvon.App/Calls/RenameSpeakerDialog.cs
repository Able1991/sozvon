using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Sozvon.App.Recording;
using Sozvon.Core.Calls;
using static Sozvon.App.Strings.Loc;

namespace Sozvon.App.Calls;

/// <summary>What "Rename speaker" does.</summary>
public abstract record RenameAction(string Name)
{
    /// <summary>Every line of the speaker gets the new name.</summary>
    public sealed record Rename(string To) : RenameAction(To);

    /// <summary>The name already speaks in the call: both speakers' lines become one.</summary>
    public sealed record Merge(string To) : RenameAction(To);

    /// <summary>The name already speaks in the call: the two speakers swap (two people mixed up).</summary>
    public sealed record Swap(string With) : RenameAction(With);

    /// <summary>Only the clicked line goes to that speaker.</summary>
    public sealed record Line(string To) : RenameAction(To);
}

/// <summary>
/// "Who is speaking?": pick a suggested name or type one, for the whole transcript or only the clicked line. A name
/// that already speaks in the call asks whether to swap the two speakers or merge them.
/// </summary>
public sealed partial class RenameSpeakerDialog : ContentDialog
{
    private readonly TranscriptRow _row;
    private readonly IReadOnlyList<TranscriptRow> _rows;
    private readonly TextBox _name = new() { Header = L("Имя") };
    private readonly CheckBox _everywhere = new() { IsChecked = true };
    private readonly RadioButtons _choice = new();
    private readonly TextBlock _taken = new() { TextWrapping = TextWrapping.Wrap };
    private readonly StackPanel _takenPanel = new() { Spacing = 6 };
    private readonly TextBlock _swap = new() { TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock _merge = new() { TextWrapping = TextWrapping.Wrap };
    private bool _updating;

    public RenameSpeakerDialog(TranscriptRow row, IReadOnlyList<TranscriptRow> rows, IReadOnlyList<string> suggestions)
    {
        _row = row;
        _rows = rows;
        Title = L("Кто это говорит?");
        CloseButtonText = L("Отмена");
        DefaultButton = ContentDialogButton.Primary;
        _name.Text = row.Speaker;
        _name.TextChanged += (_, _) => Update();
        var count = rows.Count(r => r.Speaker == row.Speaker);
        _everywhere.Content = L("Во всей расшифровке (реплик «%@»: %@)", row.Speaker, count);
        ToolTipService.SetToolTip(_everywhere, L("Сними галочку, чтобы отдать другому человеку только эту реплику"));
        _everywhere.Checked += (_, _) => Update();
        _everywhere.Unchecked += (_, _) => Update();
        _choice.Items.Add(_swap);
        _choice.Items.Add(_merge);
        _choice.SelectedIndex = 0;
        _choice.SelectionChanged += (_, _) => Update();
        _takenPanel.Children.Add(_taken);
        _takenPanel.Children.Add(_choice);

        var content = new StackPanel { Spacing = 12, MinWidth = 420 };
        content.Children.Add(new TextBlock
        {
            Text = "«" + row.Text + "»",
            TextWrapping = TextWrapping.Wrap,
            MaxLines = 3,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Opacity = 0.75,
        });
        content.Children.Add(_name);
        if (suggestions.Count > 0)
        {
            var chips = new FlowPanel();
            foreach (var name in suggestions)
            {
                var chip = new Button { Content = name, Padding = new Thickness(10, 2, 10, 4) };
                chip.Click += (_, _) => _name.Text = name;
                chips.Children.Add(chip);
            }
            content.Children.Add(new TextBlock { Text = L("Похоже, это:") });
            content.Children.Add(chips);
        }
        content.Children.Add(_everywhere);
        content.Children.Add(_takenPanel);
        Content = content;
        PrimaryButtonClick += (_, args) => args.Cancel = Action is null;
        Update();
    }

    /// <summary>What the dialog would do now; null when the name is not usable or unchanged.</summary>
    public RenameAction? Action
    {
        get
        {
            if (Clean is not { } name)
            {
                return null;
            }
            if (_everywhere.IsChecked != true)
            {
                return new RenameAction.Line(name);
            }
            if (Taken)
            {
                return _choice.SelectedIndex == 0 ? new RenameAction.Swap(name) : new RenameAction.Merge(name);
            }
            return new RenameAction.Rename(name);
        }
    }

    private string? Clean => Transcript.CleanSpeaker(_name.Text) is { } name && name != _row.Speaker ? name : null;

    /// <summary>The new name already speaks in this call.</summary>
    private bool Taken => Clean is { } name && _rows.Any(r => r.Speaker == name);

    private void Update()
    {
        if (_updating)
        {
            return;
        }
        _updating = true;
        var showTaken = _everywhere.IsChecked == true && Taken;
        _takenPanel.Visibility = showTaken ? Visibility.Visible : Visibility.Collapsed;
        if (showTaken && Clean is { } name)
        {
            _taken.Text = L("«%@» уже есть в звонке", name);
            _swap.Text = L("Поменять местами: реплики «%@» станут «%@», и наоборот", _row.Speaker, name);
            _merge.Text = L("Объединить: все реплики станут «%@»", name);
        }
        PrimaryButtonText = Action switch
        {
            RenameAction.Line => L("Изменить реплику"),
            RenameAction.Swap => L("Поменять местами"),
            RenameAction.Merge => L("Объединить"),
            _ => L("Переименовать"),
        };
        IsPrimaryButtonEnabled = Action is not null;
        _updating = false;
    }
}
