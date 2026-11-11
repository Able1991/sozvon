using CommunityToolkit.Mvvm.ComponentModel;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Sozvon.Core.Calls;
using Sozvon.Core.Foundation;
using Windows.Storage.Pickers;

namespace Sozvon.App.Settings;

/// <summary>
/// "Change Folder…" next to the calls folder (the setup wizard, Settings, Recognition, Files), as on the Mac
/// (CallsFolderChanger.swift): pick a folder, offer to move the calls there, apply it at once. The rules and the move
/// itself are in Sozvon.Core (<see cref="CallsFolder"/>). The app and the wizard each make their own, with their own
/// texts and their own idea of "busy".
/// </summary>
/// <param name="settingsFile">settings.json of the data folder: the choice is kept there.</param>
/// <param name="current">The calls folder in use now.</param>
/// <param name="busy">Recording or transcribing now: the folder stays.</param>
/// <param name="switched">After a change: everything follows the new folder.</param>
/// <param name="text">The process's string table: Loc.L in the app, the wizard's Strings.L.</param>
public sealed partial class CallsFolderChanger(string settingsFile, string dataFolder, string defaultFolder, Func<string> current, Func<bool> busy,
    Action<string> switched, Func<string, object[], string> text) : ObservableObject
{
    /// <summary>
    /// Tests only: the folder "picked" instead of the system's folder picker, which UI automation must never open.
    /// </summary>
    public const string TestPickVariable = "SOZVON_TEST_PICK_CALLS_FOLDER";

    private int _testPicks;

    /// <summary>"Moving calls: 3 of 40" while calls are moved, null otherwise.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Shown), nameof(CanChange))]
    public partial string? Moving { get; private set; }

    public string Current => current();

    /// <summary>The row's second line: the folder, or the progress of a move.</summary>
    public string Shown => Moving ?? Current;

    public bool CanChange => Moving is null;

    /// <summary>The folder changed from outside (the wizard): the row shows the new one.</summary>
    public void Refresh()
    {
        OnPropertyChanged(nameof(Current));
        OnPropertyChanged(nameof(Shown));
    }

    public async Task ChangeAsync(XamlRoot root)
    {
        if (Moving is not null)
        {
            return;
        }
        if (busy())
        {
            await TellAsync(root, L("Сейчас идёт запись или расшифровка"), L("Папку звонков можно сменить, когда они закончатся."));
            return;
        }
        if (await PickAsync(root) is { } chosen)
        {
            await ApplyAsync(root, chosen);
        }
    }

    public async Task ApplyAsync(XamlRoot root, string chosen)
    {
        var old = Current;
        if (CallsFolder.Problem(old, chosen, dataFolder) is { } problem)
        {
            if (problem != CallsFolderProblem.Same)
            {
                await TellAsync(root, L("Эта папка не подходит"), Explain(problem));
            }
            return;
        }
        var calls = CallsFolder.Calls(old);
        if (calls.Count == 0)
        {
            await SwitchToAsync(root, chosen);
            return;
        }
        var dialog = Dialog(root, L("Перенести звонки в «%@»?", Path.GetFileName(Path.TrimEndingDirectorySeparator(chosen))),
            L("Звонков: %@. Они переедут из «%@» вместе с аудио и заметками. Если не переносить, Sozvon будет показывать только звонки из новой папки, а старые останутся на месте.",
              calls.Count, old));
        dialog.PrimaryButtonText = L("Перенести");
        dialog.SecondaryButtonText = L("Не переносить");
        dialog.CloseButtonText = L("Отмена");
        dialog.DefaultButton = ContentDialogButton.Primary;
        switch (await dialog.ShowAsync())
        {
            case ContentDialogResult.Primary:
                await MoveAsync(root, old, chosen);
                break;
            case ContentDialogResult.Secondary:
                await SwitchToAsync(root, chosen);
                break;
        }
    }

    private async Task MoveAsync(XamlRoot root, string old, string chosen)
    {
        Moving = L("Переношу звонки…");
        var dispatcher = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        var error = await Task.Run(() =>
        {
            try
            {
                CallsFolder.Move(old, chosen, trash: RecycleBin.Move,
                    progress: (done, total) => dispatcher.TryEnqueue(() =>
                    {
                        // A report still queued when the move has ended must not bring the progress back.
                        if (Moving is not null) Moving = L("Переношу звонки: %@ из %@", done, total);
                    }));
                return null;
            }
            catch (CallsFolderMoveException e) when (e.Taken.Count > 0)
            {
                return L("В новой папке уже есть звонки с такими же именами: %@. Ничего не перенесено.", string.Join(", ", e.Taken.Take(3)));
            }
            catch (CallsFolderMoveException e)
            {
                return L("Копия звонка «%@» не совпала с оригиналом. Оригинал остался на месте, папка не сменилась.", e.Mismatch ?? "");
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                return e.Message;
            }
        });
        Moving = null;
        if (error is not null)
        {
            await TellAsync(root, L("Не получилось перенести звонки"), error);
            // What already moved stays in the new folder: switch to it only when everything is there.
            if (CallsFolder.Calls(chosen).Count > 0 && CallsFolder.Calls(old).Count == 0)
            {
                await SwitchToAsync(root, chosen);
            }
            return;
        }
        await SwitchToAsync(root, chosen);
    }

    private async Task SwitchToAsync(XamlRoot root, string chosen)
    {
        try
        {
            Directory.CreateDirectory(chosen);
            CallsFolder.Choose(settingsFile, chosen, defaultFolder);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            await TellAsync(root, L("Эта папка не подходит"), e.Message);
            return;
        }
        switched(Path.GetFullPath(chosen));
        Refresh();
    }

    /// <summary>The system's folder picker, owned by the window; a test gives the folder through <see cref="TestPickVariable"/> instead.</summary>
    private async Task<string?> PickAsync(XamlRoot root)
    {
        if (Environment.GetEnvironmentVariable(TestPickVariable) is { Length: > 0 } given)
        {
            // Several folders separated by "|": one per press, the last one again after that.
            var folders = given.Split('|');
            return folders[Math.Min(_testPicks++, folders.Length - 1)];
        }
        var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.ComputerFolder, CommitButtonText = L("Выбрать") };
        picker.FileTypeFilter.Add("*");
        var window = Win32Interop.GetWindowFromWindowId(root.ContentIslandEnvironment.AppWindowId);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, window);
        return await picker.PickSingleFolderAsync() is { Path.Length: > 0 } folder ? folder.Path : null;
    }

    private string Explain(CallsFolderProblem problem) => problem switch
    {
        CallsFolderProblem.Inside => L("Она внутри нынешней папки звонков. Выбери папку рядом или в другом месте."),
        CallsFolderProblem.Contains => L("Нынешняя папка звонков лежит внутри неё. Выбери другую папку."),
        CallsFolderProblem.EngineData => L("Это папка движка Sozvon: при переустановке звонки пропали бы. Выбери другую."),
        _ => "",
    };

    private async Task TellAsync(XamlRoot root, string title, string message)
    {
        var dialog = Dialog(root, title, message);
        dialog.CloseButtonText = L("OK");
        dialog.DefaultButton = ContentDialogButton.Close;
        await dialog.ShowAsync();
    }

    private static ContentDialog Dialog(XamlRoot root, string title, string message) => new()
    {
        XamlRoot = root,
        RequestedTheme = Shell.Dialogs.ThemeOf(root),
        Title = title,
        Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
    };

    private string L(string key, params object[] arguments) => text(key, arguments);
}
