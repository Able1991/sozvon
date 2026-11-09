using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json.Nodes;
using Sozvon.Core.Calls;
using Sozvon.Core.Foundation;

namespace Sozvon.Core.Tests;

/// <summary>Temporary data and calls folders for one test.</summary>
public abstract class TempFolders : IDisposable
{
    protected string Root { get; } = Path.Combine(Path.GetTempPath(), "sozvon-test-" + Guid.NewGuid().ToString("N"));
    protected string Data => Path.Combine(Root, "data");
    protected string Calls => Path.Combine(Root, "calls");

    protected TempFolders()
    {
        Directory.CreateDirectory(Data);
        Directory.CreateDirectory(Calls);
    }

    protected static void WriteText(string path, string text)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, text, new UTF8Encoding(false));
    }

    /// <summary>A call folder with the given call.json fields, named and identified by <paramref name="id"/>.</summary>
    protected string MakeCall(string id, JsonObject? fields = null, string? folder = null)
    {
        var dir = Path.Combine(Calls, folder ?? id);
        var call = fields ?? [];
        call["schema"] = 1;
        call["id"] = id;
        WriteText(CallFile.PathIn(dir), call.ToJsonString());
        return dir;
    }

    protected static JsonObject Json(string dir) => JsonFile.Read(CallFile.PathIn(dir))!;

    public virtual void Dispose()
    {
        if (!Directory.Exists(Root)) return;
        foreach (var entry in Directory.GetDirectories(Data)) // never walk into a junction: it leads to the real install
            if ((File.GetAttributes(entry) & FileAttributes.ReparsePoint) != 0) Directory.Delete(entry);
        for (var attempt = 0; attempt < 20; attempt++)
        {
            try
            {
                Directory.Delete(Root, recursive: true);
                return;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                Thread.Sleep(100);
            }
        }
    }
}

internal static class Repo
{
    internal static string Root([CallerFilePath] string here = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(here)!, "..", ".."));

    internal static JsonObject Fixture(string name) =>
        JsonFile.Read(Path.Combine(Root(), "Tests", "Fixtures", name)) ?? throw new FileNotFoundException(name);
}

/// <summary>The real engine install used by the interop tests; they skip when it is absent.</summary>
internal static class RealEngine
{
    internal static readonly string Install =
        Environment.GetEnvironmentVariable("SOZVON_TEST_ENGINE")
        ?? @"C:\Users\User\AppData\Local\Temp\claude\fc02657706c86607\5c0b1740-e0cc-48c1-95ab-bb57939e1860\scratchpad\Установка с нуля";

    internal static string Python => Path.Combine(Install, ".venv", "Scripts", "python.exe");

    internal static void RequirePython()
    {
        if (!File.Exists(Python)) Assert.Skip($"no engine install at {Install}");
    }

    /// <summary>Points <paramref name="link"/> at <paramref name="target"/> with a junction, which needs no privileges.</summary>
    internal static void Junction(string link, string target)
    {
        using var process = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
        {
            FileName = Path.Combine(Environment.SystemDirectory, "cmd.exe"),
            Arguments = $"/c mklink /J \"{link}\" \"{target}\"",
            CreateNoWindow = true,
            UseShellExecute = false,
            RedirectStandardOutput = true,
        })!;
        process.WaitForExit();
        if (process.ExitCode != 0) throw new IOException($"mklink failed for {link}");
    }
}
