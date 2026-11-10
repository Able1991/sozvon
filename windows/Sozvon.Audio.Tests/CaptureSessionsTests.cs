using Sozvon.Audio.Capture;
using Xunit;

namespace Sozvon.Audio.Tests;

public sealed class CaptureSessionsTests
{
    [Fact]
    public void APrivacyStorePathBecomesTheProcessName()
    {
        CaptureClient client = CaptureSessions.FromStorePath(@"C:\Program Files\Zoom\bin\Zoom.exe");
        Assert.Equal("Zoom", client.ProcessName);
        Assert.Equal(@"C:\Program Files\Zoom\bin\Zoom.exe", client.ImagePath);
        Assert.Equal(0, client.ProcessId);
    }

    [Theory]
    [InlineData(133_000_000_000_000_000, 0, true)]
    [InlineData(133_000_000_000_000_000, 133_000_000_100_000_000, false)]
    [InlineData(0, 0, false)]
    public void InUseUntilTheStopIsWritten(long start, long stop, bool inUse) => Assert.Equal(inUse, CaptureSessions.InUse(start, stop));

    [Fact]
    public void AStaleDesktopEntryCountsOnlyWhileItsAppRuns()
    {
        CaptureClient[] store =
        [
            CaptureSessions.FromStorePath(@"C:\Program Files\Zoom\bin\Zoom.exe"),
            CaptureSessions.FromStorePath(@"C:\Users\a\AppData\Local\Yandex\YandexBrowser\Application\browser.exe"),
            new(0, "", Package: "MSTeams_8wekyb3d8bbwe"),
        ];
        var running = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "zoom", "explorer" };

        List<CaptureClient> left = CaptureSessions.StillRunning(store, running);

        Assert.Equal(["Zoom", ""], left.Select(c => c.ProcessName));
    }

    /// <summary>Opens the real default microphone (nothing is kept) and finds this process among its sessions.</summary>
    [LiveMicrophoneFact]
    public async Task SeesThisProcessWhileItHoldsTheMicrophone()
    {
        int self = Environment.ProcessId;
        await Task.Run(() =>
        {
            using var devices = new WasapiDevices(CaptureKind.Microphone);
            using (ICaptureEndpoint endpoint = devices.Open())
            {
                Thread.Sleep(500);
                Assert.Contains(self, CaptureSessions.ActiveSessionProcesses());
                Assert.Contains(CaptureSessions.Active(), c => c.ProcessId == self);
            }
            Thread.Sleep(500);
            Assert.DoesNotContain(self, CaptureSessions.ActiveSessionProcesses());
        });
    }

    private sealed class LiveMicrophoneFactAttribute : FactAttribute
    {
        public LiveMicrophoneFactAttribute()
        {
            if (Environment.GetEnvironmentVariable("SOZVON_LIVE_MICROPHONE") != "1") Skip = "SOZVON_LIVE_MICROPHONE is not 1";
        }
    }
}
