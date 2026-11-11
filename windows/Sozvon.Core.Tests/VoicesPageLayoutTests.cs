using System.Xml.Linq;

namespace Sozvon.Core.Tests;

/// <summary>
/// The saved voices list rebuilds its rows after every voice.py run and reuses the row containers: anything a row's
/// controls take from their row has to follow the row, not the moment the control was first loaded.
/// </summary>
public sealed class VoicesPageLayoutTests
{
    private static readonly XNamespace Ui = "http://schemas.microsoft.com/winfx/2006/xaml/presentation";

    private static XElement DeleteButton()
    {
        var path = Path.Combine(Repo.Root(), "windows", "Sozvon.App", "VoicePrints", "VoicesPage.xaml");
        return XDocument.Load(path).Descendants(Ui + "DataTemplate").Single().Descendants(Ui + "Button").Single();
    }

    /// <summary>
    /// The trash button used to get its question and its record when it was loaded: a reused row asked
    /// «Удалить голос «Zira Lee»?» on David's row and deleted Zira, or another voice that had left the list.
    /// </summary>
    [Fact]
    public void RowDeleteButtonAsksAboutItsRowWhenClicked()
    {
        var button = DeleteButton();
        Assert.Null(button.Attribute("Loaded"));
        Assert.NotNull(button.Attribute("Click"));
    }

    /// <summary>
    /// The caption style wraps by default: a long project title spread the row's details over two lines instead of
    /// ending in an ellipsis.
    /// </summary>
    [Fact]
    public void RowTextsStayOnOneLineWithAnEllipsis()
    {
        var path = Path.Combine(Repo.Root(), "windows", "Sozvon.App", "VoicePrints", "VoicesPage.xaml");
        var texts = XDocument.Load(path).Descendants(Ui + "DataTemplate").Single().Descendants(Ui + "TextBlock").ToList();
        Assert.Equal(2, texts.Count);
        foreach (var text in texts)
        {
            Assert.Equal("NoWrap", (string?)text.Attribute("TextWrapping"));
            Assert.Equal("CharacterEllipsis", (string?)text.Attribute("TextTrimming"));
        }
    }

    [Fact]
    public void RowDeleteButtonIsEnabledFromItsRow()
    {
        Assert.Equal("{x:Bind CanDelete}", (string?)DeleteButton().Attribute("IsEnabled"));
    }
}
