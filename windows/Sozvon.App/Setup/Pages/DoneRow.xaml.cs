using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Sozvon.App.Setup.Pages;

/// <summary>A line of the "engine installed" card; the check mark means that part really is in place.</summary>
public sealed partial class DoneRow : UserControl
{
    public enum Mark { None, Done, Problem, Working }

    public DoneRow(string glyph, string title, string detail, bool isDone) : this(glyph, title, detail, isDone ? Mark.Done : Mark.None)
    {
    }

    public DoneRow(string glyph, string title, string detail, Mark mark)
    {
        InitializeComponent();
        RowIcon.Glyph = glyph;
        RowTitle.Text = title;
        RowDetail.Text = detail;
        RowCheck.Visibility = mark == Mark.Done ? Visibility.Visible : Visibility.Collapsed;
        RowWarning.Visibility = mark == Mark.Problem ? Visibility.Visible : Visibility.Collapsed;
        RowProgress.Visibility = mark == Mark.Working ? Visibility.Visible : Visibility.Collapsed;
        RowProgress.IsActive = mark == Mark.Working;
    }
}
