using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Sozvon.App.Calls;
using Sozvon.App.Shell;
using Sozvon.App.Strings;
using Sozvon.App.VoicePrints;
using Sozvon.Core.Calls;
using Sozvon.Core.Foundation;
using static Sozvon.App.Strings.Loc;

namespace Sozvon.App.Projects;

/// <summary>A project in the list: its dot, title, and "3 человека · 5 терминов · 12 звонков".</summary>
public sealed class ProjectRow(Project project, string details)
{
    public Project Project { get; } = project;

    public string Details { get; } = details;

    public string Slug => Project.Slug;

    public string Title => Project.Title;

    public override string ToString() => $"{Title}, {Details}";
}

/// <summary>
/// Projects, as the Mac's Projects window: the list from profiles\*.json, which follows the folder by itself; a
/// double click or Enter opens the editor, Delete asks to move the file to the Recycle Bin. Project discovery is off
/// on Windows, so there is no search through an assistant here.
/// </summary>
public sealed partial class ProjectsPage : UserControl
{
    private readonly string _profiles;
    private readonly CallRepository _repository;
    private readonly VoiceStore _voices;
    private readonly Action _projectsChanged;
    private FileSystemWatcher? _watcher;
    private IReadOnlyDictionary<string, int> _callCounts = new Dictionary<string, int>();
    private List<Project> _projects = [];
    private bool _reloadQueued;
    private bool _deleting;

    /// <param name="projectsChanged">A project was saved or deleted here: the call list shows the new titles.</param>
    public ProjectsPage(string profilesFolder, CallRepository repository, VoiceStore voices, Action projectsChanged)
    {
        _profiles = profilesFolder;
        _repository = repository;
        _voices = voices;
        _projectsChanged = projectsChanged;
        InitializeComponent();
        // The items mark Enter handled before the list sees it.
        ProjectList.AddHandler(KeyDownEvent, new KeyEventHandler(OnListKeyDown), handledEventsToo: true);
        ProjectList.ContextFlyout = ListMenu();
        Loaded += OnLoaded;
        Unloaded += (_, _) =>
        {
            StopWatching();
            _voices.Changed -= OnVoicesChanged;
        };
    }

    public ObservableCollection<ProjectRow> Rows { get; } = [];

