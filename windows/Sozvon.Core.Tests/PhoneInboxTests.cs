using Sozvon.Core.Calls;

namespace Sozvon.Core.Tests;

/// <summary>The phone folder: which files are ready, where they go, and one real import with the engine's ffmpeg.</summary>
public sealed class PhoneInboxTests : TempFolders
{
    private static readonly DateTime Now = new(2026, 11, 10, 12, 0, 0, DateTimeKind.Utc);

    private string Inbox => Path.Combine(Root, "phone");

    private static string Ffmpeg => Path.Combine(RealEngine.Install, ".venv", "Scripts", "ffmpeg.exe");

    private string Put(string name, DateTime changed)
    {
        var path = Path.Combine(Inbox, name);
        WriteText(path, "x");
        File.SetLastWriteTimeUtc(path, changed);
        return path;
    }

    [Fact]
    public void OnlySettledAudioIsReadyOldestFirst()
    {
        var newer = Put("b.m4a", Now.AddMinutes(-1));
        var older = Put("a.mp3", Now.AddMinutes(-5));
        Put("arriving.m4a", Now.AddSeconds(-3));
        Put("notes.txt", Now.AddHours(-1));
        Put(".hidden.m4a", Now.AddHours(-1));
        File.SetAttributes(Put("desktop.m4a", Now.AddHours(-1)), FileAttributes.Hidden);
        Put(Path.Combine(PhoneInbox.DoneFolder, "old.m4a"), Now.AddHours(-1));
        Assert.Equal([older, newer], PhoneInbox.Ready(Inbox, Now));
    }

    [Fact]
    public void AMissingFolderHasNothingReady() => Assert.Empty(PhoneInbox.Ready(Path.Combine(Root, "gone"), Now));

    [Fact]
    public void MovingAsideNeverOverwrites()
    {
        var first = PhoneInbox.MoveAside(Put("a.m4a", Now), PhoneInbox.DoneFolder);
        var second = PhoneInbox.MoveAside(Put("a.m4a", Now), PhoneInbox.DoneFolder);
        Assert.Equal(Path.Combine(Inbox, "Imported", "a.m4a"), first);
        Assert.Equal(Path.Combine(Inbox, "Imported", "a 2.m4a"), second);
    }

    [Theory]
    [InlineData("Встреча с Ильёй.m4a", "Встреча с Ильёй")]
    [InlineData("New Recording 12.m4a", "")]
    [InlineData("Новая запись.m4a", "")]
    [InlineData("Recording (3).m4a", "")]
    [InlineData("Voice 001.m4a", "")]
    [InlineData("2026-11-10 12_01_02.m4a", "")]
    public void TheTopicIsTheNameTheUserGave(string file, string topic) => Assert.Equal(topic, PhoneInbox.Topic(file));

    [Fact]
    public async Task ARecordingBecomesACallAndMovesToImported()
    {
        if (!File.Exists(Ffmpeg)) Assert.Skip($"no ffmpeg at {Ffmpeg}");
        Directory.CreateDirectory(Inbox);
        var wav = Path.Combine(Inbox, "Идея про релиз.wav");
        CallImportTests.WriteSilence(wav, seconds: 2);
        var result = await PhoneInbox.ImportNextAsync(Inbox, Calls, Ffmpeg, new HashSet<string>(), DateTime.UtcNow.AddMinutes(1));
        var imported = Assert.IsType<PhoneImport.Imported>(result);
        Assert.Equal("Идея про релиз", imported.Topic);
        Assert.True(File.Exists(Path.Combine(Inbox, "Imported", "Идея про релиз.wav")));
        Assert.False(File.Exists(wav));
        Assert.True(File.Exists(Path.Combine(imported.CallDir, "system.m4a")));
        Assert.IsType<PhoneImport.Nothing>(await PhoneInbox.ImportNextAsync(Inbox, Calls, Ffmpeg, new HashSet<string>(), DateTime.UtcNow.AddMinutes(1)));
    }

    [Fact]
    public async Task AFileWithoutAudioGoesToFailed()
    {
        if (!File.Exists(Ffmpeg)) Assert.Skip($"no ffmpeg at {Ffmpeg}");
        Put("broken.mp3", DateTime.UtcNow.AddMinutes(-1));
        var result = await PhoneInbox.ImportNextAsync(Inbox, Calls, Ffmpeg, new HashSet<string>(), DateTime.UtcNow.AddMinutes(1));
        Assert.IsType<PhoneImport.Failed>(result);
        Assert.True(File.Exists(Path.Combine(Inbox, "Failed", "broken.mp3")));
        Assert.Empty(Directory.GetDirectories(Calls));
    }

    [Fact]
    public async Task SkippedFilesWait()
    {
        var file = Put("a.m4a", Now.AddMinutes(-1));
        Assert.IsType<PhoneImport.Nothing>(await PhoneInbox.ImportNextAsync(Inbox, Calls, Ffmpeg, new HashSet<string> { file }, Now));
        Assert.True(File.Exists(file));
    }
}
