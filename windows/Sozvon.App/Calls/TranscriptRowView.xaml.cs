using System.ComponentModel;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using static Sozvon.App.Strings.Loc;

namespace Sozvon.App.Calls;

/// <summary>
/// A transcript paragraph: time, "Name:" in semibold (coral while the voice is not saved), the text, the star of a
/// line marked during the recording. The player's line gets an accent row; find matches are highlighted.
/// </summary>
public sealed partial class TranscriptRowView : UserControl
{
    public static readonly DependencyProperty RowProperty = DependencyProperty.Register(
        nameof(Row), typeof(TranscriptRow), typeof(TranscriptRowView),
        new PropertyMetadata(null, (d, e) => ((TranscriptRowView)d).OnRowChanged((TranscriptRow?)e.OldValue, (TranscriptRow?)e.NewValue)));

    public TranscriptRowView()
    {
        InitializeComponent();
        ActualThemeChanged += (_, _) => Render();
    }

    /// <summary>A click on the row: the card plays from there.</summary>
    public event EventHandler<TranscriptRow>? Activated;

    public TranscriptRow? Row
    {
        get => (TranscriptRow?)GetValue(RowProperty);
        set => SetValue(RowProperty, value);
    }

    private bool IsDark => ActualTheme == ElementTheme.Dark;

    private void OnRowChanged(TranscriptRow? old, TranscriptRow? row)
    {
        if (old is not null)
        {
            old.PropertyChanged -= OnRowPropertyChanged;
        }
        if (row is not null)
        {
            row.PropertyChanged += OnRowPropertyChanged;
        }
        Render();
    }

    private void OnRowPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(TranscriptRow.IsPlaying))
        {
            ShowPlaying();
        }
        else
        {
            ShowMatches();
        }
    }

    private void Render()
    {
        if (Row is not { } row)
        {
            return;
        }
        TimeText.Text = PlayingTimeText.Text = row.Time;
        Body.Inlines.Clear();
        var name = new Run { Text = row.Speaker + ":", FontWeight = FontWeights.SemiBold };
        if (row.IsUnconfirmed)
        {
            name.Foreground = new SolidColorBrush(IsDark ? Color.FromArgb(255, 0xFF, 0x9B, 0x6A) : Color.FromArgb(255, 0xC4, 0x50, 0x1B));
        }
        Body.Inlines.Add(name);
        if (row.Text.Length > 0)
        {
            Body.Inlines.Add(new Run { Text = " " + row.Text });
        }
        StarIcon.Visibility = row.IsStarred ? Visibility.Visible : Visibility.Collapsed;
        var star = row.IsStarred ? L("Отмечено как важное во время записи") : null;
        ToolTipService.SetToolTip(StarIcon, star);
        ToolTipService.SetToolTip(Root, row.IsVoiced ? L("Голос «%@» сохранён: Sozvon узнаёт этого человека в следующих звонках", row.Speaker) : null);
        AutomationProperties.SetName(this, $"{row.Time} {row.Speaker}: {row.Text}");
        ShowPlaying();
        ShowMatches();
    }

    private void ShowPlaying()
    {
        if (Row is not { } row)
        {
            return;
        }
        var playing = row.IsPlaying ? Visibility.Visible : Visibility.Collapsed;
        PlayingFill.Visibility = PlayingBar.Visibility = PlayingTimeText.Visibility = playing;
        TimeText.Visibility = row.IsPlaying ? Visibility.Collapsed : Visibility.Visible;
        StarredFill.Visibility = row.IsStarred && !row.IsPlaying ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>All matches in yellow, the current one in the accent colour. Offsets skip "Name: ".</summary>
    private void ShowMatches()
    {
        Body.TextHighlighters.Clear();
        if (Row is not { Found.Count: > 0 } row)
        {
            return;
        }
        var offset = row.Speaker.Length + 2;
        var others = new TextHighlighter
        {
            Background = new SolidColorBrush(Color.FromArgb(0x73, 0xFF, 0xD6, 0x0A)),
            Foreground = new SolidColorBrush(IsDark ? Colors.White : Colors.Black),
        };
        foreach (var match in row.Found.Where(m => m != row.CurrentFound))
        {
            others.Ranges.Add(new TextRange { StartIndex = offset + match.Start, Length = match.Length });
        }
        Body.TextHighlighters.Add(others);
        if (row.CurrentFound is { } current)
        {
            var mark = new TextHighlighter
            {
                Background = new SolidColorBrush(Accent(IsDark ? "SystemAccentColorLight2" : "SystemAccentColorDark1")),
                Foreground = new SolidColorBrush(IsDark ? Colors.Black : Colors.White),
            };
            mark.Ranges.Add(new TextRange { StartIndex = offset + current.Start, Length = current.Length });
            Body.TextHighlighters.Add(mark);
        }
    }

    private static Color Accent(string key) => (Color)Application.Current.Resources[key];

    private void OnTapped(object sender, TappedRoutedEventArgs e)
    {
        if (Row is { } row)
        {
            Activated?.Invoke(this, row);
        }
    }
}
