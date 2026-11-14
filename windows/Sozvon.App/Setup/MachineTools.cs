using System.ComponentModel;
using System.Diagnostics;
using Sozvon.Core.Assistants;
using Kind = Sozvon.Core.Settings.Assistant;

namespace Sozvon.App.Setup;

/// <summary>A summary assistant with its command line tool. <see cref="Key"/> is the SOZVON_LLM value.</summary>
internal sealed record Assistant(string Key, string Title, string Description, bool IsInstalled);

/// <summary>Finds the tools the wizard offers. Only absolute paths: nothing is started from the current folder.</summary>
internal static class MachineTools
{
    private const int NvidiaTimeoutMilliseconds = 5000;

    /// <summary>As Settings looks for them (PATH and the folders the vendors' installers use), read again by "Check again".</summary>
    public static IReadOnlyList<Assistant> FindAssistants()
    {
        var home = AssistantHome.FromEnvironment();
        bool Installed(Kind kind) => AssistantCli.Find(kind, home) is not null;
        return
        [
            new("claude", "Claude Code", Strings.L("Текст уходит в Anthropic. Потом можно спрашивать о звонках прямо в терминале."), Installed(Kind.Claude)),
            new("codex", "Codex", Strings.L("Текст уходит в OpenAI. Потом можно спрашивать о звонках в Codex."), Installed(Kind.Codex)),
            new("cursor", "Cursor", Strings.L("Текст уходит в Cursor и к выбранной там модели. Потом можно спрашивать о звонках в Cursor."), Installed(Kind.Cursor)),
        ];
    }

    /// <summary>The wizard's key (SOZVON_LLM) as the assistant of Settings.</summary>
    public static Kind KindOf(string key) => key switch
    {
        "claude" => Kind.Claude,
        "codex" => Kind.Codex,
        "cursor" => Kind.Cursor,
        _ => Kind.None,
    };

    /// <summary>The name of the first NVIDIA card, or null when nvidia-smi is missing or finds none.</summary>
    public static string? FindNvidiaCard()
    {
        var tool = Find("nvidia-smi");
        if (tool is null)
        {
            return null;
        }
        var start = new ProcessStartInfo(tool, "--query-gpu=name --format=csv,noheader")
        {
            RedirectStandardOutput = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        try
        {
            using var process = Process.Start(start)!;
            var output = process.StandardOutput.ReadToEndAsync();
            if (!process.WaitForExit(NvidiaTimeoutMilliseconds))
            {
                process.Kill();
                return null;
            }
            var name = output.Result.Split('\n')[0].Trim();
            return process.ExitCode == 0 && name.Length > 0 ? name : null;
        }
        catch (Exception e) when (e is Win32Exception or InvalidOperationException)
        {
            return null;
        }
    }

    private static string? Find(string name)
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var path = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        var folders = path.Concat([Path.Combine(home, ".local", "bin"), Path.Combine(roaming, "npm"), Environment.SystemDirectory]).Where(Path.IsPathFullyQualified);
        return folders.SelectMany(folder => new[] { ".exe", ".cmd" }.Select(extension => Path.Combine(folder, name + extension))).FirstOrDefault(File.Exists);
    }
}
