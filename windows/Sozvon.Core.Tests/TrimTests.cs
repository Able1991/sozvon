using System.Text.Json.Nodes;
using Sozvon.Core.Calls;
using Sozvon.Core.Engine;
using Sozvon.Core.Foundation;

namespace Sozvon.Core.Tests;

/// <summary>Trim a recording, as on the Mac (TrimTests, TrimEditingTests, WaveformTests, SpeedBookTests, SleepGuardTests).</summary>
public sealed class TrimTests : TempFolders
{
    private static JsonObject Json(string text) => JsonNode.Parse(text)!.AsObject();

    [Fact]
    public void TheHintComesFromTheSilence()
    {
        var h = Trim.Hint(Json("""{"silence": {"head": 372.0, "tail": 10.0}}"""), 3600)!;
        Assert.Equal((370.0, 3600.0, 6, 0), (h.Start, h.End, h.HeadMinutes, h.TailMinutes));
        Assert.Null(Trim.Hint(Json("""{"silence": {"head": 59.0, "tail": 59.0}}"""), 3600));
        Assert.Null(Trim.Hint(Json("""{"silence": {"head": 372.0, "tail": 0.0}, "trim_hint_dismissed": true}"""), 3600));
        Assert.Null(Trim.Hint(Json("{}"), 3600));
    }

    [Fact]
    public void TheTailAndBothEnds()
    {
        var t = Trim.Hint(Json("""{"silence": {"head": 5.0, "tail": 300.0}}"""), 1000)!;
        Assert.Equal((0.0, 702.0, 0, 5), (t.Start, t.End, t.HeadMinutes, t.TailMinutes));
        var b = Trim.Hint(Json("""{"silence": {"head": 60.0, "tail": 245.0}}"""), 1000)!;
        Assert.Equal((58.0, 757.0, 1, 4), (b.Start, b.End, b.HeadMinutes, b.TailMinutes));
        // Silence longer than the call: no hint.
        Assert.Null(Trim.Hint(Json("""{"silence": {"head": 1.0, "tail": 100.0}}"""), 50));
    }

    [Fact]
    public void WhyTrimIsOffInItsOrder()
    {
        var all = Json("""{"demo": true, "audio_removed_at": "x", "audio": {"mic_seconds": 5.0}}""");
        Assert.Equal(TrimUnavailable.Busy, Trim.Unavailable(all, hasAudio: false, busy: true));
        Assert.Equal(TrimUnavailable.Demo, Trim.Unavailable(all, false, false));
        all.Remove("demo");
        Assert.Equal(TrimUnavailable.AudioRemoved, Trim.Unavailable(all, false, false));
        all.Remove("audio_removed_at");
        Assert.Equal(TrimUnavailable.NoAudio, Trim.Unavailable(all, false, false));
        Assert.Equal(TrimUnavailable.TooShort, Trim.Unavailable(all, true, false));
        // The longer track decides: 40 s on the system track is long enough.
        Assert.Null(Trim.Unavailable(Json("""{"audio": {"mic_seconds": 5.0, "system_seconds": 40.0}}"""), true, false));
        Assert.All(Enum.GetValues<TrimUnavailable>(), why => Assert.NotEmpty(Trim.Reason(why)));
    }

    [Fact]
    public void ACallCarriesItsTrimState()
    {
        var dir = Path.Combine(Calls, "2026-11-05 10-00");
        WriteText(Path.Combine(dir, "call.json"), """{"schema": 1, "id": "2026-11-05 10-00", "status": "done", "audio": {"mic_seconds": 3600.0}, "silence": {"head": 372.0, "tail": 0.0}}""");
        WriteText(Path.Combine(dir, "mic.m4a"), "x");
        var call = Call.Load(dir)!;
        Assert.Null(call.TrimUnavailable(busy: false));
        Assert.Equal(TrimUnavailable.Busy, call.TrimUnavailable(busy: true));
        Assert.Equal(new TrimHint(370, 3600, 6, 0), call.TrimHint);

        Assert.True(Trim.DismissHint(dir));
        Assert.Null(Call.Load(dir)!.TrimHint);

        var short_ = Path.Combine(Calls, "2026-11-05 11-00");
        WriteText(Path.Combine(short_, "call.json"), """{"schema": 1, "id": "2026-11-05 11-00", "status": "done", "audio": {"mic_seconds": 20.0}}""");
        WriteText(Path.Combine(short_, "mic.m4a"), "x");
        Assert.Equal(TrimUnavailable.TooShort, Call.Load(short_)!.TrimUnavailable(busy: false));
    }

    [Fact]
    public void ArrowsMoveTheTakenHandleByOneOrTenSeconds()
    {
        var s = new TrimState(3900, new TrimHint(372, 3520, 6, 6));
        Assert.True(s.Move(TrimHandle.Start, +1, shift: false, 3900));
        Assert.Equal(373, s.Start);
        s.Move(TrimHandle.Start, +1, shift: true, 3900);
        Assert.Equal(383, s.Start);
        s.Move(TrimHandle.End, -1, shift: false, 3900);
        Assert.Equal(3519, s.End);
        s.Move(TrimHandle.End, -1, shift: true, 3900);
        Assert.Equal(3509, s.End);
    }

