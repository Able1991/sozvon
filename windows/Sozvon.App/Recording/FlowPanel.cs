using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;

namespace Sozvon.App.Recording;

/// <summary>Lays children out in rows, left to right, wrapping at the available width.</summary>
public sealed partial class FlowPanel : Panel
{
    private const double Spacing = 8;

    protected override Size MeasureOverride(Size availableSize)
    {
        var (width, height) = Place(availableSize.Width, arrange: false);
        return new Size(width, height);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        Place(finalSize.Width, arrange: true);
        return finalSize;
    }

    private (double Width, double Height) Place(double limit, bool arrange)
    {
        double x = 0, y = 0, rowHeight = 0, widest = 0;
        foreach (var child in Children)
        {
            if (!arrange)
            {
                child.Measure(new Size(limit, double.PositiveInfinity));
            }
            var size = child.DesiredSize;
            if (x > 0 && x + size.Width > limit)
            {
                x = 0;
                y += rowHeight + Spacing;
                rowHeight = 0;
            }
            if (arrange)
            {
                child.Arrange(new Rect(x, y, size.Width, size.Height));
            }
            x += size.Width + Spacing;
            widest = Math.Max(widest, x - Spacing);
            rowHeight = Math.Max(rowHeight, size.Height);
        }
        return (widest, y + rowHeight);
    }
}
