using Sozvon.Core.Calls;

namespace Sozvon.Core.Tests;

/// <summary>The search across calls: title, project and names, as loose as the find inside a transcript.</summary>
public class CallSearchTests
{
    [Fact]
    public void IgnoresCaseAndTheDotsOfYo()
    {
        Assert.True(CallSearch.Matches("елку", ["Weekly sync про ёлку"]));
        Assert.True(CallSearch.Matches("ЁЛКИН", ["Звонок", "Сергей Ёлкин"]));
        Assert.True(CallSearch.Matches("ВЕБХУКИ", ["вебхуки для счетов"]));
        Assert.True(CallSearch.Matches("счет", ["Счёт"]));
    }

    [Fact]
    public void BlankQueryShowsEverythingAndOtherWordsNothing()
    {
        Assert.True(CallSearch.Matches("   ", ["что угодно"]));
        Assert.True(CallSearch.Matches("", []));
        Assert.False(CallSearch.Matches("zzz", ["вебхуки", "Northwind", "Анна Петрова"]));
        Assert.True(CallSearch.Matches("  иван ", ["Анна Петрова", "Иван"]));
    }
}
