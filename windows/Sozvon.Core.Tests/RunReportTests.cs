using System.Text.Json.Nodes;
using Sozvon.Core.Calls;
using Sozvon.Core.Engine;

namespace Sozvon.Core.Tests;

/// <summary>What the tray says when an engine run ends, as the Mac's ProcessingController.report and summaryFinished.</summary>
public sealed class RunReportTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "sozvon-runreport-" + Guid.NewGuid().ToString("N"), "2026-11-11 16-45 · запуск");

    public RunReportTests() => Directory.CreateDirectory(_dir);

    public void Dispose() => Directory.Delete(Path.GetDirectoryName(_dir)!, recursive: true);

    private static string L(string key, object[] args) => args.Length == 0 ? key : key + "|" + string.Join("|", args);

    private RunNotice? Report(RunOutcome outcome, ProcessingKind kind = ProcessingKind.Transcribe, bool stopped = false) =>
        RunReport.For(new CallRunFinished(_dir, kind, outcome, stopped), L);

    private void Write(string name, string text = "x") => File.WriteAllText(Path.Combine(_dir, name), text);

    [Fact]
    public void ADoneCallSaysItIsReadyWithTheFolderName()
    {
        Write("transcript.md");
        Write(CallFile.Name, new JsonObject { ["status"] = "done" }.ToJsonString());
        Assert.Equal(new RunNotice("Расшифровка готова", "2026-11-11 16-45 · запуск"), Report(new RunOutcome.Ok()));
    }

    [Fact]
    public void AFailedSummaryIsSaidWithTheEnginesReason()
    {
        Write("transcript.md");
        Write(CallFile.Name, """{"status":"done","warnings":[{"step":"summary","error":"claude:  not logged in\n run claude"}]}""");
        Assert.Equal(new RunNotice("Готово, но саммари не получилось", "claude: not logged in run claude"), Report(new RunOutcome.Ok()));
    }

    [Fact]
    public void AFailedSummaryWithoutAReasonPointsToTheLog()
    {
        Write("transcript.md");
        Write(CallFile.Name, """{"status":"done","warnings":[{"step":"summary"}]}""");
        Assert.Equal(new RunNotice("Готово, но саммари не получилось", "Подробности в process.log"), Report(new RunOutcome.Ok()));
    }

    [Fact]
    public void ASuccessWithoutATranscriptIsAFailure() =>
        Assert.Equal(new RunNotice("Не получилось расшифровать", "Движок не оставил transcript.md"), Report(new RunOutcome.Ok()));

    [Fact]
    public void NoAudioAsksToCheckTheMicrophoneOnWindows() =>
        Assert.Equal(new RunNotice("В записи нет звука", "Ни одна дорожка не записалась. Проверь доступ к микрофону в параметрах Windows."),
                     Report(new RunOutcome.NoAudio("в записи нет звука")));

    [Fact]
    public void AFailureSaysTheEnginesMessage() =>
        Assert.Equal(new RunNotice("Не получилось расшифровать", "CUDA out of memory"), Report(new RunOutcome.Failed(1, "CUDA out of memory")));

    [Fact]
    public void AFailureWithoutAMessagePointsToTheLog() =>
        Assert.Equal(new RunNotice("Не получилось расшифровать", "Подробности в process.log"), Report(new RunOutcome.Failed(1, "")));

    [Fact]
    public void ADamagedRecordingIsSaidSo() =>
        Assert.Equal(new RunNotice("Запись повреждена", "Не удалось прочитать дорожки звонка. Подробности в process.log"),
                     Report(new RunOutcome.Damaged("ffmpeg: moov atom not found")));

    [Fact]
    public void ABrokenEngineAndAMissingModelSayTheEnginesMessage()
    {
        Assert.Equal(new RunNotice("Движок сломан", "torch не загрузился"), Report(new RunOutcome.EngineBroken("torch не загрузился")));
        Assert.Equal(new RunNotice("Модель не скачана", "Подробности в process.log"), Report(new RunOutcome.ModelMissing("")));
    }

    [Fact]
    public void ASummaryRunSaysUpdatedOrWhyNot()
    {
        Assert.Equal(new RunNotice("Саммари обновлено", "2026-11-11 16-45 · запуск"), Report(new RunOutcome.Ok(), ProcessingKind.SummaryOnly));
        Assert.Equal(new RunNotice("Не получилось обновить саммари", "claude не найден"),
                     Report(new RunOutcome.Failed(1, "claude не найден"), ProcessingKind.SummaryOnly));
    }

    [Fact]
    public void ARunTheAppStoppedSaysNothing() => Assert.Null(Report(new RunOutcome.Failed(143, ""), stopped: true));
}
