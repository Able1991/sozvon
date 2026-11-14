using System.Text.Json.Nodes;
using Sozvon.Core.Foundation;

namespace Sozvon.Core.Engine;

/// <summary>Why Settings says setup isn't finished.</summary>
public enum SetupProblem { EngineMissing, ModelMissing }

/// <summary>What the top of Settings, General shows about setup.</summary>
public enum SetupBanner { None, Installing, Incomplete }

/// <summary>Where the wizard's install step is.</summary>
public enum InstallPhase { Running, Failed, Stopped, Done }

/// <summary>The install step's main button.</summary>
public enum InstallAction { Continue, Retry, ContinueInstall }

/// <summary>The install step's footer: Back is always there and stops a running download.</summary>
public sealed record InstallFooter(InstallAction Action, bool Enabled);

/// <summary>Where the setup wizard opens and what it counts as a finished install (the Mac's SetupFlow).</summary>
public static class SetupFlow
{
    /// <summary>Index of the model step: welcome, assistant, details, model, engine, microphone, ready.</summary>
    public const int ModelStep = 3;

    /// <summary>Index of the download step, right after the model choice.</summary>
    public const int InstallStep = ModelStep + 1;

    /// <summary>
    /// The wizard goes past the download only with a fully ready engine. <see cref="EngineStateKind.NeedsUpdate"/> is
    /// usable for an app set up before, but after a stopped first install it is a venv without the model.
    /// </summary>
    public static bool Installed(EngineStateKind engine) => engine == EngineStateKind.Ready;

    /// <summary>
    /// The step to open on: the one it was closed on, except past the download without a ready engine, then the model
    /// choice (the download can't be skipped; what was downloaded stays and the download continues).
    /// </summary>
    public static int Resume(int? saved, EngineStateKind engine) => saved switch
    {
        null or < 0 => 0,
        > ModelStep when !Installed(engine) => ModelStep,
        { } step => step,
    };

    /// <summary>Setup was finished once. Installs from before the progress file: set up if the engine works and no step is saved.</summary>
    public static bool IsDone(SetupProgress progress, EngineStateKind engine) =>
        progress.Done ?? (EngineState.IsUsable(engine) && progress.Step is null);

    /// <summary>The app opens the wizard at its start: setup unfinished, or the engine or its model missing.</summary>
    public static bool OpensAtStart(SetupProgress progress, EngineStateKind engine) =>
        !IsDone(progress, engine) || !EngineState.IsUsable(engine);

    /// <summary>"Finish Setup…": an unfinished setup continues where it was closed; after setup, the model choice.</summary>
    public static int OpenAt(SetupProgress progress, EngineStateKind engine) =>
        IsDone(progress, engine) ? ModelStep : Resume(progress.Step, engine);

    public static SetupProblem? Problem(EngineStateKind engine) => engine switch
    {
        EngineStateKind.NotInstalled => SetupProblem.EngineMissing,
        EngineStateKind.ModelMissing => SetupProblem.ModelMissing,
        _ => null,
    };

    /// <summary>A running install shows what it is doing instead of a button; otherwise the problem, if there is one.</summary>
    public static SetupBanner Banner(EngineStateKind engine, bool installing) =>
        installing ? (Installed(engine) ? SetupBanner.None : SetupBanner.Installing)
        : Problem(engine) is null ? SetupBanner.None : SetupBanner.Incomplete;

    /// <summary>No Stop and no skipping: Continue only once everything is downloaded.</summary>
    public static InstallFooter Footer(InstallPhase phase) => phase switch
    {
        InstallPhase.Running => new(InstallAction.Continue, Enabled: false),
        InstallPhase.Done => new(InstallAction.Continue, Enabled: true),
        InstallPhase.Failed => new(InstallAction.Retry, Enabled: true),
        _ => new(InstallAction.ContinueInstall, Enabled: true),
    };
}

/// <summary>
/// The wizard's step and whether setup was finished, in setup.json of the data folder. The wizard is its own process:
/// it writes the file, the app reads it.
/// </summary>
public sealed record SetupProgress(int? Step, bool? Done)
{
    public const string FileName = "setup.json";

    public static SetupProgress None { get; } = new(null, null);

    public static string PathIn(string dataFolder) => Path.Combine(dataFolder, FileName);

    public static SetupProgress Load(string dataFolder)
    {
        var json = JsonFile.Read(PathIn(dataFolder));
        if (json is null) return None;
        return new(Integer(json["step"]), json["done"] is JsonValue done && done.TryGetValue<bool>(out var d) ? d : null);
    }

    public static void SaveStep(string dataFolder, int step) =>
        JsonFile.WriteAtomic(PathIn(dataFolder), new JsonObject { ["step"] = step, ["done"] = false });

    public static void SaveDone(string dataFolder) =>
        JsonFile.WriteAtomic(PathIn(dataFolder), new JsonObject { ["done"] = true });

    private static int? Integer(JsonNode? node) => node is JsonValue value && value.TryGetValue<int>(out var i) ? i : null;
}

/// <summary>setup.log of a running install: the wizard keeps it open for writing until setup.ps1 ends.</summary>
public static class SetupLog
{
    public const string FileName = "setup.log";
    public const string PhasePrefix = "==> ";
    private const int TailBytes = 64 * 1024;

    public static string PathIn(string dataFolder) => Path.Combine(dataFolder, FileName);

    /// <summary>The current step of the install: the text of the last "==> " line, or "".</summary>
    public static string Phase(IEnumerable<string> lines) =>
        lines.LastOrDefault(l => l.StartsWith(PhasePrefix, StringComparison.Ordinal))?[PhasePrefix.Length..].Trim() ?? "";

    /// <summary>
    /// An install is running: someone holds the log open for writing. Opening it while refusing to share writing fails
    /// exactly then, and the handle goes away with the wizard, however it ended.
    /// </summary>
    public static bool IsBeingWritten(string path)
    {
        try
        {
            using var _ = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete);
            return false;
        }
        catch (FileNotFoundException)
        {
            return false;
        }
        catch (DirectoryNotFoundException)
        {
            return false;
        }
        catch (IOException)
        {
            return true;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
    }

    /// <summary>The last lines of the log, read beside the writer.</summary>
    public static IReadOnlyList<string> Tail(string path)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            stream.Seek(Math.Max(0, stream.Length - TailBytes), SeekOrigin.Begin);
            using var reader = new StreamReader(stream);
            return reader.ReadToEnd().Split('\n').Select(l => l.TrimEnd('\r')).ToList();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return [];
        }
    }
}
