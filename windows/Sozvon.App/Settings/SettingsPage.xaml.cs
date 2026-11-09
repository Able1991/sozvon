using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Sozvon.Core.Settings;
using static Sozvon.App.Strings.Loc;

namespace Sozvon.App.Settings;

public sealed partial class SettingsPage : UserControl
{
    public SettingsPage(SettingsViewModel viewModel)
    {
        ViewModel = viewModel;
        InitializeComponent();
        PythonStatus.Text = L(viewModel.EngineInstalled ? "Установлен" : "Не установлен");
        AddModels();
        CallLanguagesBox.Languages = ViewModel.CallLanguages;
        CallLanguagesBox.LanguagesChanged += (_, _) => ViewModel.CallLanguages = CallLanguagesBox.Languages;
    }

    public SettingsViewModel ViewModel { get; }

    /// <summary>In enum order: the box's index is the model. A model that is not on disk cannot be chosen: the engine would refuse the call.</summary>
    private void AddModels()
    {
        foreach (var model in Enum.GetValues<WhisperModel>())
        {
            var downloaded = model.IsDownloaded(ViewModel.DataFolder);
            ModelBox.Items.Add(new ComboBoxItem { Content = ModelTitle(model) + (downloaded ? "" : " · " + L("не скачана")), IsEnabled = downloaded });
        }
    }

    private static string ModelTitle(WhisperModel model) => model switch
    {
        WhisperModel.Turbo => "Whisper Turbo",
        WhisperModel.Large => "Whisper Large v3",
        WhisperModel.Small => "Whisper Small",
        WhisperModel.GigaAm => "GigaAM v3",
        _ => "Parakeet v3",
    };

    private void OnTabChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        var tag = (string)sender.SelectedItem.Tag;
        foreach (var pane in new[] { General, Recognition, Assistants, Cloud, About })
        {
            pane.Visibility = pane.Name == tag ? Visibility.Visible : Visibility.Collapsed;
        }
    }

    private void OnShowCallsFolder(object sender, RoutedEventArgs e) => ShowFolder(ViewModel.CallsFolder);

    private void OnShowDataFolder(object sender, RoutedEventArgs e) => ShowFolder(ViewModel.DataFolder);

    private void OnOpenMicrophoneSettings(object sender, RoutedEventArgs e) =>
        Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone") { UseShellExecute = true });

    private static void ShowFolder(string path)
    {
        Directory.CreateDirectory(path);
        Process.Start("explorer.exe", $"\"{path}\"");
    }
}
