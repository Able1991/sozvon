namespace Sozvon.Core.Engine;

/// <summary>Where the engine and the calls live on Windows.</summary>
public sealed record EngineLayout(string Data, string Calls)
{
    /// <summary>The default folders: data in %LOCALAPPDATA%\Sozvon, calls in the profile, outside any OneDrive redirect.</summary>
    public static EngineLayout Default() => new(
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Sozvon"),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Sozvon Calls"));

    public string Python => Path.Combine(Data, ".venv", "Scripts", "python.exe");
    public string ScriptsFolder => Path.GetDirectoryName(Python)!;
    public string Profiles => Path.Combine(Data, "profiles");
    public string Voices => Path.Combine(Data, "voices");
    public string Env => Path.Combine(Data, ".env");
    public bool IsInstalled => File.Exists(Python);

    public string Script(string name) => Path.Combine(Data, "bin", name);
}

/// <summary>What the app decides for every engine run (contract section 2).</summary>
/// <param name="Threads">SOZVON_THREADS; null leaves the engine's own default.</param>
public sealed record EngineOptions(string UiLanguage = "ru", int? Threads = null, int? McpPort = null, string? McpToken = null);

public static class EngineEnvironment
{
    public const string StopEventVariable = "SOZVON_STOP_EVENT";

    /// <summary>The environment of an engine run: the base one with the contract's variables on top.</summary>
    public static Dictionary<string, string> Build(EngineLayout layout, EngineOptions options, IEnumerable<KeyValuePair<string, string>>? baseEnvironment = null)
    {
        var env = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (key, value) in baseEnvironment ?? Inherited())
            if (key.Length > 0 && key[0] != '=') env[key] = value;

        env["PATH"] = env.TryGetValue("PATH", out var path) && path.Length > 0
            ? layout.ScriptsFolder + Path.PathSeparator + path
            : layout.ScriptsFolder;
        env["PYTHONUTF8"] = "1";
        env["PYTHONIOENCODING"] = "utf-8";
        env["PYTHONUNBUFFERED"] = "1";
        env["SOZVON_DATA_DIR"] = layout.Data;
        env["SOZVON_CALLS_DIR"] = layout.Calls;
        env["SOZVON_UI_LANG"] = options.UiLanguage;
        SetOrRemove(env, "SOZVON_THREADS", options.Threads?.ToString());
        SetOrRemove(env, "SOZVON_MCP_PORT", options.McpPort?.ToString());
        SetOrRemove(env, "SOZVON_MCP_TOKEN", options.McpToken);
        env.Remove(StopEventVariable);
        return env;
    }

    private static void SetOrRemove(Dictionary<string, string> env, string key, string? value)
    {
        if (value is null) env.Remove(key);
        else env[key] = value;
    }

    private static IEnumerable<KeyValuePair<string, string>> Inherited() =>
        Environment.GetEnvironmentVariables().Cast<System.Collections.DictionaryEntry>()
                   .Select(e => new KeyValuePair<string, string>((string)e.Key, (string?)e.Value ?? ""));
}
