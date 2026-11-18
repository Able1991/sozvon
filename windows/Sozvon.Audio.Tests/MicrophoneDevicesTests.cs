using Sozvon.Audio.Capture;
using Xunit;

namespace Sozvon.Audio.Tests;

/// <summary>The microphone the call app captures from, which need not be the default.</summary>
public sealed class MicrophoneDevicesTests
{
    private static readonly string[] s_all = ["built-in", "usb", "headset"];

    [Fact]
    public void TheDefaultIsKeptWhenTheCallUsesIt()
    {
        Assert.Equal("built-in", MicrophoneDevices.Choose("built-in", "headset", ["usb", "built-in"], s_all, null));
    }

    [Fact]
    public void TheMicrophoneACallAppIsSetToIsFollowed()
    {
        Assert.Equal("usb", MicrophoneDevices.Choose("built-in", "built-in", ["usb"], s_all, null));
    }

    [Fact]
    public void TheCommunicationsMicrophoneComesBeforeAnyOther()
    {
        Assert.Equal("headset", MicrophoneDevices.Choose("built-in", "headset", ["usb", "headset"], s_all, null));
    }

    [Fact]
    public void NobodyCapturingMeansTheDefault()
    {
        Assert.Equal("built-in", MicrophoneDevices.Choose("built-in", "headset", [], s_all, null));
        Assert.Null(MicrophoneDevices.Choose(null, null, [], [], null));
    }

    [Fact]
    public void ACallThatPausesItsMicrophoneStaysOnIt()
    {
        // Some call apps stop capturing while muted: the room's default mic must not take over for that time.
        Assert.Equal("usb", MicrophoneDevices.Choose("built-in", "built-in", [], s_all, followed: "usb"));
    }

    [Fact]
    public void AFollowedMicrophonePulledOutGivesWayToTheDefault()
    {
        Assert.Equal("built-in", MicrophoneDevices.Choose("built-in", "built-in", [], ["built-in"], followed: "usb"));
    }

    [Fact]
    public void ANewDefaultIsTakenWhenNobodyCaptures()
    {
        Assert.Equal("headset", MicrophoneDevices.Choose("headset", "headset", [], s_all, followed: null));
    }

    [Fact]
    public void TheRealMicrophonesAreScannedWithoutOpeningAny()
    {
        using var devices = new MicrophoneDevices();
        using var defaults = new WasapiDevices(CaptureKind.Microphone);
        string? chosen = devices.DefaultDeviceId();
        // Nothing else captures in the test run, so the default is the one.
        Assert.Equal(defaults.DefaultDeviceId(), chosen);
    }
}
