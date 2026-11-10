using System.ComponentModel;
using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;
using Sozvon.Core.Settings;

namespace Sozvon.Core.Assistants;

/// <summary>Where an assistant keeps its settings: the profile folder and the local application data.</summary>
/// <param name="Home">The profile folder (USERPROFILE): ~\.claude.json, ~\.codex, ~\.cursor and ~\.local\bin are in it.</param>
/// <param name="SearchPath">PATH, as the assistants' own tools see it.</param>
public sealed record AssistantHome(string Home, string LocalAppData, string RoamingAppData, string SearchPath)
{
    /// <summary>
    /// The folders from the environment, as the assistants themselves read them (Node and Rust take USERPROFILE first), so a
    /// run with its own USERPROFILE never reaches the real profile.
    /// </summary>
    public static AssistantHome FromEnvironment() => new(
        Variable("USERPROFILE") ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        Variable("LOCALAPPDATA") ?? Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        Variable("APPDATA") ?? Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        Variable("PATH") ?? "");

    private static string? Variable(string name) => Environment.GetEnvironmentVariable(name) is { Length: > 0 } value ? value : null;
}

/// <summary>Runs one command line tool and returns its exit code and output.</summary>
public interface ICliRunner
{
    (int ExitCode, string Output) Run(string cli, IReadOnlyList<string> arguments);
}

/// <summary>
/// An assistant's command line tool. As in the engine, only absolute paths are started, nothing from the current folder,
/// and a batch file never goes through cmd.exe: npm's .cmd wrapper is read and node runs its script directly.
/// </summary>
public static partial class AssistantCli
{
    /// <summary>The tool's name: claude, codex, cursor-agent; null for no assistant.</summary>
    public static string? Name(Assistant a) => a switch
    {
        Assistant.Claude => "claude",
        Assistant.Codex => "codex",
        Assistant.Cursor => "cursor-agent",
        _ => null,
    };

    public static string Title(Assistant a) => a switch
    {
        Assistant.Claude => "Claude Code",
        Assistant.Codex => "Codex",
        Assistant.Cursor => "Cursor",
        _ => "",
    };

    /// <summary>PATH, then ~\.local\bin (Claude's own installer) and npm's global folder; absolute folders only.</summary>
    public static IEnumerable<string> SearchFolders(AssistantHome home) =>
        home.SearchPath.Split(System.IO.Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(f => f.Trim('"'))
            .Concat([System.IO.Path.Combine(home.Home, ".local", "bin"), System.IO.Path.Combine(home.RoamingAppData, "npm")])
            .Where(System.IO.Path.IsPathFullyQualified);

    /// <summary>The full path of the tool that can be started safely, or null.</summary>
    public static string? Find(string name, AssistantHome home) =>
        SearchFolders(home)
            .SelectMany(folder => new[] { ".exe", ".cmd" }.Select(extension => System.IO.Path.Combine(folder, name + extension)))
            .FirstOrDefault(candidate => File.Exists(candidate) && Argv(candidate, home) is not null);

    public static string? Find(Assistant a, AssistantHome home) => Name(a) is { } name ? Find(name, home) : null;

    /// <summary>How to start a tool: an .exe itself, npm's .cmd as node and its script; null when it cannot be started safely.</summary>
    public static IReadOnlyList<string>? Argv(string path, AssistantHome home)
    {
        var extension = System.IO.Path.GetExtension(path);
        if (extension.Equals(".exe", StringComparison.OrdinalIgnoreCase)) return [path];
        if (!extension.Equals(".cmd", StringComparison.OrdinalIgnoreCase)) return null;
        try
        {
            var targets = NpmTarget().Matches(File.ReadAllText(path));
            if (targets.Count != 1) return null;
            var folder = System.IO.Path.GetFullPath(System.IO.Path.GetDirectoryName(path)!);
            var script = System.IO.Path.GetFullPath(System.IO.Path.Combine(folder, targets[0].Groups[1].Value));
            if (!script.StartsWith(folder + System.IO.Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) || !File.Exists(script)) return null;
            var node = new[] { folder }.Concat(SearchFolders(home)).Select(f => System.IO.Path.Combine(f, "node.exe")).FirstOrDefault(File.Exists);
            return node is null ? null : [node, script];
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return null;
        }
    }

    [GeneratedRegex("\"%~?dp0%?\\\\([^\"]+)\"\\s+%\\*")]
    private static partial Regex NpmTarget();
}

/// <summary>Starts the tool with the given environment, no window and no input, and waits for it a limited time.</summary>
public sealed class ProcessCliRunner(AssistantHome home, IReadOnlyDictionary<string, string>? environment = null, TimeSpan? timeout = null) : ICliRunner
{
    private readonly TimeSpan _timeout = timeout ?? TimeSpan.FromSeconds(60);

    public (int ExitCode, string Output) Run(string cli, IReadOnlyList<string> arguments)
    {
        if (AssistantCli.Argv(cli, home) is not { } argv) return (-1, $"{cli}: cannot be started safely");
        var start = new ProcessStartInfo(argv[0])
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = home.Home,
        };
        foreach (var argument in argv.Skip(1).Concat(arguments)) start.ArgumentList.Add(argument);
        if (environment is not null)
        {
            start.Environment.Clear();
            foreach (var (key, value) in environment) start.Environment[key] = value;
        }
        try
        {
            using var process = Process.Start(start) ?? throw new Win32Exception("not started");
            process.StandardInput.Close();
            var output = process.StandardOutput.ReadToEndAsync();
            var errors = process.StandardError.ReadToEndAsync();
            if (!process.WaitForExit(_timeout))
            {
                process.Kill(entireProcessTree: true);
                return (-1, $"{System.IO.Path.GetFileName(cli)}: no answer in {_timeout.TotalSeconds:0} s");
            }
            return (process.ExitCode, (output.Result + errors.Result).Trim());
        }
        catch (Exception e) when (e is Win32Exception or InvalidOperationException or IOException)
        {
            return (-1, e.Message);
        }
    }
}
