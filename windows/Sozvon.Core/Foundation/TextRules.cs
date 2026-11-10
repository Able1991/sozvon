using System.Globalization;

namespace Sozvon.Core.Foundation;

/// <summary>Small text rules shared by the call and project code.</summary>
public static class TextRules
{
    /// <summary>"Anna, Ivan\nOleg" becomes ["Anna", "Ivan", "Oleg"]. A WinUI text box breaks lines with "\r" alone.</summary>
    public static List<string> SplitList(string text) =>
        text.Split([',', '\n', '\r'], StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries).ToList();

    /// <summary>"Anna, Oleg +4". When only one name would be hidden, everyone is shown.</summary>
    public static string ShortPeople(IReadOnlyList<string> names, int max = 2)
    {
        if (names.Count <= max + 1) return string.Join(", ", names);
        return string.Join(", ", names.Take(max)) + $" +{names.Count - max}";
    }

    /// <summary>Words separated by exactly one space.</summary>
    public static string Squeeze(string text) =>
        string.Join(' ', text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));

    /// <summary>The first <paramref name="count"/> visible characters, never cut inside one.</summary>
    public static string Prefix(string text, int count)
    {
        if (count <= 0) return "";
        var info = new StringInfo(text);
        return info.LengthInTextElements <= count ? text : info.SubstringByTextElements(0, count);
    }
}
