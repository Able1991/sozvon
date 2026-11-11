using System.Xml.Linq;

namespace Sozvon.Core.Tests;

/// <summary>
/// Long texts of the Calls window: the list keeps a title on one line with an ellipsis (the strong text style wraps by
/// default), and the card's meta line wraps instead of losing the duration behind a long project name.
/// </summary>
public sealed class CallsWindowLayoutTests
{
    private static readonly XNamespace Ui = "http://schemas.microsoft.com/winfx/2006/xaml/presentation";

    private static XElement TextBlockBoundTo(string file, string binding, string? style = null)
    {
        var path = Path.Combine(Repo.Root(), "windows", "Sozvon.App", "Calls", file);
        return XDocument.Load(path).Descendants(Ui + "TextBlock")
            .Single(e => ((string?)e.Attribute("Text"))?.StartsWith("{x:Bind " + binding, StringComparison.Ordinal) == true
                         && (style is null || ((string?)e.Attribute("Style"))?.Contains(style, StringComparison.Ordinal) == true));
    }

    [Fact]
    public void ListTitleStaysOnOneLineWithAnEllipsis()
    {
        // The row's title; the day header binds its own Title in a caption style.
        var title = TextBlockBoundTo("CallsPage.xaml", "Title}", "BodyStrong");
        Assert.Equal("NoWrap", (string?)title.Attribute("TextWrapping"));
        Assert.Equal("CharacterEllipsis", (string?)title.Attribute("TextTrimming"));
    }

    /// <summary>In a narrow window "Поделиться" used to lie on top of the "Расшифровка" tab.</summary>
    [Fact]
    public void TabsAndHeaderButtonsDoNotShareAColumn()
    {
        var path = Path.Combine(Repo.Root(), "windows", "Sozvon.App", "Calls", "CallDetailView.xaml");
        var tabs = XDocument.Load(path).Descendants(Ui + "SelectorBar").Single();
        var header = tabs.Parent!;
        Assert.Equal(2, header.Element(Ui + "Grid.ColumnDefinitions")?.Elements().Count());
        var buttons = header.Elements(Ui + "StackPanel").Single();
        static string Column(XElement e) => (string?)e.Attribute("Grid.Column") ?? "0";
        Assert.NotEqual(Column(tabs), Column(buttons));
    }

    [Fact]
    public void CardMetaLineWraps()
    {
        Assert.Equal("Wrap", (string?)TextBlockBoundTo("CallDetailView.xaml", "ViewModel.Meta").Attribute("TextWrapping"));
    }
}
