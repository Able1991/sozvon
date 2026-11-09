using System.Globalization;

namespace Sozvon.Core.Foundation;

/// <summary>The timestamps of call.json: UTC, ISO 8601.</summary>
public static class Iso8601
{
    private static readonly string[] Formats =
    [
        "yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mm:ss.FFFFFFF'Z'",
        "yyyy-MM-dd'T'HH:mm:sszzz", "yyyy-MM-dd'T'HH:mm:ss.FFFFFFFzzz",
    ];

    public static string Seconds(DateTimeOffset at) =>
        at.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);

    public static string Milliseconds(DateTimeOffset at) =>
        at.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);

    public static DateTimeOffset? Parse(string? text) =>
        DateTimeOffset.TryParseExact(text, Formats, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var at)
            ? at : null;
}
