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

    /// <summary>The last tab change came from a key on the tabs, not the mouse.</summary>
    private bool _tabsByKeyboard;
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
            Appeared();
        };
        Unloaded += (_, _) => myVoice.Store.Changed -= OnVoicesChanged;
        PythonStatus.Text = L(viewModel.EngineInstalled ? "Установлен" : "Не установлен");
        AddModels();
        AddRussianModels();
        AddAssistants();
        AddSummaryLanguages();
        CallLanguagesBox.Languages = ViewModel.CallLanguages;
        CallLanguagesBox.LanguagesChanged += (_, _) => ViewModel.CallLanguages = CallLanguagesBox.Languages;
        ViewModel.Integrations.Confirm = ConfirmAsync;
        ViewModel.CallsFolder.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(CallsFolderChanger.Current))
            {
                _ = ShowServerOnceUpAsync();
            }
        };
    }

    /// <summary>
    /// After a change of the calls folder the MCP server starts again: the row would keep "not answering" from the
    /// moment it was down, so it is asked again until the new server answers (half a minute at most).
    /// </summary>
    private async Task ShowServerOnceUpAsync()
    {
        for (var attempt = 0; attempt < 15; attempt++)
        {
            await Task.Delay(TimeSpan.FromSeconds(2));
            if ((await Sozvon.Core.Engine.McpHealth.ProbeAsync(ViewModel.Integrations.Endpoint)).State == Sozvon.Core.Engine.McpHealthState.Listening)
            {
                break;
            }
        }
        await ViewModel.Integrations.RefreshServerAsync();
    }

    public SettingsViewModel ViewModel { get; }

    /// <summary>
    /// The page came into view: on the page itself, the General tab, or the window shown again with Settings open. What
    /// Windows keeps (open at sign-in, maybe switched off in Task Manager meanwhile) is read again.
    /// </summary>
    public void Appeared() => ViewModel.SignIn.Refresh();

    /// <summary>In enum order: the box's index is the model. A model that is not on disk cannot be chosen: the engine would refuse the call.</summary>
    private void AddModels()
    {
        foreach (var model in Enum.GetValues<WhisperModel>())
        {
            var downloaded = model.IsDownloaded(ViewModel.DataFolder);
            ModelBox.Items.Add(new ComboBoxItem { Content = ModelTitle(model) + (downloaded ? "" : " · " + L("не скачана")), IsEnabled = downloaded });
        }
    }

    /// <summary>In enum order, as on the Mac: one whose command line tool is missing says so and can still be chosen.</summary>
    private void AddAssistants()
    {
        var home = Sozvon.Core.Assistants.AssistantHome.FromEnvironment();
        foreach (var assistant in Enum.GetValues<Assistant>())
        {
            var title = assistant == Assistant.None ? L("Без саммари") : Sozvon.Core.Assistants.AssistantCli.Title(assistant);
            var missing = assistant != Assistant.None && Sozvon.Core.Assistants.AssistantCli.Find(assistant, home) is null;
            AssistantBox.Items.Add(new ComboBoxItem { Content = title + (missing ? L(" (не найден)") : "") });
        }
        AssistantBox.SelectedIndex = ViewModel.SummaryAssistantIndex;
    }

    /// <summary>The conversation's language first, as on the Mac, then the real languages in the canonical order.</summary>
    private void AddSummaryLanguages()
    {
        foreach (var language in SettingsViewModel.SummaryLanguages)
        {
            SummaryLanguageBox.Items.Add(new ComboBoxItem { Content = language == SpeechLanguage.Auto ? L("Как в разговоре") : LanguagesButton.Title(language) });
        }
        SummaryLanguageBox.SelectedIndex = ViewModel.SummaryLanguageIndex;
    }

    private static string ModelTitle(WhisperModel model) => model.Title();

    /// <summary>
    /// "Для русского": unlike the main model, one not on disk can be chosen. Until it is downloaded the engine keeps
    /// Russian on the main model, and the engine block says so with "Download model…".
    /// </summary>
    private void AddRussianModels()
    {
        foreach (var model in SettingsViewModel.RussianModels)
        {
            var title = model is { } m ? ModelTitle(m) + (m.IsDownloaded(ViewModel.DataFolder) ? "" : " · " + L("не скачана")) : L("Та же модель");
            RussianModelBox.Items.Add(new ComboBoxItem { Content = title });
        }
    }

    /// <summary>The setup downloads what .env names, the model for Russian included; the Recognition tab reads the disk again when it is shown.</summary>
    private void OnDownloadModel(object sender, RoutedEventArgs e) => Shell.AppHost.Current?.OpenSetup();

    private void OnTabChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        var tag = (string)sender.SelectedItem.Tag;
        foreach (var pane in new[] { General, Recognition, Assistants, Cloud, About })
        {
            pane.Visibility = pane.Name == tag ? Visibility.Visible : Visibility.Collapsed;
        }
        Pane.ChangeView(null, 0, null, disableAnimation: true);
        // A tab chosen with the mouse (or through UI Automation) leaves no focus rectangle: the pane takes the focus as a
        // click would give it (Programmatic would still draw one after keyboard-like input such as UI Automation). Arrow
        // keys on the tabs are left alone, so keyboard users go on from where they are.
        if (!_tabsByKeyboard)
        {
            // After the click (or the automation call) has placed its own focus.
            DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => Pane.Focus(FocusState.Pointer));
        }
        _tabsByKeyboard = false;
        // Each look runs the assistants' tools again, as the Mac does when the pane appears.
        if (tag == nameof(Assistants))
        {
            _ = ViewModel.AssistantsAppearedAsync();
        }
        else if (tag == nameof(Recognition))
        {
            _ = ViewModel.Integrations.RefreshServerAsync();
            ViewModel.ShowModels();
        }
        else if (tag == nameof(Cloud))
        {
            ViewModel.Server.Appeared();
        }
        else if (tag == nameof(General))
        {
            Appeared();
        }
    }

    private void OnTabsKey(object sender, KeyRoutedEventArgs e) => _tabsByKeyboard = true;

    /// <summary>The hairline under the tabs shows only while some of the pane is scrolled under them.</summary>
    private void OnPaneScrolled(object? sender, ScrollViewerViewChangedEventArgs e) =>
        PaneDivider.Visibility = Pane.VerticalOffset > 0.5 ? Visibility.Visible : Visibility.Collapsed;

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
            await ViewModel.ActAsync(row);
        }
    }

    private void OnCheckSummary(object sender, RoutedEventArgs e) => ViewModel.CheckSummary();

    private async void OnShowLogs(object sender, RoutedEventArgs e) => await ViewModel.ShowLogsAsync();

    private void OnCopyAssistantCommand(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is AssistantRow row)
        {
            ViewModel.Integrations.Copy(row);
        }
    }

    /// <summary>"Disconnect Sozvon from …?": the shared question, which follows the window's theme.</summary>
    private Task<bool> ConfirmAsync(string title, string text, string destructive) =>
        Shell.Dialogs.ConfirmAsync(XamlRoot, title, text, destructive);

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

    private void OnShowCallsFolder(object sender, RoutedEventArgs e) => ShowFolder(ViewModel.CallsFolder.Current);

    private async void OnChangeCallsFolder(object sender, RoutedEventArgs e)
    {
        try
        {
            await ViewModel.CallsFolder.ChangeAsync(XamlRoot);
        }
        catch (Exception error)
        {
            Shell.AppHost.Log(error);
        }
    }

    private void OnShowDataFolder(object sender, RoutedEventArgs e) => ShowFolder(ViewModel.DataFolder);

    private void OnOpenMicrophoneSettings(object sender, RoutedEventArgs e) =>
        Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone") { UseShellExecute = true });

    private static void ShowFolder(string path)
    {
        Directory.CreateDirectory(path);
        Process.Start("explorer.exe", $"\"{path}\"");
    }
}