    private ProjectRow? Selected => ProjectList.SelectedItem as ProjectRow;

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        StartWatching();
        _voices.Changed += OnVoicesChanged;
        _voices.Refresh();
        Reload();
        ProjectList.Focus(FocusState.Programmatic);
        await CountCallsAsync();
    }

    /// <summary>Reads the projects again, keeping the selection.</summary>
    private void Reload(string? select = null)
    {
        _projects = Project.All(_profiles);
        select ??= Selected?.Slug;
        Rows.Clear();
        foreach (var project in _projects)
        {
            Rows.Add(new ProjectRow(project, Details(project)));
        }
        // The selected project stays selected; otherwise the first one, so the card is never empty for no reason.
        ProjectList.SelectedItem = Rows.FirstOrDefault(r => r.Slug == select) ?? Rows.FirstOrDefault();
        EmptyState.Visibility = Rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        ListPane.Visibility = Rows.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        ShowDetail();
        Summary.Text = Rows.Count == 0 ? "" : Count(_projects.Count, ("проект", "проекта", "проектов"), ("project", "projects"))
            + " · " + Count(Project.PeopleCount(_projects), ("человек", "человека", "человек"), ("person", "people"));
    }

    /// <summary>Calls per project, read in the background; the list shows them when they are in.</summary>
    private async Task CountCallsAsync()
    {
        try
        {
            var calls = await Task.Run(_repository.Scan);
            _callCounts = calls.Where(c => c.ProjectSlug.Length > 0).GroupBy(c => c.ProjectSlug).ToDictionary(g => g.Key, g => g.Count());
            Reload();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            AppHost.Log(error);
        }
    }

    private string Details(Project project)
    {
        var parts = new List<string>
        {
            Count(project.People.Count, ("человек", "человека", "человек"), ("person", "people")),
            Count(project.Terms.Count, ("термин", "термина", "терминов"), ("term", "terms")),
        };
        if (_callCounts.TryGetValue(project.Slug, out var calls))
        {
            parts.Add(Count(calls, ("звонок", "звонка", "звонков"), ("call", "calls")));
        }
        return string.Join(" · ", parts);
    }

    private static string Count(int n, (string, string, string) ru, (string, string) en) => Plural.Count(n, ru, en, Loc.IsRussian);

    private async Task EditAsync(Project project)
    {
        var dialog = new ProjectEditorDialog(project, _profiles, _voices, Dialogs.ThemeOf(XamlRoot)) { XamlRoot = XamlRoot };
        await dialog.ShowAsync();
        if (dialog.Saved is { } saved)
        {
            Reload(saved.Slug);
            _projectsChanged();
        }
        ProjectList.Focus(FocusState.Programmatic);
    }

    /// <summary>Asks, then removes the file under its lock off the UI thread: the lock may be held for a while.</summary>
    private async Task DeleteAsync(Project project)
    {
        if (_deleting)
        {
            return;
        }
        var sure = await Dialogs.ConfirmAsync(XamlRoot, L("Удалить проект «%@»?", project.Title),
            L("Звонки сохранят свои расшифровки. Уйдут только люди, термины и замены этого проекта. Файл попадёт в Корзину, его можно вернуть."),
            L("Удалить"));
        if (!sure)
        {
            return;
        }
        _deleting = true;
        try
        {
            await Task.Run(() => Project.Delete(project.Slug, _profiles, RecycleBin.Move));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or FileLockTimeoutException)
        {
            await Dialogs.ShowProblemAsync(XamlRoot, L("Не получилось удалить проект"), e.Message);
        }
        finally
        {
            _deleting = false;
        }
        Reload();
        _projectsChanged();
    }

    private void OnNew(object sender, RoutedEventArgs e) => _ = EditAsync(new Project("", ""));

    private void OnSelectionChanged(object sender, SelectionChangedEventArgs e) => ShowDetail();

    private void OnEdit(object sender, RoutedEventArgs e)
    {
        if (Selected is { } row)
        {
            _ = EditAsync(row.Project);
        }
    }

    private void OnDelete(object sender, RoutedEventArgs e)
    {
        if (Selected is { } row)
        {
            _ = DeleteAsync(row.Project);
        }
    }

    private void OnVoicesChanged(object? sender, EventArgs e) => ShowVoices();

    /// <summary>The card of the selected project: its full title, what its calls are about, people, terms and voices.</summary>
    private void ShowDetail()
    {
        var row = Selected;
        DetailScroller.Visibility = row is null ? Visibility.Collapsed : Visibility.Visible;
        NoSelection.Visibility = row is null && Rows.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (row is null)
        {
            return;
        }
        var project = row.Project;
        DetailDot.Fill = CallsPage.ProjectBrush(project.Slug);
        DetailTitle.Text = project.Title;
        DetailMeta.Text = row.Details;
        DetailContext.Text = Or(project.Context);
        DetailPeople.Text = Or(string.Join(", ", project.People));
        DetailTerms.Text = Or(string.Join(", ", project.Terms));
        VoiceProblem.IsOpen = false;
        ShowVoices();
        DetailScroller.ChangeView(null, 0, null, disableAnimation: true);
    }

    private static string Or(string text) => text.Length > 0 ? text : "—";

    private void ShowVoices()
    {
        DetailVoices.Children.Clear();
        if (Selected is not { } row)
        {
            return;
        }
        foreach (var voice in Sozvon.Core.Calls.Voices.ForProfile(_voices.Records, row.Slug))
        {
            DetailVoices.Children.Add(ProjectVoiceRow.Create(voice, !_voices.IsBusy, () => _ = DeleteVoiceAsync(voice)));
        }
        if (DetailVoices.Children.Count == 0)
        {
            // The hint about saving a voice is already under the list.
            DetailVoices.Children.Add(new TextBlock { Text = L("Голосов пока нет") });
        }
    }

    private async Task DeleteVoiceAsync(VoiceRecord voice)
    {
        var outcome = await _voices.DeleteAsync(voice);
        VoiceProblem.Message = outcome.Message;
        VoiceProblem.IsOpen = !outcome.IsOk;
    }

    private void OnListDoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if ((e.OriginalSource as FrameworkElement)?.DataContext is ProjectRow row)
        {
            _ = EditAsync(row.Project);
        }
    }

    private void OnListKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (Selected is not { } row)
        {
            return;
        }
        if (e.Key == Windows.System.VirtualKey.Enter)
        {
            _ = EditAsync(row.Project);
            e.Handled = true;
        }
        else if (e.Key == Windows.System.VirtualKey.Delete)
        {
            _ = DeleteAsync(row.Project);
            e.Handled = true;
        }
    }

    /// <summary>Each row's own menu acts on that row, as on the Mac; the list's menu is for the empty area.</summary>
    private void OnContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.Item is ProjectRow row)
        {
            args.ItemContainer.ContextFlyout = RowMenu(row.Project);
        }
    }

    private MenuFlyout RowMenu(Project project)
    {
        var menu = new MenuFlyout();
        menu.Items.Add(Item(L("Изменить…"), () => _ = EditAsync(project)));
        menu.Items.Add(Item(L("Показать в проводнике"), () => Show(Path.Combine(_profiles, project.Slug + ".json"))));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item(L("Удалить…"), () => _ = DeleteAsync(project)));
        return menu;
    }

    private MenuFlyout ListMenu()
    {
        var menu = new MenuFlyout();
        menu.Items.Add(Item(L("Новый проект…"), () => _ = EditAsync(new Project("", ""))));
        menu.Items.Add(Item(L("Показать в проводнике"), () => Show(_profiles)));
        return menu;
    }

    private static MenuFlyoutItem Item(string text, Action action)
    {
        var item = new MenuFlyoutItem { Text = text };
        item.Click += (_, _) => action();
        return item;
    }

    /// <summary>The folder in File Explorer, or the folder with the file selected.</summary>
    private static void Show(string path)
    {
        if (File.Exists(path))
        {
            Process.Start("explorer.exe", $"/select,\"{path}\"");
            return;
        }
        Directory.CreateDirectory(path);
        Process.Start("explorer.exe", $"\"{path}\"");
    }

    /// <summary>Changes made elsewhere (the engine, the call form, an editor) show up by themselves.</summary>
    private void StartWatching()
    {
        if (_watcher is not null)
        {
            return;
        }
        try
        {
            Directory.CreateDirectory(_profiles);
            _watcher = new FileSystemWatcher(_profiles, "*.json") { EnableRaisingEvents = true };
            _watcher.Created += OnFolderChanged;
            _watcher.Changed += OnFolderChanged;
            _watcher.Deleted += OnFolderChanged;
            _watcher.Renamed += OnFolderChanged;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        {
            AppHost.Log(e);
        }
    }

    private void StopWatching()
    {
        _watcher?.Dispose();
        _watcher = null;
    }

    private void OnFolderChanged(object sender, FileSystemEventArgs e) => DispatcherQueue.TryEnqueue(async () =>
    {
        if (_reloadQueued)
        {
            return;
        }
        _reloadQueued = true;
        await Task.Delay(300);
        _reloadQueued = false;
        var fresh = Project.All(_profiles);
        if (fresh.Count != _projects.Count || fresh.Zip(_projects).Any(pair => !pair.First.SameAs(pair.Second)))
        {
            Reload();
        }
    });
}
