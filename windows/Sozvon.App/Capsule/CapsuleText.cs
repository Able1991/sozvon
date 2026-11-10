using System.Globalization;

namespace Sozvon.App.Capsule;

/// <summary>The capsule's strings, the same wording as the Mac app.</summary>
internal static class CapsuleText
{
    // The app's language from Settings, not the system's: read on every call, it is set once at startup.
    private static bool Russian => Strings.Loc.IsRussian;

    private static string T(string ru, string en) => Russian ? ru : en;

    public static string Record => T("Записать", "Record");
    public static string Starting => T("Запуск…", "Starting…");
    public static string Processing => T("Расшифровка…", "Transcribing…");
    public static string Saved => T("Записано", "Recorded");
    public static string SavedMinutes(int minutes) => T($"Записано · {minutes} мин", $"Recorded · {minutes} min");
    public static string StopIn(int seconds) => T($"Стоп через {seconds} с", $"Stop in {seconds} s");
    public static string Continue => T("Продолжить", "Continue");
    public static string TellOthers => T("Скажи собеседникам, что идёт запись", "Tell the others you are recording");
    public static string MicSilent(string time) => T($"Тебя не слышно {time}", $"You can't be heard {time}");
    public static string SystemSilent(string time) => T($"Их не слышно {time}", $"They can't be heard {time}");
    public static string Prompt(string app) => T($"Идёт звонок в {app}. Записать?", $"A call is on in {app}. Record?");
    public static string PromptAuto(string app, int seconds) => T($"Звонок в {app} · запись через {seconds} с", $"Call in {app} · recording in {seconds} s");
    public static string NotNow => T("Не сейчас", "Not now");
    public static string RecordNow => T("Записать сейчас", "Record now");
    public static string DontRecord => T("Не записывать", "Don't record");
    public static string Hide => T("Скрыть панель", "Hide panel");
    public static string Mark => T("Отметить важное", "Mark as important");
    public static string Stop => T("Остановить", "Stop");
}
