using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Sozvon.App.Calls;

public sealed partial class SummaryPieceSelector : DataTemplateSelector
{
    public DataTemplate? Paragraph { get; set; }
    public DataTemplate? Heading { get; set; }
    public DataTemplate? Bullet { get; set; }
    public DataTemplate? Task { get; set; }

    protected override DataTemplate? SelectTemplateCore(object item) => ((SummaryPiece)item).Kind switch
    {
        SummaryPieceKind.Heading => Heading,
        SummaryPieceKind.Bullet => Bullet,
        SummaryPieceKind.Task => Task,
        _ => Paragraph,
    };

    protected override DataTemplate? SelectTemplateCore(object item, DependencyObject container) => SelectTemplateCore(item);
}
