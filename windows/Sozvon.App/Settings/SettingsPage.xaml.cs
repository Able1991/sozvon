using System.Diagnostics;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Sozvon.App.VoicePrints;
using Microsoft.UI.Xaml.Input;
using Sozvon.Core.Server;
using Sozvon.Core.Settings;
using Windows.Storage.Pickers;
using Windows.System;
using static Sozvon.App.Strings.Loc;

namespace Sozvon.App.Settings;

public sealed partial class SettingsPage : UserControl
{
    private readonly MyVoice _myVoice;
    private readonly Action _showVoices;

    /// <param name="showVoices">"Manage…": the Voices page with every saved voice.</param>
    public SettingsPage(SettingsViewModel viewModel, MyVoice myVoice, Action showVoices)
    {
        ViewModel = viewModel;
        _myVoice = myVoice;
        _showVoices = showVoices;
        InitializeComponent();
        myVoice.Attach(MyVoiceRow);
        Loaded += (_, _) =>
        {
            myVoice.Store.Changed += OnVoicesChanged;
            ShowOtherVoices();
        };
        Unloaded += (_, _) => myVoice.Store.Changed -= OnVoicesChanged;
        PythonStatus.Text = L(viewModel.EngineInstalled ? "Установлен" : "Не установлен");
        AddModels();
        CallLanguagesBox.Languages = ViewModel.CallLanguages;
        CallLanguagesBox.LanguagesChanged += (_, _) => ViewModel.CallLanguages = CallLanguagesBox.Languages;
        ViewModel.Integrations.Confirm = ConfirmAsync;
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
        // Each look runs the assistants' tools again, as the Mac does when the pane appears.
        if (tag == nameof(Assistants) && !ViewModel.Integrations.Busy)
        {
            _ = ViewModel.Integrations.RefreshAsync();
        }
        else if (tag == nameof(Recognition))
        {
            _ = ViewModel.Integrations.RefreshServerAsync();
        }
        else if (tag == nameof(Cloud))
        {
            ViewModel.Server.Appeared();
        }
    }

    private void OnServerFieldKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter)
        {
            ViewModel.Server.Save();
            e.Handled = true;
        }
    }

    private void OnSaveServer(object sender, RoutedEventArgs e) => ViewModel.Server.Save();

    private void OnSyncServer(object sender, RoutedEventArgs e) => ViewModel.Server.SyncNow();

    private void OnCopyConnector(object sender, RoutedEventArgs e) => ServerViewModel.Copy(ViewModel.Server.ConnectorUrl);

    private void OnCopyServerPassword(object sender, RoutedEventArgs e) => ViewModel.Server.CopyPassword();

    /// <summary>As on the Mac: the address goes to the clipboard, and Claude's "Add custom connector" opens.</summary>
    private async void OnOpenClaudeConnectors(object sender, RoutedEventArgs e)
    {
        ServerViewModel.Copy(ViewModel.Server.ConnectorUrl);
        await Launcher.LaunchUriAsync(OwnServer.ClaudeConnectorsUrl);
    }

    private async void OnOpenChatGptConnectors(object sender, RoutedEventArgs e) => await Launcher.LaunchUriAsync(OwnServer.ChatGptConnectorsUrl);

    /// <summary>The system's folder picker, owned by this window.</summary>
    private async void OnChoosePhoneFolder(object sender, RoutedEventArgs e)
    {
        var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.ComputerFolder };
        picker.FileTypeFilter.Add("*");
        var window = Win32Interop.GetWindowFromWindowId(XamlRoot.ContentIslandEnvironment.AppWindowId);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, window);
        if (await picker.PickSingleFolderAsync() is { Path.Length: > 0 } folder)
        {
            ViewModel.Settings.PhoneFolder = folder.Path;
        }
    }

    private void OnClearPhoneFolder(object sender, RoutedEventArgs e) => ViewModel.Settings.PhoneFolder = "";

    private async void OnAssistantAction(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is AssistantRow row)
        {
            await ViewModel.Integrations.ActAsync(row);
        }
    }

    private void OnCopyAssistantCommand(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is AssistantRow row)
        {
            ViewModel.Integrations.Copy(row);
        }
    }

    private async Task<bool> ConfirmAsync(string title, string text, string destructive)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = title,
            Content = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap },
            PrimaryButtonText = destructive,
            CloseButtonText = L("Отмена"),
            DefaultButton = ContentDialogButton.Close,
        };
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }

    private void OnVoicesChanged(object? sender, EventArgs e) => ShowOtherVoices();

    /// <summary>"Голоса собеседников": the names, how many, and Manage, which waits for at least one voice.</summary>
    private void ShowOtherVoices()
    {
        var store = _myVoice.Store;
        var names = Sozvon.Core.Calls.Voices.OtherNames(store.Records);
        OtherVoicesRow.Description = names.Count == 0 ? L("Пока нет: имена подставятся, когда ты подпишешь спикеров") : string.Join(", ", names);
        OtherVoicesCount.Text = store.Records.Count(r => !r.Me).ToString(Culture);
        ManageVoicesButton.IsEnabled = store.Records.Count > 0;
    }

    private void OnManageVoices(object sender, RoutedEventArgs e) => _showVoices();

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
