using System.ComponentModel;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Sozvon.App.Shell;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.System;
using static Sozvon.App.Strings.Loc;

namespace Sozvon.App.Calls;

public sealed partial class CallsPage : UserControl
{
    private bool _importing;

    /// <summary>A "could not delete / bring back" dialog is up; another one over it would take the app down.</summary>
    private bool _problemShowing;

    /// <summary>Hides "Звонок в Корзине" a few seconds after a deletion; Ctrl+Z keeps working after that.</summary>
    private readonly DispatcherTimer _trashBarTimer = new() { Interval = TimeSpan.FromSeconds(6) };

    private static readonly Windows.UI.Color[] ProjectColors =
    [
        ColorHelper.FromArgb(255, 0xE0, 0x8A, 0x3C),
        ColorHelper.FromArgb(255, 0xE5, 0x48, 0x4D),
        ColorHelper.FromArgb(255, 0xA9, 0x84, 0x67),
        ColorHelper.FromArgb(255, 0x8A, 0x8A, 0x8A),
        ColorHelper.FromArgb(255, 0x2E, 0x8B, 0x57),
        ColorHelper.FromArgb(255, 0x6B, 0x5B, 0xD6),
    ];

    public CallsPage(CallsViewModel viewModel)
    {
        ViewModel = viewModel;
        InitializeComponent();
        ViewModel.PropertyChanged += OnViewModelChanged;
        ViewModel.Projects.CollectionChanged += (_, _) => RebuildProjectMenu();
        GroupedCalls.Source = ViewModel.Groups;
        RebuildProjectMenu();
        ShowDetail();
        _trashBarTimer.Tick += (_, _) => HideTrashBar();
        // Ctrl+Z anywhere on the page but in a text field, which keeps its own undo.
        var undo = new KeyboardAccelerator { Key = VirtualKey.Z, Modifiers = VirtualKeyModifiers.Control };
        undo.Invoked += OnUndoAccelerator;
        Root.KeyboardAccelerators.Add(undo);
    }

    public CallsViewModel ViewModel { get; }

    public static Brush ProjectBrush(string slug) =>
        new SolidColorBrush(ProjectColors[(uint)StableHash(slug) % ProjectColors.Length]);

    public static Visibility Shown(string text) => text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;

    public static Visibility ShownIf(bool value, bool expected) => value == expected ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>Ctrl+F: the find bar of the opened call's transcript; false when that is not what is on screen.</summary>
    public bool OpenTranscriptFind() => ViewModel.Detail is not null && Detail.OpenFind();

