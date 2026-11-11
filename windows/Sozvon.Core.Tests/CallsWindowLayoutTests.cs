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

    /// <summary>
    /// The row's second line: a horizontal StackPanel gives the subtitle all the width it asks for, so a long project and
    /// people list was cut mid-word with no ellipsis and pushed the «Без саммари» mark out of the row. In a Grid the
    /// subtitle takes the star column and trims, and the mark keeps its own Auto column.
    /// </summary>
    [Fact]
    public void ListSubtitleTrimsAndKeepsTheMarkVisible()
    {
        var path = Path.Combine(Repo.Root(), "windows", "Sozvon.App", "Calls", "CallsPage.xaml");
        var subtitles = XDocument.Load(path).Descendants(Ui + "TextBlock")
            .Where(e => (string?)e.Attribute("Text") == "{x:Bind Subtitle}").ToList();
        Assert.NotEmpty(subtitles);
        static string Column(XElement e) => (string?)e.Attribute("Grid.Column") ?? "0";
        foreach (var subtitle in subtitles)
        {
            var line = subtitle.Parent!;
            Assert.Equal(Ui + "Grid", line.Name);
            var columns = line.Element(Ui + "Grid.ColumnDefinitions")!.Elements().ToList();
            Assert.Equal("*", (string?)columns[int.Parse(Column(subtitle))].Attribute("Width"));
            var badge = line.Elements(Ui + "Border").Single(b => b.Descendants(Ui + "TextBlock").Any(t => (string?)t.Attribute("Text") == "{x:Bind Badge}"));
            Assert.Equal("Auto", (string?)columns[int.Parse(Column(badge))].Attribute("Width"));
        }
    }

    /// <summary>
    /// The call form's project box: "Northwind · редизайн" was cut mid-word with no ellipsis, since the item's title sat in
    /// a horizontal StackPanel that never trims. The title takes a star column of a Grid and trims.
    /// </summary>
    [Fact]
    public void FormProjectTitleTrimsWithAnEllipsis()
    {
        var path = Path.Combine(Repo.Root(), "windows", "Sozvon.App", "Recording", "CallInfoWindow.xaml");
        var title = XDocument.Load(path).Descendants(Ui + "DataTemplate")
            .Single(t => (string?)t.Attribute(XName.Get("Key", "http://schemas.microsoft.com/winfx/2006/xaml")) == "ProjectTemplate")
            .Descendants(Ui + "TextBlock").Single(t => (string?)t.Attribute("Text") == "{x:Bind Title}");
        Assert.Equal("CharacterEllipsis", (string?)title.Attribute("TextTrimming"));
        var line = title.Parent!;
        Assert.Equal(Ui + "Grid", line.Name);
        var columns = line.Element(Ui + "Grid.ColumnDefinitions")!.Elements().ToList();
        Assert.Equal("*", (string?)columns[int.Parse((string?)title.Attribute("Grid.Column") ?? "0")].Attribute("Width"));
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
