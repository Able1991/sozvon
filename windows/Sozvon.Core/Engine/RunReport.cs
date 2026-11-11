using Sozvon.Core.Calls;
using Sozvon.Core.Foundation;

namespace Sozvon.Core.Engine;

/// <summary>A notification: its title and its line.</summary>
public sealed record RunNotice(string Title, string Message);

/// <summary>
/// What the app says when an engine run ends, as the Mac's ProcessingController (report, summaryFinished): the call is
/// ready, ready without its summary and why, or why it failed. Without it a failed run says nothing beyond a red row.
/// </summary>
public static class RunReport
{
    /// <param name="l">The process's string table, keys in Russian as on the Mac.</param>
    /// <returns>Null for a run the app itself stopped (a quit, a call taken back).</returns>
    public static RunNotice? For(CallRunFinished run, Func<string, object[], string> l)
    {
        if (run.Stopped) return null;
        string L(string key) => l(key, []);
        string OrLog(string message) => message.Trim().Length > 0 ? TextRules.Squeeze(message) : L("Подробности в process.log");
        var name = Path.GetFileName(Path.TrimEndingDirectorySeparator(run.Dir));
        if (run.Kind == ProcessingKind.SummaryOnly)
        {
            return run.Outcome.IsOk
                ? new(L("Саммари обновлено"), name)
                : new(L("Не получилось обновить саммари"), OrLog(run.Outcome.Message));
        }
        return run.Outcome switch
        {
            RunOutcome.Ok => Done(run.Dir, name, L, OrLog),
            RunOutcome.NoAudio => new(L("В записи нет звука"), L("Ни одна дорожка не записалась. Проверь доступ к микрофону в параметрах Windows.")),
            RunOutcome.EngineBroken broken => new(L("Движок сломан"), OrLog(broken.Message)),
            RunOutcome.ModelMissing missing => new(L("Модель не скачана"), OrLog(missing.Message)),
            RunOutcome.Damaged => new(L("Запись повреждена"), L("Не удалось прочитать дорожки звонка. Подробности в process.log")),
            _ => new(L("Не получилось расшифровать"), OrLog(run.Outcome.Message)),
        };
    }

    private static RunNotice Done(string dir, string name, Func<string, string> L, Func<string, string> orLog)
    {
        if (!File.Exists(Path.Combine(dir, "transcript.md"))) return new(L("Не получилось расшифровать"), L("Движок не оставил transcript.md"));
        string? why;
        try
        {
            why = CallWarnings.Summary(CallFile.Read(dir));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            why = null;
        }
        return why is null ? new(L("Расшифровка готова"), name) : new(L("Готово, но саммари не получилось"), orLog(why));
    }
}