    /// <summary>Delete on the list, as in File Explorer: the selected call to the Recycle Bin.</summary>
    private void OnListKeyDown(object sender, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Delete && ViewModel.SelectedRow is not null)
        {
            e.Handled = true;
            Trash();
        }
    }

    private void OnTrashRequested(object? sender, EventArgs e) => Trash();

    /// <summary>No confirmation, as in Finder: the call goes to the Recycle Bin and the bar offers to bring it back.</summary>
    private async void Trash()
    {
        if (_problemShowing)
        {
            return;
        }
        var problem = await ViewModel.TrashSelectedAsync();
        if (ViewModel.Actions.CanUndoTrash)
        {
            ShowTrashBar();
        }
        await ShowProblemAsync(problem);
    }

    /// <summary>
    /// The reason a call could not be deleted or brought back. One at a time: a second ContentDialog over the first
    /// is refused by XAML with an exception that would take the app down.
    /// </summary>
    private async Task ShowProblemAsync(string? problem)
    {
        if (problem is null || _problemShowing)
        {
            return;
        }
        _problemShowing = true;
        try
        {
            await new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = Shell.Dialogs.ThemeOf(XamlRoot), Title = problem, CloseButtonText = "OK" }.ShowAsync();
        }
        finally
        {
            _problemShowing = false;
        }
    }

    private void OnUndoTrashRequested(object? sender, EventArgs e) => UndoTrash();

    private void OnUndoTrash(object sender, RoutedEventArgs e) => UndoTrash();

    /// <summary>Ctrl+Z: the last deleted call comes back, unless a text field has the focus and undoes its own typing.</summary>
    private void OnUndoAccelerator(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (FocusManager.GetFocusedElement(XamlRoot) is TextBox or RichEditBox or AutoSuggestBox or PasswordBox || !ViewModel.Actions.CanUndoTrash)
        {
            return;
        }
        args.Handled = true;
        UndoTrash();
    }

    private async void UndoTrash()
    {
        if (_problemShowing)
        {
            return;
        }
        HideTrashBar();
        await ShowProblemAsync(await ViewModel.UndoTrashAsync());
    }

    private void ShowTrashBar()
    {
        _trashBarTimer.Stop();
        TrashBar.Visibility = Visibility.Visible;
        TrashBar.IsOpen = true;
        _trashBarTimer.Start();
    }

    private void HideTrashBar()
    {
        _trashBarTimer.Stop();
        TrashBar.IsOpen = false;
        TrashBar.Visibility = Visibility.Collapsed;
    }

    private void OnTrashBarClosed(InfoBar sender, InfoBarClosedEventArgs args) => HideTrashBar();

    private void OnDragOver(object sender, DragEventArgs e)
    {
        if (e.DataView.Contains(StandardDataFormats.StorageItems) && !_importing)
        {
            e.AcceptedOperation = DataPackageOperation.Copy;
            e.DragUIOverride.Caption = L("Импортировать запись");
        }
    }

    /// <summary>Dropped files: the recordings among them are imported one after another, the rest explained.</summary>
    private async void OnDrop(object sender, DragEventArgs e)
    {
        if (_importing || !e.DataView.Contains(StandardDataFormats.StorageItems))
        {
            return;
        }
        var deferral = e.GetDeferral();
        var files = (await e.DataView.GetStorageItemsAsync()).OfType<StorageFile>().Select(f => f.Path).Where(p => p.Length > 0).ToList();
        deferral.Complete();
        if (files.Count == 0)
        {
            return;
        }
        _importing = true;
        ImportBar.Visibility = Visibility.Visible;
        ImportBar.IsOpen = true;
        var progress = new Progress<(string Name, double Fraction)>(p =>
        {
            ImportBar.Title = L("Импортируется «%@»…", p.Name);
            ImportProgress.Value = p.Fraction;
        });
        try
        {
            var problems = await ViewModel.Actions.ImportAsync(files, AppPaths.CallsDir, progress);
            if (problems.Count > 0)
            {
                await new ContentDialog
                {
                    XamlRoot = XamlRoot,
                    RequestedTheme = Shell.Dialogs.ThemeOf(XamlRoot),
                    Title = L("Не все записи импортированы"),
                    Content = new TextBlock { Text = string.Join("\n", problems), TextWrapping = TextWrapping.Wrap },
                    CloseButtonText = "OK",
                }.ShowAsync();
            }
        }
        finally
        {
            _importing = false;
            ImportBar.IsOpen = false;
            ImportBar.Visibility = Visibility.Collapsed;
        }
    }

    private void OnCallSelected(object sender, SelectionChangedEventArgs e) => ViewModel.SelectedRow = CallList.SelectedItem as CallRow;

    private static int StableHash(string text) => text.Aggregate(17, (hash, c) => unchecked(hash * 31 + c));

    private void OnViewModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(CallsViewModel.SelectedRow):
                CallList.SelectedItem = ViewModel.SelectedRow;
                break;
            case nameof(CallsViewModel.Detail):
                ShowDetail();
                break;
            case nameof(CallsViewModel.SelectedProject):
                // The tick follows a filter changed in code too (a rename, "Последняя расшифровка" clearing it).
                ProjectButton.Content = ViewModel.SelectedProject.Title;
                foreach (var item in ProjectMenu.Items.OfType<RadioMenuFlyoutItem>())
                {
                    item.IsChecked = Equals(item.Tag, ViewModel.SelectedProject);
                }
                break;
        }
    }

    private void ShowDetail()
    {
        Detail.ViewModel = ViewModel.Detail;
        Detail.Visibility = ViewModel.Detail is null ? Visibility.Collapsed : Visibility.Visible;
        NoSelection.Visibility = ViewModel.Detail is null ? Visibility.Visible : Visibility.Collapsed;
    }

    private void RebuildProjectMenu()
    {
        ProjectButton.Content = ViewModel.SelectedProject.Title;
        ProjectMenu.Items.Clear();
        foreach (var project in ViewModel.Projects)
        {
            var item = new RadioMenuFlyoutItem { Text = project.Title, Tag = project, IsChecked = project == ViewModel.SelectedProject };
            item.Click += (_, _) => ViewModel.SelectedProject = project;
            ProjectMenu.Items.Add(item);
        }
    }
}
