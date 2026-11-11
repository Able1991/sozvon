using Sozvon.Core.Engine;
using Sozvon.Core.Settings;

namespace Sozvon.Core.Assistants;

public enum AssistantCheckState { Running, Ok, Failed }

/// <summary>
/// Whether the chosen summary assistant answers: <c>bin\check_assistant.py &lt;name&gt;</c> sends it a one-word request through
/// the very command a summary uses (docs/CONTRACT.md), so "connected" never hides a CLI that is logged out or cannot start.
/// As the Mac's AssistantCheck.
/// </summary>
/// <param name="Message">A failure: the assistant's own error with the engine's hint (log in again, update), or the last line.</param>
/// <param name="TimedOut">The script gave no answer in time and was ended.</param>
public sealed record AssistantCheck(AssistantCheckState State, string Message = "", bool TimedOut = false)
{
    public static readonly AssistantCheck Running = new(AssistantCheckState.Running);
    public static readonly AssistantCheck Ok = new(AssistantCheckState.Ok);

    public static AssistantCheck Failed(string message) => new(AssistantCheckState.Failed, message);

    /// <summary>The script's output lines and exit code. No <c>RESULT:</c> line (the engine broke): its last line with text.</summary>
    public static AssistantCheck Parse(IReadOnlyList<string> lines, int exitCode)
    {
        if (lines.LastOrDefault(l => l.StartsWith("RESULT: ", StringComparison.Ordinal)) is { } last)
        {
            var rest = last["RESULT: ".Length..].TrimEnd();
            if (rest == "ok" || rest.StartsWith("ok ", StringComparison.Ordinal)) return Ok;
            if (rest.StartsWith("error", StringComparison.Ordinal)) return Failed(rest["error".Length..].Trim());
        }
        return Failed(lines.LastOrDefault(l => l.Trim().Length > 0)?.Trim() ?? "");
    }
}

/// <summary>Runs the check off the caller's thread, in a Job like every engine script, and ends it after a timeout.</summary>
public static class AssistantCheckScript
{
    public const string Script = "check_assistant.py";

    /// <summary>The engine itself gives the CLI 120 s; the interpreter's start and the journal fit in the rest.</summary>
    public static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(150);

    /// <summary>check_assistant.py's argument: claude, codex, cursor.</summary>
    public static string Argument(Assistant a) => a switch
    {
        Assistant.Claude => "claude",
        Assistant.Codex => "codex",
        Assistant.Cursor => "cursor",
        _ => throw new ArgumentOutOfRangeException(nameof(a), "no assistant to check"),
    };

    public static async Task<AssistantCheck> RunAsync(EngineLayout layout, EngineOptions options, Assistant assistant, TimeSpan? timeout = null)
    {
        if (!layout.IsInstalled) return AssistantCheck.Failed($"the engine is not installed: {layout.Python}");
        var lines = new List<string>();
        var request = new EngineRunRequest(layout.Python, [layout.Script(Script), Argument(assistant)],
                                           EngineEnvironment.Build(layout, options), layout.Data);
        EngineProcess process;
        try
        {
            process = await Task.Run(() => EngineProcess.Start(request, line =>
            {
                lock (lines) lines.Add(line);
            }));
        }
        catch (EngineStartException e)
        {
            return AssistantCheck.Failed(e.Message);
        }
        var limit = timeout ?? DefaultTimeout;
        int code;
        try
        {
            code = await process.Completion.WaitAsync(limit);
        }
        catch (TimeoutException)
        {
            process.Terminate();
            await process.Completion;
            return new AssistantCheck(AssistantCheckState.Failed, "", TimedOut: true);
        }
        lock (lines) return AssistantCheck.Parse(lines.ToList(), code);
    }
}