    [Fact]
    public void HandlesStayInsideTheCallAndKeepTheMinimumRange()
    {
        var s = new TrimState(100, null);
        s.Move(TrimHandle.Start, -1, shift: true, 100);
        Assert.Equal(0, s.Start);
        s.Move(TrimHandle.End, +1, shift: true, 100);
        Assert.Equal(100, s.End);
        s.Set(TrimHandle.Start, 95, 100);
        Assert.Equal(100 - Trim.MinRangeSeconds, s.Start);
        s.Set(TrimHandle.End, 0, 100);
        Assert.Equal(100, s.End);
        s = new TrimState(100, new TrimHint(20, 100, 0, 0));
        s.Set(TrimHandle.End, 0, 100);
        Assert.Equal(20 + Trim.MinRangeSeconds, s.End);
    }

    [Fact]
    public void CancelGoesBackAStepAndTheCutCannotBeStopped()
    {
        var s = new TrimState(60, new TrimHint(10, 50, 0, 0)) { Phase = TrimPhase.Confirming };
        Assert.False(s.Move(TrimHandle.Start, +1, false, 60));
        Assert.Equal(10, s.Start);
        Assert.Equal(TrimCancelResult.BackToEditing, s.Cancel());
        Assert.Equal(TrimCancelResult.Close, s.Cancel());
        s.Phase = TrimPhase.Working;
        Assert.Equal(TrimCancelResult.None, s.Cancel());
        Assert.False(s.Move(TrimHandle.End, -1, false, 60));
    }

    [Fact]
    public void TheWaveformIsTheLoudestSamplePerBinNormalized()
    {
        Assert.Equal([0.5f, 1f], WaveformEnvelope.Peaks([0.1f, -0.2f, 0.4f, -0.1f], 2));
        Assert.Equal([0f, 0f, 0f], WaveformEnvelope.Peaks([0f, 0f], 3));
        var e = new WaveformEnvelope(4, 4);
        e.Add([1f, 1f], start: -1, rate: 1);   // one sample before the call's start
        e.Add([0.5f, 0.5f], start: 3, rate: 1); // one at the call's end
        Assert.Equal([1f, 0f, 0f, 0.5f], e.Peaks());
    }

    [Fact]
    public void TheSpeedBookIgnoresShortCallsAndKeepsTheLastTen()
    {
        var b = new SpeedBook();
        b.Record("turbo", 599, 100);
        Assert.Null(b.Factor("turbo"));
        for (var i = 1; i <= 11; i++) b.Record("turbo", 600, i * 60);
        Assert.Equal(Enumerable.Range(2, 10).Average(i => i / 10.0), b.Factor("turbo")!.Value, 9);
        Assert.Null(b.Estimate("large-v3", 1200));
        Assert.Equal("turbo", b.LastModel);
        b.Save(Data);
        Assert.Equal(b.Factor("turbo"), SpeedBook.Load(Data).Factor("turbo"));
        WriteText(Path.Combine(Data, SpeedBook.FileName), "{ broken");
        Assert.Null(SpeedBook.Load(Data).LastModel);
    }

    [Fact]
    public void TheEstimateReadsAsOnTheMac()
    {
        static string L(string key, object[] args)
        {
            var s = key;
            foreach (var a in args)
            {
                var at = s.IndexOf("%@", StringComparison.Ordinal);
                s = s[..at] + a + s[(at + 2)..];
            }
            return s;
        }
        Assert.Equal("≈ 1 мин", EstimateText.Duration(90, L));
        Assert.Equal("≈ 12 мин", EstimateText.Duration(12 * 60 + 20, L));
        Assert.Equal("≈ 1 ч 10 мин", EstimateText.Duration(70 * 60, L));
        Assert.Equal("≈ 1 ч", EstimateText.Duration(3600, L));
        Assert.Equal("≈ 59 мин", EstimateText.Duration(3540, L));
        Assert.All(new[] { 3570.0, 3585, 3599 }, s => Assert.Equal("≈ 1 ч", EstimateText.Duration(s, L)));
        Assert.Equal("почти готово", EstimateText.Remaining(300, 400, L));
        Assert.Equal("осталось ≈ 10 мин", EstimateText.Remaining(900, 300, L));
    }

    [Fact]
    public void TheSleepGuardHoldsOnlyWhileThereIsSomethingToDo()
    {
        var calls = new List<string>();
        var guard = new SleepGuard(() => calls.Add("hold"), () => calls.Add("release"));
        guard.Update(recording: false, hasWork: false);
        guard.Update(recording: true, hasWork: false);
        guard.Update(recording: true, hasWork: true);
        guard.Update(recording: false, hasWork: true);
        Assert.True(guard.IsHeld);
        guard.Update(recording: false, hasWork: false);
        guard.Update(recording: false, hasWork: false);
        Assert.Equal(["hold", "release"], calls);
        Assert.False(guard.IsHeld);
    }
}
