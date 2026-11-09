using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Sozvon.App.Setup.Pages;

/// <summary>A line of the "engine installed" card; the check mark means that part really is in place.</summary>
public sealed partial class DoneRow : UserControl
{
    public DoneRow(string glyph, string title, string detail, bool isDone)
    {
        InitializeComponent();
        RowIcon.Glyph = glyph;
        RowTitle.Text = title;
        RowDetail.Text = detail;
        RowCheck.Visibility = isDone ? Visibility.Visible : Visibility.Collapsed;
    }
}
