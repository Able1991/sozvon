using System.ComponentModel;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using CommunityToolkit.Mvvm.ComponentModel;

namespace Sozvon.App.Settings;

/// <summary>Loads settings.json and writes it back atomically on every change.</summary>
public sealed partial class SettingsStore : ObservableObject
{
    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
    };

    private readonly string _path;

    public SettingsStore(string path)
    {
        _path = path;
        Settings = Load();
        Settings.PropertyChanged += OnChanged;
    }

    public AppSettings Settings { get; }

    /// <summary>The reason the last save failed; empty when it worked.</summary>
    [ObservableProperty] public partial string SaveError { get; private set; } = "";

    private AppSettings Load()
    {
        try
        {
            return File.Exists(_path)
                ? JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(_path), Options) ?? new AppSettings()
                : new AppSettings();
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            return new AppSettings();
        }
    }

    private void OnChanged(object? sender, PropertyChangedEventArgs e)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            var temp = _path + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(Settings, Options));
            File.Move(temp, _path, overwrite: true);
            SaveError = "";
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            SaveError = error.Message;
        }
    }
}
