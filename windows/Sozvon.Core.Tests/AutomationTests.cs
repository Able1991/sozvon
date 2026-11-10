using Sozvon.Core.Automation;

namespace Sozvon.Core.Tests;

public class CallDetectorTests
{
    private const int OwnPid = 42;
    private static readonly DateTimeOffset T0 = new(2026, 11, 10, 12, 0, 0, TimeSpan.Zero);
    private static readonly MicClient Zoom = new(100, "Zoom");
    private static readonly MicClient Chrome = new(200, "chrome.exe");
    private static readonly MicClient Recorder = new(300, "SoundRecorder");

    private static DateTimeOffset At(double seconds) => T0.AddSeconds(seconds);

    [Fact]
    public void KnownAppsHelpersAndStoreApps()
    {
        Assert.Equal("Zoom", CallApps.App(Zoom)?.Name);
        Assert.Equal("Chrome", CallApps.App(Chrome)?.Name);
        Assert.Equal("Microsoft Teams", CallApps.App(new(1, "ms-teams"))?.Name);
        Assert.Equal("Telegram", CallApps.App(new(1, "Telegram"))?.Name);
        Assert.Equal("Discord", CallApps.App(new(1, "Discord"))?.Name);
        Assert.Equal("Skype", CallApps.App(new(1, "Skype"))?.Name);
        Assert.Equal("Slack", CallApps.App(new(1, "slack"))?.Name);
        Assert.Equal("WhatsApp", CallApps.App(new(1, "WhatsApp.Root"))?.Name);
        Assert.Equal("Edge", CallApps.App(new(1, "msedge"))?.Name);
        Assert.Equal("Firefox", CallApps.App(new(1, "firefox"))?.Name);
        Assert.Equal("Yandex Browser", CallApps.App(new(1, "browser", @"C:\Users\a\AppData\Local\Yandex\YandexBrowser\Application\browser.exe"))?.Name);
        Assert.Null(CallApps.App(new(1, "browser", @"C:\Tools\browser.exe")));
        Assert.Null(CallApps.App(Recorder));
        Assert.Null(CallApps.App(new(1, "Sozvon.App")));
        Assert.Null(CallApps.App(new(1, "zoomer")));
        Assert.Equal("Microsoft Teams", CallApps.App(new(0, "", Package: "MSTeams_8wekyb3d8bbwe"))?.Name);
        Assert.Null(CallApps.App(new(0, "", Package: "Microsoft.WindowsSoundRecorder_8wekyb3d8bbwe")));
    }

    [Fact]
    public void WebViewCountsOnlyAsTheKnownAppThatStartedIt()
    {
        Assert.Equal("Microsoft Teams", CallApps.App(new(1, "msedgewebview2", ParentName: "ms-teams.exe"))?.Name);
        Assert.Null(CallApps.App(new(1, "msedgewebview2", ParentName: "Widgets.exe")));
        Assert.Null(CallApps.App(new(1, "msedgewebview2", ParentName: "msedgewebview2")));
        Assert.Null(CallApps.App(new(1, "msedgewebview2")));
    }

    [Fact]
    public void Debounce()
    {
        var d = new CallDetector(OwnPid);
        Assert.Null(d.Update([Zoom], At(0), busy: false));
        Assert.Null(d.Update([Zoom], At(4.9), busy: false));
        Assert.Equal("Zoom", d.Update([Zoom], At(5), busy: false)?.Name);
    }

    [Fact]
    public void ReleaseRestartsTheDebounceAndHidesThePrompt()
    {
        var d = new CallDetector(OwnPid);
        d.Update([Zoom], At(0), busy: false);
        d.Update([], At(3), busy: false);
        Assert.Null(d.Update([Zoom], At(6), busy: false));
        Assert.NotNull(d.Update([Zoom], At(11), busy: false));
        Assert.Null(d.Update([], At(12), busy: false));
        Assert.Null(d.Prompt);
    }

    [Fact]
    public void IgnoresItselfAndUnknownApps()
    {
        var d = new CallDetector(OwnPid);
        MicClient[] clients = [new(OwnPid, "Zoom"), Recorder, new(43, "Sozvon.App")];
        d.Update(clients, At(0), busy: false);
        Assert.Null(d.Update(clients, At(60), busy: false));
        Assert.Empty(d.OnMic);
    }

    [Fact]
    public void NotNowSuppressesUntilRelease()
    {
        var d = new CallDetector(OwnPid);
        d.Update([Zoom], At(0), busy: false);
        Assert.NotNull(d.Update([Zoom], At(5), busy: false));
        d.Dismiss();
        Assert.Null(d.Update([Zoom], At(600), busy: false));
        d.Update([], At(601), busy: false);
        d.Update([Zoom], At(700), busy: false);
        Assert.Equal("Zoom", d.Update([Zoom], At(705), busy: false)?.Name);
    }

