using System.IO;
using Sozvon.Core.Calls;
using Sozvon.Core.Engine;

namespace Sozvon.App.Shell;

/// <summary>The app's folders. The engine's own variables take precedence, as in docs/CONTRACT.md.</summary>
public static class AppPaths
{
    private static readonly EngineLayout Defaults = EngineLayout.Default();

    public static string DataDir { get; } = Given(Environment.GetEnvironmentVariable("SOZVON_DATA_DIR")) ?? Defaults.Data;

    /// <summary>
    /// The calls folder of this moment: SOZVON_CALLS_DIR, the folder chosen in the wizard or Settings
    /// (<see cref="CallsFolder.SettingKey"/> in settings.json), or %USERPROFILE%\Sozvon Calls. A change in Settings
    /// applies at once (<see cref="ChangeCallsDir"/>), as on the Mac.
    /// </summary>
    public static string CallsDir { get; private set; } =
        CallsFolder.Current(Path.Combine(DataDir, "settings.json"), Defaults.Calls, Environment.GetEnvironmentVariable("SOZVON_CALLS_DIR"));

    /// <summary>%USERPROFILE%\Sozvon Calls: choosing it again removes the choice.</summary>
    public static string DefaultCallsDir => Defaults.Calls;

    /// <summary>The calls folder changed: the list, the MCP server and the next runs follow it. Raised on the UI thread.</summary>
    public static event Action? CallsDirChanged;

    /// <summary>The app's layout, its calls folder read live.</summary>
    public static EngineLayout Layout { get; } = new(DataDir, () => CallsDir);

    public static string SettingsFile => Path.Combine(DataDir, "settings.json");

    public static string EnvFile => Path.Combine(DataDir, ".env");

    public static void ChangeCallsDir(string folder)
    {
        if (CallsFolder.SamePath(folder, CallsDir))
        {
            return;
        }
        CallsDir = Path.GetFullPath(folder);
        CallsDirChanged?.Invoke();
    }

    /// <summary>
    /// One running app per data folder: a run with its own SOZVON_DATA_DIR (a test, a second profile)
    /// must not hand its launch over to the Sozvon the user works in.
    /// </summary>
    public static string InstanceKey(string name)
    {
        var folder = Path.GetFullPath(DataDir).TrimEnd(Path.DirectorySeparatorChar).ToUpperInvariant();
        var hash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(folder)));
        return $"{name}-{hash[..16]}";
    }

    public static string Asset(string name) => Path.Combine(AppContext.BaseDirectory, "Shell", "Assets", name);

    private static string? Given(string? value) => string.IsNullOrWhiteSpace(value) ? null : value;
}
