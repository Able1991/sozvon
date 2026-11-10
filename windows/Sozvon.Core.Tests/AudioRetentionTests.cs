using System.Text.Json.Nodes;
using Sozvon.Core.Calls;

namespace Sozvon.Core.Tests;

/// <summary>"Delete audio automatically": which calls lose their tracks, and what stays.</summary>
public class AudioRetentionTests : TempFolders
{
    private static readonly DateTimeOffset Now = new(2026, 11, 10, 12, 0, 0, TimeSpan.Zero);

    private string Done(string id, int daysAgo, bool transcript = true, string status = "done")
    {
        var dir = MakeCall(id, new JsonObject { ["status"] = status, ["created_at"] = Now.AddDays(-daysAgo).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") });
        foreach (var name in AudioRetention.RemovedFiles) WriteText(Path.Combine(dir, name), new string('a', 2000));
        if (transcript) WriteText(Path.Combine(dir, "transcript.txt"), "[00:00] Анна: да");
        WriteText(Path.Combine(dir, "summary.md"), "## Коротко");
        return dir;
    }

    [Fact]
    public void OnlyFinishedTranscribedCallsOlderThanTheLimit()
    {
        var old = Done("2026-10-01 10-00", 40);
        Done("2026-11-05 10-00", 5);
        Done("2026-10-02 10-00", 39, transcript: false);
        Done("2026-10-03 10-00", 38, status: "failed");
        var busy = Done("2026-10-04 10-00", 37);
        var expired = AudioRetention.Expired(Calls, 30, Now, dir => dir == busy);
        Assert.Equal([old], expired);
        Assert.Empty(AudioRetention.Expired(Calls, 0, Now)); // keep forever
    }

    [Fact]
    public void ACallWithoutAStartTimeIsLeftAlone()
    {
        var dir = MakeCall("2026-01-01 10-00", new JsonObject { ["status"] = "done" });
        WriteText(Path.Combine(dir, "mic.m4a"), "x");
        WriteText(Path.Combine(dir, "transcript.txt"), "x");
        Assert.Empty(AudioRetention.Expired(Calls, 7, Now));
    }

    [Fact]
    public void RemovesTheAudioAndKeepsTheText()
    {
        var dir = Done("2026-10-01 10-00", 40);
        Assert.Equal(4 * 2000, AudioRetention.Size([dir]));
        Assert.Equal(4 * 2000, AudioRetention.RemoveAudio(dir, Now));
        Assert.All(AudioRetention.RemovedFiles, name => Assert.False(File.Exists(Path.Combine(dir, name))));
        Assert.True(File.Exists(Path.Combine(dir, "transcript.txt")));
        Assert.True(File.Exists(Path.Combine(dir, "summary.md")));
        Assert.Equal("2026-11-10T12:00:00Z", Json(dir)["audio_removed_at"]!.GetValue<string>());
        Assert.Empty(AudioRetention.Expired(Calls, 30, Now)); // nothing left to remove
    }

    [Fact]
    public void SettingsChoicesAreDays()
    {
        Assert.Equal([0, 7, 15, 30, 60], AudioRetention.Choices);
        Assert.Equal(30, AudioRetention.Days(3));
        Assert.Equal(0, AudioRetention.Days(9));
    }
}
