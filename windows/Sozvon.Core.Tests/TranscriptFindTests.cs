using Sozvon.Core.Calls;

namespace Sozvon.Core.Tests;

/// <summary>Find inside a transcript: what matches, in what order, and how Next and Previous wrap.</summary>
public class TranscriptFindTests
{
    private static List<(int Line, string Text)> Found(string query, params string[] lines) =>
        TranscriptFind.Matches(query, lines).Select(m => (m.Line, lines[m.Line].Substring(m.Start, m.Length))).ToList();

    [Fact]
    public void FindsEveryOccurrenceInReadingOrder()
    {
        var found = Found("счёт", "один счёт и ещё счёт", "нет", "Счёт третий");
        Assert.Equal([0, 0, 2], found.Select(f => f.Line));
        // The matched text is the transcript's own.
        Assert.Equal(["счёт", "счёт", "Счёт"], found.Select(f => f.Text));
    }

    [Fact]
    public void IgnoresCaseAndTheDotsOfYo()
    {
        Assert.Single(Found("счет", "Счёт"));
        Assert.Single(Found("СЧЁТ", "счет"));
        Assert.Equal("Счёт", Found("счет", "за Счёт")[0].Text);
    }

    [Fact]
    public void BlankQueryFindsNothing()
    {
        Assert.Empty(Found("", "text"));
        Assert.Empty(Found("   ", "a  b"));
    }

    [Fact]
    public void SurroundingSpacesInTheQueryDoNotCount()
    {
        Assert.Single(Found(" ключ ", "ключи"));
    }

    [Fact]
    public void TheEngineStarIsNotText()
    {
        Assert.Empty(Found("⭐", "важно ⭐"));
        Assert.Single(Found("важно", "важно ⭐"));
    }

    [Fact]
    public void NextAndPreviousWrapAround()
    {
        Assert.Equal(0, TranscriptFind.Step(2, 1, 3));
        Assert.Equal(2, TranscriptFind.Step(0, -1, 3));
        Assert.Equal(2, TranscriptFind.Step(1, 1, 3));
        Assert.Equal(0, TranscriptFind.Step(5, 1, 0)); // nothing found
    }
}
