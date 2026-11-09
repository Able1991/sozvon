using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Sozvon.App.Calls;

/// <summary>Picks the line template with the speaker's voice colour, which is a theme resource.</summary>
public sealed partial class TranscriptLineSelector : DataTemplateSelector
{
    public DataTemplate? Mine { get; set; }
    public DataTemplate? Theirs { get; set; }

    protected override DataTemplate? SelectTemplateCore(object item) => ((TranscriptLine)item).IsMe ? Mine : Theirs;

    protected override DataTemplate? SelectTemplateCore(object item, DependencyObject container) => SelectTemplateCore(item);
}
