using System.IO;

namespace Sozvon.App.Shell;

/// <summary>The app's folders. The engine's own variables take precedence, as in docs/CONTRACT.md.</summary>
public static class AppPaths
{
    public static string DataDir { get; } = FromEnvironment("SOZVON_DATA_DIR")
        ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Sozvon");

    public static string CallsDir { get; } = FromEnvironment("SOZVON_CALLS_DIR")
        ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Sozvon Calls");

    public static string SettingsFile => Path.Combine(DataDir, "settings.json");

    public static string EnvFile => Path.Combine(DataDir, ".env");

    public static string EnginePython => Path.Combine(DataDir, ".venv", "Scripts", "python.exe");

    public static string InstalledMarker => Path.Combine(DataDir, ".installed");

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

    private static string? FromEnvironment(string name)
    {
        var value = Environment.GetEnvironmentVariable(name);
        return string.IsNullOrWhiteSpace(value) ? null : value;
    }
}