    [Fact]
    public void NotNowForOneAppLeavesOthersOldestFirst()
    {
        var d = new CallDetector(OwnPid);
        d.Update([Zoom], At(0), busy: false);
        d.Update([Zoom, Chrome], At(2), busy: false);
        Assert.Equal("Zoom", d.Update([Zoom, Chrome], At(7), busy: false)?.Name);
        d.Dismiss();
        Assert.Equal("Chrome", d.Update([Zoom, Chrome], At(8), busy: false)?.Name);
    }

    [Fact]
    public void BusyHidesAndSuppressesTheAppsOnTheMic()
    {
        var d = new CallDetector(OwnPid);
        d.Update([Zoom], At(0), busy: false);
        Assert.NotNull(d.Update([Zoom], At(6), busy: false));
        Assert.Null(d.Update([Zoom], At(7), busy: true));
        Assert.Null(d.Update([Zoom], At(900), busy: false));
        d.Update([], At(901), busy: false);
        d.Update([Zoom], At(1000), busy: false);
        Assert.NotNull(d.Update([Zoom], At(1005), busy: false));
    }
}

public class CallEndDetectorTests
{
    private static readonly DateTimeOffset T0 = new(2026, 11, 10, 12, 0, 0, TimeSpan.Zero);

    private static DateTimeOffset At(double seconds) => T0.AddSeconds(seconds);

    [Fact]
    public void CountsDownAfterTheCallAppLetsGo()
    {
        var e = new CallEndDetector();
        Assert.Null(e.Update(false, false, At(0)));
        Assert.Null(e.Update(true, false, At(0)));
        Assert.Null(e.Update(true, false, At(60)));
        Assert.Equal(30, e.Update(false, false, At(61)));
        Assert.Equal(10, e.Update(false, false, At(81)));
        Assert.Null(e.Update(true, false, At(82)));
        Assert.Equal(30, e.Update(false, false, At(83)));
        Assert.Equal(0, e.Update(false, false, At(120)));
    }

    [Fact]
    public void AShortUseOfTheMicDoesNotArm()
    {
        var e = new CallEndDetector();
        e.Update(true, false, At(0));
        Assert.Null(e.Update(false, false, At(5)));
        Assert.Null(e.Update(false, false, At(100)));
    }

    [Fact]
    public void TheOtherSideHeardMeansTheCallGoesOn()
    {
        var e = new CallEndDetector();
        e.Update(true, false, At(0));
        Assert.Equal(30, e.Update(false, false, At(60)));
        Assert.Null(e.Update(false, true, At(70)));
        Assert.Equal(30, e.Update(false, false, At(71)));
        Assert.Equal(0, e.Update(false, false, At(101)));
    }

    [Fact]
    public void KeepRecordingLastsForTheRestOfTheRecording()
    {
        var e = new CallEndDetector();
        e.Update(true, false, At(0));
        Assert.Equal(30, e.Update(false, false, At(60)));
        e.KeepRecording();
        Assert.Null(e.Update(false, false, At(160)));
        Assert.Null(e.Update(true, false, At(161)));
        Assert.Null(e.Update(false, false, At(400)));
    }
}

public class CallAutomationRulesTests
{
    private const int OwnPid = 42;
    private static readonly DateTimeOffset T0 = new(2026, 11, 10, 12, 0, 0, TimeSpan.Zero);
    private static readonly MicClient[] Zoom = [new(100, "Zoom")];

    private static DateTimeOffset At(double seconds) => T0.AddSeconds(seconds);

    private static CallSituation Idle(CallStartMode mode = CallStartMode.Ask, bool autoStop = false) =>
        new(mode, autoStop, Busy: false, Recording: false, OtherSideAudible: false);

    private static CallSituation Recording(bool autoStop = true, bool heard = false) =>
        new(CallStartMode.Ask, autoStop, Busy: true, Recording: true, OtherSideAudible: heard);

    [Fact]
    public void AskShowsThePromptWithoutCountdown()
    {
        var rules = new CallAutomationRules(OwnPid);
        rules.Update(Zoom, At(0), Idle());
        Assert.Equal(CallAction.None, rules.Update(Zoom, At(5), Idle()));
        Assert.Equal("Zoom", rules.Prompt?.Name);
        Assert.Null(rules.StartIn);
        Assert.Equal(CallAction.None, rules.Update(Zoom, At(600), Idle()));
    }

