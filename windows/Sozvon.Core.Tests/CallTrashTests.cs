using Sozvon.Core.Calls;
using Sozvon.Core.Foundation;
using Sozvon.Core.Server;

namespace Sozvon.Core.Tests;

/// <summary>
/// A call to the Recycle Bin and back with Ctrl+Z: what is remembered, and what the own server's lists say. The Bin
/// is a fake here; the real one is tried once, at the end.
/// </summary>
public sealed class CallTrashTests : TempFolders
{
    private static readonly DateTimeOffset At = new(2026, 11, 10, 12, 0, 0, TimeSpan.Zero);

    /// <summary>Takes folders away and gives them back, remembering the order of the calls.</summary>
    private sealed class FakeBin : IRecycler
    {
        public List<string> Recycled { get; } = [];
        public List<string> Restored { get; } = [];
        public Exception? Refuses { get; set; }

        public void Recycle(string path)
        {
            if (Refuses is not null) throw Refuses;
            Directory.Move(path, path + ".in-bin");
            Recycled.Add(path);
        }

        public void Restore(string originalPath)
        {
            if (!Directory.Exists(originalPath + ".in-bin")) throw new IOException("not in the bin: " + originalPath);
            Directory.Move(originalPath + ".in-bin", originalPath);
            Restored.Add(originalPath);
        }
    }

    private string Deleted => Path.Combine(Data, ServerLists.DeletedFile);
    private string ToRestore => Path.Combine(Data, ServerLists.RestoreFile);

    private CallTrash Trash(FakeBin bin, bool server) => new(Data, bin, () => server, () => At, retryFor: TimeSpan.Zero);

    [Fact]
    public void ATrashedCallLeavesItsFolderAndIsForgottenOnTheServer()
    {
        var bin = new FakeBin();
        var trash = Trash(bin, server: true);
        var dir = MakeCall("2026-11-04 15-01");
        Assert.False(trash.CanUndo);
        Assert.Null(trash.Trash("2026-11-04 15-01", dir));
        Assert.False(Directory.Exists(dir));
        Assert.Equal([dir], bin.Recycled);
        Assert.True(trash.CanUndo);
        Assert.Equal(new TrashedCall("2026-11-04 15-01", dir), trash.Last);
        Assert.Equal(["2026-11-04 15-01"], ServerLists.Ids(Deleted));
    }

    [Fact]
    public void WithoutAServerNothingIsWritten()
    {
        var bin = new FakeBin();
        var trash = Trash(bin, server: false);
        Assert.Null(trash.Trash("2026-11-04 15-01", MakeCall("2026-11-04 15-01")));
        Assert.False(File.Exists(Deleted));
        Assert.True(trash.CanUndo);
    }

    [Fact]
    public void UndoBringsTheLastCallBackFirstAndKeepsItOnTheServer()
    {
        var bin = new FakeBin();
        var trash = Trash(bin, server: true);
        var first = MakeCall("2026-11-04 15-01");
        var second = MakeCall("2026-11-04 16-00");
        trash.Trash("2026-11-04 15-01", first);
        trash.Trash("2026-11-04 16-00", second);
        Assert.Equal(["2026-11-04 15-01", "2026-11-04 16-00"], ServerLists.Ids(Deleted));

        var (call, problem) = trash.Undo();
        Assert.Null(problem);
        Assert.Equal(new TrashedCall("2026-11-04 16-00", second), call);
        Assert.True(Directory.Exists(second));
        Assert.Equal([second], bin.Restored);
        Assert.Equal(["2026-11-04 15-01"], ServerLists.Ids(Deleted));
        Assert.Equal(["2026-11-04 16-00"], ServerLists.Ids(ToRestore));
        Assert.True(trash.CanUndo);

        (call, problem) = trash.Undo();
        Assert.Null(problem);
        Assert.Equal("2026-11-04 15-01", call.Id);
        Assert.True(Directory.Exists(first));
        Assert.Empty(ServerLists.Ids(Deleted));
        Assert.Equal(["2026-11-04 16-00", "2026-11-04 15-01"], ServerLists.Ids(ToRestore));
        Assert.False(trash.CanUndo);
        Assert.Throws<InvalidOperationException>(() => trash.Undo());
    }

