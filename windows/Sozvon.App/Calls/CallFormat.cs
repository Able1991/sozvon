using Sozvon.App.Strings;

namespace Sozvon.App.Calls;

/// <summary>Dates and durations as the list and the header show them.</summary>
public static class CallFormat
{
    public static string Duration(double seconds)
    {
        if (seconds < 60)
        {
            return Loc.IsRussian ? "<1 мин" : "<1 min";
        }
        var minutes = (int)Math.Round(seconds / 60);
        if (minutes < 60)
        {
            return Loc.IsRussian ? $"{minutes} мин" : $"{minutes} min";
        }
        return Loc.IsRussian ? $"{minutes / 60} ч {minutes % 60:00} мин" : $"{minutes / 60} h {minutes % 60:00} min";
    }

    public static string Clock(double seconds)
    {
        var time = TimeSpan.FromSeconds(Math.Max(0, seconds));
        return time.TotalHours >= 1 ? time.ToString(@"h\:mm\:ss") : time.ToString(@"m\:ss");
    }

    public static string DayGroup(DateTimeOffset? at)
    {
        if (at is null)
        {
            return Loc.L("Без даты");
        }
        var day = at.Value.LocalDateTime.Date;
        var today = DateTime.Now.Date;
        if (day == today)
        {
            return Loc.L("Сегодня");
        }
        if (day == today.AddDays(-1))
        {
            return Loc.L("Вчера");
        }
        return day.ToString(Loc.IsRussian ? "d MMMM yyyy 'г.'" : "MMMM d, yyyy", Loc.Culture);
    }

    public static string Time(DateTimeOffset? at) => at?.LocalDateTime.ToString("HH:mm", Loc.Culture) ?? "";

    public static string DateAndTime(DateTimeOffset? at) =>
        at?.LocalDateTime.ToString(Loc.IsRussian ? "d MMMM 'в' HH:mm" : "MMMM d 'at' HH:mm", Loc.Culture) ?? "";

    public static string Meta(CallRecord call)
    {
        var parts = new[] { call.ProjectTitle, DateAndTime(call.CreatedAt), call.DurationSeconds > 0 ? Duration(call.DurationSeconds) : "" };
        return string.Join(" · ", parts.Where(p => p.Length > 0));
    }
}