    [Fact]
    public void OffShowsNothingButStillSeesTheCall()
    {
        var rules = new CallAutomationRules(OwnPid);
        rules.Update(Zoom, At(0), Idle(CallStartMode.Off));
        rules.Update(Zoom, At(30), Idle(CallStartMode.Off));
        Assert.Null(rules.Prompt);
        Assert.True(rules.InCall);
    }

    [Fact]
    public void RecordCountsDownThenStarts()
    {
        var rules = new CallAutomationRules(OwnPid);
        rules.Update(Zoom, At(0), Idle(CallStartMode.Record));
        rules.Update(Zoom, At(5), Idle(CallStartMode.Record));
        Assert.Equal(CallAutomation.StartCountdown, rules.StartIn);
        rules.Update(Zoom, At(8.5), Idle(CallStartMode.Record));
        Assert.Equal(7, rules.StartIn);
        Assert.Equal(CallAction.Record, rules.Update(Zoom, At(15), Idle(CallStartMode.Record)));
        Assert.Null(rules.Prompt);
        Assert.Null(rules.StartIn);
    }

    [Fact]
    public void DontRecordCancelsTheCountdownForThisCall()
    {
        var rules = new CallAutomationRules(OwnPid);
        rules.Update(Zoom, At(0), Idle(CallStartMode.Record));
        rules.Update(Zoom, At(5), Idle(CallStartMode.Record));
        rules.NotNow();
        Assert.Null(rules.StartIn);
        Assert.Equal(CallAction.None, rules.Update(Zoom, At(60), Idle(CallStartMode.Record)));
        Assert.Null(rules.Prompt);
    }

    [Fact]
    public void ChangingTheModeDuringTheCountdownStopsIt()
    {
        var rules = new CallAutomationRules(OwnPid);
        rules.Update(Zoom, At(0), Idle(CallStartMode.Record));
        rules.Update(Zoom, At(5), Idle(CallStartMode.Record));
        rules.Update(Zoom, At(6), Idle(CallStartMode.Ask));
        Assert.Null(rules.StartIn);
        Assert.Equal(CallAction.None, rules.Update(Zoom, At(60), Idle(CallStartMode.Ask)));
        Assert.NotNull(rules.Prompt);
    }

    [Fact]
    public void StopsAfterTheGraceOnceTheCallEnds()
    {
        var rules = new CallAutomationRules(OwnPid);
        rules.Update(Zoom, At(0), Recording());
        rules.Update(Zoom, At(20), Recording());
        Assert.Equal(CallAction.None, rules.Update([], At(21), Recording()));
        Assert.Equal(CallAutomation.StopGrace, rules.StopIn);
        rules.Update([], At(40), Recording());
        Assert.Equal(11, rules.StopIn);
        Assert.Equal(CallAction.Stop, rules.Update([], At(51), Recording()));
        Assert.Null(rules.StopIn);
    }

    [Fact]
    public void NoAutomaticStopWhenItIsOffOrKept()
    {
        var off = new CallAutomationRules(OwnPid);
        off.Update(Zoom, At(0), Recording(autoStop: false));
        off.Update(Zoom, At(20), Recording(autoStop: false));
        Assert.Equal(CallAction.None, off.Update([], At(100), Recording(autoStop: false)));
        Assert.Null(off.StopIn);

        var kept = new CallAutomationRules(OwnPid);
        kept.Update(Zoom, At(0), Recording());
        kept.Update(Zoom, At(20), Recording());
        kept.Update([], At(21), Recording());
        kept.KeepRecording();
        Assert.Null(kept.StopIn);
        Assert.Equal(CallAction.None, kept.Update([], At(200), Recording()));
    }

    [Fact]
    public void ANewRecordingStartsWithAFreshEndDetector()
    {
        var rules = new CallAutomationRules(OwnPid);
        rules.Update(Zoom, At(0), Recording());
        rules.Update(Zoom, At(20), Recording());
        rules.Update([], At(21), Recording());
        rules.KeepRecording();
        rules.Update([], At(22), Idle());
        rules.Update([], At(30), Recording());
        Assert.Equal(CallAction.None, rules.Update([], At(300), Recording()));
        Assert.Null(rules.StopIn);
    }

    [Theory]
    [InlineData(0, CallStartMode.Ask)]
    [InlineData(1, CallStartMode.Record)]
    [InlineData(2, CallStartMode.Off)]
    [InlineData(7, CallStartMode.Ask)]
    [InlineData(-1, CallStartMode.Ask)]
    public void StoredModes(int stored, CallStartMode mode) => Assert.Equal(mode, CallAutomation.Mode(stored));
}
