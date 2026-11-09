using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using static Sozvon.App.Strings.Loc;

namespace Sozvon.App.Settings;

public sealed partial class SettingsPage : UserControl
{
    public SettingsPage(SettingsViewModel viewModel)
    {
        ViewModel = viewModel;
        InitializeComponent();
        PythonStatus.Text = L(viewModel.EngineInstalled ? "Установлен" : "Не установлен");
    }

    public SettingsViewModel ViewModel { get; }

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