    [Fact]
    public void WithoutAServerUndoOnlyWithdrawsAnOldNote()
    {
        var server = true;
        var bin = new FakeBin();
        var trash = new CallTrash(Data, bin, () => server, () => At, retryFor: TimeSpan.Zero);
        var dir = MakeCall("2026-11-04 15-01");
        trash.Trash("2026-11-04 15-01", dir);
        Assert.Equal(["2026-11-04 15-01"], ServerLists.Ids(Deleted));

        // The server was switched off meanwhile: the note must not linger, and nothing is to be brought back there.
        server = false;
        var (call, problem) = trash.Undo();
        Assert.Null(problem);
        Assert.Equal("2026-11-04 15-01", call.Id);
        Assert.Empty(ServerLists.Ids(Deleted));
        Assert.False(File.Exists(ToRestore));
    }

    [Fact]
    public void ABinThatRefusesLeavesTheCallWhereItIs()
    {
        var bin = new FakeBin { Refuses = new IOException("in use") };
        var trash = Trash(bin, server: true);
        var dir = MakeCall("2026-11-04 15-01");
        Assert.Throws<IOException>(() => trash.Trash("2026-11-04 15-01", dir));
        Assert.True(Directory.Exists(dir));
        Assert.False(trash.CanUndo);
        Assert.False(File.Exists(Deleted));
    }

    [Fact]
    public void ANoteThatCannotBeWrittenIsReportedButTheCallIsGone()
    {
        Directory.CreateDirectory(Deleted); // a folder where the list should be: it cannot be written
        var bin = new FakeBin();
        var trash = Trash(bin, server: true);
        var dir = MakeCall("2026-11-04 15-01");
        var problem = trash.Trash("2026-11-04 15-01", dir);
        Assert.NotNull(problem);
        Assert.False(Directory.Exists(dir));
        Assert.True(trash.CanUndo);
    }

    [Fact]
    public void ACallAlreadyBackIsNotRestoredTwice()
    {
        var bin = new FakeBin();
        var trash = Trash(bin, server: true);
        var dir = MakeCall("2026-11-04 15-01");
        trash.Trash("2026-11-04 15-01", dir);
        bin.Restore(dir); // put back in File Explorer meanwhile
        var (call, problem) = trash.Undo();
        Assert.Null(problem);
        Assert.Equal(dir, call.Folder);
        Assert.Equal([dir], bin.Restored); // our undo did not ask the bin again
        Assert.Empty(ServerLists.Ids(Deleted));
        Assert.Equal(["2026-11-04 15-01"], ServerLists.Ids(ToRestore));
    }

    [Fact]
    public void ACallGoneFromTheBinCannotComeBackAndIsForgotten()
    {
        var bin = new FakeBin();
        var trash = Trash(bin, server: false);
        var dir = MakeCall("2026-11-04 15-01");
        trash.Trash("2026-11-04 15-01", dir);
        Directory.Delete(dir + ".in-bin", recursive: true); // the Bin was emptied
        Assert.Throws<IOException>(() => trash.Undo());
        Assert.False(trash.CanUndo);
    }

    /// <summary>The real Recycle Bin: a folder goes there, is seen there under its old path, and comes back.</summary>
    [Fact]
    [Trait("Category", "Slow")]
    public void TheRealRecycleBinTakesAFolderAndGivesItBack()
    {
        var dir = Path.Combine(Calls, "sozvon-trash-test " + Guid.NewGuid().ToString("N")[..8]);
        WriteText(Path.Combine(dir, "call.json"), "{\"schema\": 1}");
        WriteText(Path.Combine(dir, "notes", "a.txt"), "hello");
        try
        {
            Assert.False(RecycleBin.Contains(dir));
            RecycleBin.Move(dir);
            Assert.False(Directory.Exists(dir));
            Assert.True(RecycleBin.Contains(dir));

            RecycleBin.Restore(dir);
            Assert.True(Directory.Exists(dir));
            Assert.Equal("hello", File.ReadAllText(Path.Combine(dir, "notes", "a.txt")));
            Assert.False(RecycleBin.Contains(dir));
            Assert.Throws<IOException>(() => RecycleBin.Restore(dir)); // already there
            Assert.Throws<FileNotFoundException>(() => RecycleBin.Restore(dir + "-never")); // never in the Bin
        }
        finally
        {
            // Never leave our folder in the owner's Recycle Bin: the test's folder is ours alone, nothing else is touched.
            if (!Directory.Exists(dir) && RecycleBin.Contains(dir))
            {
                RecycleBin.Restore(dir);
            }
        }
    }
}
