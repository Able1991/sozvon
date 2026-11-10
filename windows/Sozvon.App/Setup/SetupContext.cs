namespace Sozvon.App.Setup;

/// <summary>Where the wizard reads the engine from and where it installs it.</summary>
internal sealed record SetupContext(string DataFolder, string EngineFolder)
{
    public string SetupScript => Path.Combine(EngineFolder, "setup.ps1");
    public string ModelsManifest => Path.Combine(EngineFolder, "models.json");
    public string Python => Path.Combine(DataFolder, ".venv", "Scripts", "python.exe");
    public string EnvFile => Path.Combine(DataFolder, ".env");
    public string LogFile => Path.Combine(DataFolder, "setup.log");
    public string SettingsFile => Path.Combine(DataFolder, "settings.json");

    public static string DefaultDataFolder =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Sozvon");

    /// <summary>The engine next to the executable, or in a repository above it during development.</summary>
    public static string? FindEngineFolder()
    {
        for (var folder = new DirectoryInfo(AppContext.BaseDirectory); folder is not null; folder = folder.Parent)
        {
            var candidate = Path.Combine(folder.FullName, "engine");
            if (File.Exists(Path.Combine(candidate, "setup.ps1")))
            {
                return candidate;
            }
        }
        return null;
    }
}
