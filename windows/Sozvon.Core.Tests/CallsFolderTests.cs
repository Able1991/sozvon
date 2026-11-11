using System.Text.Json.Nodes;
using Sozvon.Core.Calls;
using Sozvon.Core.Foundation;
using Sozvon.Core.Settings;

namespace Sozvon.Core.Tests;

/// <summary>
/// Choosing another calls folder, as on the Mac (CallsFolderTests.swift): which folders make no sense, and moving the
/// calls there without losing any. The Recycle Bin is a stand-in here; the real one is CallTrashTests' business.
/// </summary>
public sealed class CallsFolderTests : TempFolders
{
    private string Old => Calls;
    private string New => Path.Combine(Root, "New");
    private string SettingsFile => Path.Combine(Data, "settings.json");

    private string MakeCallIn(string root, string name, int audioBytes = 5000)
    {
        var dir = Path.Combine(root, name);
        WriteText(Path.Combine(dir, "call.json"), $$"""{"schema":1,"id":"{{name}}"}""");
        Directory.CreateDirectory(dir);
        File.WriteAllBytes(Path.Combine(dir, "mic.m4a"), Enumerable.Repeat((byte)7, audioBytes).ToArray());
        return dir;
    }

    private string MakeCall(string name) => MakeCallIn(Old, name);

    private static List<string> Names(string root) => CallsFolder.Calls(root).Select(Path.GetFileName).OfType<string>().ToList();

    private static void Trash(string path) => Directory.Delete(path, recursive: true);

    [Fact]
    public void FoldersThatMakeNoSense()
    {
        Assert.Equal(CallsFolderProblem.Same, CallsFolder.Problem(Old, Old, Data));
        Assert.Equal(CallsFolderProblem.Same, CallsFolder.Problem(Old, Old.ToUpperInvariant() + "\\", Data));
        Assert.Equal(CallsFolderProblem.Inside, CallsFolder.Problem(Old, Path.Combine(Old, "Sub"), Data));
        Assert.Equal(CallsFolderProblem.Contains, CallsFolder.Problem(Old, Root, Data));
        Assert.Equal(CallsFolderProblem.EngineData, CallsFolder.Problem(Old, Data, Data));
        Assert.Equal(CallsFolderProblem.EngineData, CallsFolder.Problem(Old, Path.Combine(Data, "x"), Data));
        Assert.Null(CallsFolder.Problem(Old, New, Data));
        // A neighbour whose name only starts like the current folder is not inside it.
        Assert.Null(CallsFolder.Problem(Old, Old + " 2", Data));
    }

    [Fact]
    public void OnlyCallFoldersCount()
    {
        MakeCall("2026-11-04 15-01 · Acme");
        MakeCall("2026-11-05 10-00");
        var audioOnly = Path.Combine(Old, "2026-11-06 09-00");
        Directory.CreateDirectory(audioOnly);
        File.WriteAllBytes(Path.Combine(audioOnly, "system.m4a"), [1, 2, 3]);
        Directory.CreateDirectory(Path.Combine(Old, "Random"));
        Directory.CreateDirectory(Path.Combine(Old, ".hidden"));
        WriteText(Path.Combine(Old, ".hidden", "call.json"), "{}");
        WriteText(Path.Combine(Old, "desktop.ini"), "");
        Assert.Equal(["2026-11-04 15-01 · Acme", "2026-11-05 10-00", "2026-11-06 09-00"], Names(Old));
        Assert.Empty(CallsFolder.Calls(Path.Combine(Root, "missing")));
    }

    [Fact]
    public void MoveTakesEveryCallAndLeavesTheRest()
    {
        MakeCall("2026-11-04 15-01 · Acme");
        MakeCall("2026-11-05 10-00");
        Directory.CreateDirectory(Path.Combine(Old, "Random"));
        var seen = new List<(int Done, int Total)>();
        var moved = CallsFolder.Move(Old, New, trash: _ => Assert.Fail("a rename trashes nothing"), progress: (done, total) => seen.Add((done, total)));
        Assert.Equal(2, moved);
        Assert.Equal(2, CallsFolder.Calls(New).Count);
        Assert.Empty(CallsFolder.Calls(Old));
        Assert.True(Directory.Exists(Path.Combine(Old, "Random")));
        Assert.Equal(5000, new FileInfo(Path.Combine(New, "2026-11-05 10-00", "mic.m4a")).Length);
        Assert.Equal([(0, 2), (1, 2), (2, 2)], seen);
    }

