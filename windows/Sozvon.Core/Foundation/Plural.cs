namespace Sozvon.Core.Foundation;

/// <summary>"3 проекта", "11 человек", "1 term": a number with its word, as the Mac's SZW.count.</summary>
public static class Plural
{
    public static string Count(int n, (string One, string Few, string Many) ru, (string One, string Other) en, bool russian)
    {
        if (!russian) return $"{n} {(n == 1 ? en.One : en.Other)}";
        var (tens, ones) = (Math.Abs(n) % 100, Math.Abs(n) % 10);
        var word = tens is >= 11 and <= 14 ? ru.Many : ones == 1 ? ru.One : ones is >= 2 and <= 4 ? ru.Few : ru.Many;
        return $"{n} {word}";
    }
}