    [Fact]
    public void ANameTakenInTheNewFolderStopsBeforeMovingAnything()
    {
        MakeCall("2026-11-04 15-01");
        MakeCall("2026-11-05 10-00");
        MakeCallIn(New, "2026-11-05 10-00");
        var error = Assert.Throws<CallsFolderMoveException>(() =>
            CallsFolder.Move(Old, New, trash: _ => Assert.Fail("nothing goes"), progress: (_, _) => { }));
        Assert.Equal(["2026-11-05 10-00"], error.Taken);
        Assert.Null(error.Mismatch);
        Assert.Equal(2, CallsFolder.Calls(Old).Count);
        Assert.Single(CallsFolder.Calls(New));
    }

    [Fact]
    public void ANewFolderWithOtherCallsAndFilesTakesTheCallsBesideThem()
    {
        MakeCall("2026-11-04 15-01");
        MakeCallIn(New, "2026-10-01 08-00");
        WriteText(Path.Combine(New, "notes.txt"), "mine");
        Assert.Equal(1, CallsFolder.Move(Old, New, trash: Trash, progress: (_, _) => { }));
        Assert.Equal(["2026-10-01 08-00", "2026-11-04 15-01"], Names(New));
        Assert.Equal("mine", File.ReadAllText(Path.Combine(New, "notes.txt")));
    }

    [Fact]
    public void NothingToMoveStillCreatesTheNewFolder()
    {
        Assert.Equal(0, CallsFolder.Move(Path.Combine(Root, "missing"), New, trash: Trash, progress: (_, _) => { }));
        Assert.True(Directory.Exists(New));
    }

    [Fact]
    public void ACopyToAnotherDiskIsCheckedBeforeTheOriginalGoes()
    {
        var call = MakeCall("2026-11-04 15-01");
        WriteText(Path.Combine(call, "transcript.txt"), "Привет");
        WriteText(Path.Combine(call, "notes", "a.md"), "deep");
        var trashed = new List<string>();
        // The copy path, as on another drive: the original goes to the Recycle Bin only after the copy matches it.
        var moved = CallsFolder.Move(Old, New, sameVolume: false, trash: path =>
        {
            Assert.True(File.Exists(Path.Combine(New, "2026-11-04 15-01", "notes", "a.md")), "the copy is complete before the original goes");
            trashed.Add(path);
            Trash(path);
        }, progress: (_, _) => { });
        Assert.Equal(1, moved);
        Assert.Equal([call], trashed);
        Assert.Equal(5000, new FileInfo(Path.Combine(New, "2026-11-04 15-01", "mic.m4a")).Length);
        Assert.Equal("Привет", File.ReadAllText(Path.Combine(New, "2026-11-04 15-01", "transcript.txt")));
        Assert.Equal("deep", File.ReadAllText(Path.Combine(New, "2026-11-04 15-01", "notes", "a.md")));
    }

    [Fact]
    public void ACopyMissingAFileKeepsTheOriginalAndDropsTheCopy()
    {
        var first = MakeCall("2026-11-04 15-01");
        var second = MakeCall("2026-11-05 10-00");
        var error = Assert.Throws<CallsFolderMoveException>(() => CallsFolder.Move(Old, New, sameVolume: false,
            trash: _ => Assert.Fail("a bad copy trashes nothing"), progress: (_, _) => { },
            copy: (from, to) =>
            {
                CallsFolder.CopyFolder(from, to);
                File.Delete(Path.Combine(to, "mic.m4a"));
            }));
        Assert.Equal("2026-11-04 15-01", error.Mismatch);
        Assert.True(File.Exists(Path.Combine(first, "mic.m4a")));
        Assert.True(Directory.Exists(second));
        Assert.False(Directory.Exists(Path.Combine(New, "2026-11-04 15-01")));
    }

    [Fact]
    public void ACopyOfTheSameSizeButOtherBytesIsAMismatchToo()
    {
        var call = MakeCall("2026-11-04 15-01");
        var error = Assert.Throws<CallsFolderMoveException>(() => CallsFolder.Move(Old, New, sameVolume: false,
            trash: _ => Assert.Fail("a bad copy trashes nothing"), progress: (_, _) => { },
            copy: (from, to) =>
            {
                CallsFolder.CopyFolder(from, to);
                File.WriteAllBytes(Path.Combine(to, "mic.m4a"), Enumerable.Repeat((byte)8, 5000).ToArray());
            }));
        Assert.Equal("2026-11-04 15-01", error.Mismatch);
        Assert.Equal(7, File.ReadAllBytes(Path.Combine(call, "mic.m4a"))[0]);
    }

    [Fact]
    public void ATrashThatFailsLeavesBothCopiesAndStops()
    {
        MakeCall("2026-11-04 15-01");
        MakeCall("2026-11-05 10-00");
        Assert.Throws<IOException>(() => CallsFolder.Move(Old, New, sameVolume: false,
            trash: _ => throw new IOException("in use"), progress: (_, _) => { }));
        Assert.Equal(2, CallsFolder.Calls(Old).Count);
        Assert.Equal(["2026-11-04 15-01"], Names(New));
    }

    [Fact]
    public void TheSameDriveIsTold()
    {
        Assert.True(CallsFolder.OnSameVolume(Old, Path.Combine(Root, "not yet", "deeper")));
        Assert.False(CallsFolder.OnSameVolume(@"C:\Calls", @"Q:\Calls"));
        Assert.True(CallsFolder.OnSameVolume(@"c:\Calls", @"C:\Other"));
    }

    [Fact]
    public void WorkInProgressIsSeenInTheFiles()
    {
        var done = MakeCall("2026-11-04 15-01");
        Assert.False(CallsFolder.HasWorkInProgress(Old));
        var recording = MakeCall("2026-11-05 10-00");
        Directory.CreateDirectory(Path.Combine(recording, ".recording"));
        Assert.True(CallsFolder.HasWorkInProgress(Old));
        Directory.Delete(Path.Combine(recording, ".recording"));
        WriteText(Path.Combine(done, "call.json"), """{"schema":1,"id":"2026-11-04 15-01","status":"processing"}""");
        Assert.True(CallsFolder.HasWorkInProgress(Old));
        WriteText(Path.Combine(done, "call.json"), """{"schema":1,"id":"2026-11-04 15-01","status":"done","queued_at":"2026-11-05T10:00:00.000Z"}""");
        Assert.True(CallsFolder.HasWorkInProgress(Old));
        Assert.False(CallsFolder.HasWorkInProgress(Path.Combine(Root, "missing")));
    }

    [Fact]
    public void TheChoiceIsKeptInSettingsBesideTheOtherValues()
    {
        WriteText(SettingsFile, """{"Theme":"Dark","Language":"English"}""");
        var defaultFolder = Path.Combine(Root, "Sozvon Calls");
        CallsFolder.Choose(SettingsFile, New, defaultFolder);
        var saved = JsonFile.Read(SettingsFile)!;
        Assert.Equal(New, (string?)saved[CallsFolder.SettingKey]);
        Assert.Equal("Dark", (string?)saved["Theme"]);
        Assert.Equal(New, CallsFolder.Chosen(SettingsFile));
        // The default folder is no choice: the key goes, as the Mac removes callsDir.
        CallsFolder.Choose(SettingsFile, defaultFolder + "\\", defaultFolder);
        Assert.False(JsonFile.Read(SettingsFile)!.ContainsKey(CallsFolder.SettingKey));
        Assert.Equal("English", (string?)JsonFile.Read(SettingsFile)!["Language"]);
        Assert.Null(CallsFolder.Chosen(SettingsFile));
    }

    [Fact]
    public void TheFolderOfARunComesFromTheVariableTheChoiceOrTheDefault()
    {
        var defaultFolder = Path.Combine(Root, "Sozvon Calls");
        Assert.Equal(defaultFolder, CallsFolder.Current(SettingsFile, defaultFolder, null));
        CallsFolder.Choose(SettingsFile, New, defaultFolder);
        Assert.Equal(New, CallsFolder.Current(SettingsFile, defaultFolder, " "));
        Assert.Equal(@"D:\Given", CallsFolder.Current(SettingsFile, defaultFolder, @"D:\Given"));
        WriteText(SettingsFile, "{ broken");
        Assert.Equal(defaultFolder, CallsFolder.Current(SettingsFile, defaultFolder, null));
    }

    [Fact]
    public void EveryRunAfterAChangeGetsTheNewFolder()
    {
        var folder = Old;
        var layout = new Sozvon.Core.Engine.EngineLayout(Data, () => folder);
        Assert.Equal(Old, Sozvon.Core.Engine.EngineEnvironment.Build(layout, new Sozvon.Core.Engine.EngineOptions(), [])["SOZVON_CALLS_DIR"]);
        folder = New;
        Assert.Equal(New, layout.Calls);
        Assert.Equal(New, Sozvon.Core.Engine.EngineEnvironment.Build(layout, new Sozvon.Core.Engine.EngineOptions(), [])["SOZVON_CALLS_DIR"]);
    }

    [Fact]
    public void SettingsWrittenByTheAppKeepTheKeysItDoesNotManage()
    {
        var disk = JsonFile.Parse("""{"Theme":"Dark","CallsFolder":"D:\\Calls","Old":1}""");
        var mine = JsonFile.Parse("""{"Theme":"Light","Language":"System"}""")!;
        var merged = SettingsJson.KeepForeignKeys(disk, mine);
        Assert.Equal("Light", (string?)merged["Theme"]);
        Assert.Equal("System", (string?)merged["Language"]);
        Assert.Equal(@"D:\Calls", (string?)merged["CallsFolder"]);
        Assert.Equal(1, (int?)merged["Old"]);
        Assert.Same(mine, SettingsJson.KeepForeignKeys(null, mine));
    }
}
