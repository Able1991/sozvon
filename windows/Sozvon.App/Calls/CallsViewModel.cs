using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using Sozvon.App.Settings;
using Sozvon.App.Strings;

namespace Sozvon.App.Calls;

/// <summary>One row of the list.</summary>
public sealed record CallRow(CallRecord Call, string Subtitle, string Lead, string Badge, bool IsCritical)
{
    public string Title => Call.Title;
    public string Time => CallFormat.Time(Call.CreatedAt);
    public string ProjectSlug => Call.ProjectSlug;

    /// <summary>The name a screen reader announces for the row.</summary>
    public override string ToString() => $"{Title}, {Time}, {Subtitle}";
}

/// <summary>A day in the list.</summary>
public sealed class CallGroup(string title, IEnumerable<CallRow> rows) : List<CallRow>(rows)
{
    public string Title { get; } = title;

    public override string ToString() => Title;
}

public sealed record ProjectFilter(string Slug, string Title);

/// <summary>The Calls page: the list, its project filter and search, and the opened call.</summary>
public sealed partial class CallsViewModel : ObservableObject, IDisposable
{
    private readonly CallRepository _repository;
    private readonly AppSettings _settings;
    private readonly EngineSettings _engine;

    public CallsViewModel(CallRepository repository, AppSettings settings, EngineSettings engine, CallActions actions)
    {
        _repository = repository;
        _settings = settings;
        _engine = engine;
        Actions = actions;
        actions.Changed += dir =>
        {
            if (dir is not null)
            {
                _pendingCallId = dir;
            }
            _ = RefreshAsync();
        };
    }

    public CallActions Actions { get; }

    public static readonly ProjectFilter AllProjects = new("", Loc.L("Все проекты"));

    private IReadOnlyList<CallRecord> _calls = [];
    private string? _pendingCallId;

    public ObservableCollection<CallGroup> Groups { get; } = [];

    public ObservableCollection<ProjectFilter> Projects { get; } = [AllProjects];

    [ObservableProperty] public partial ProjectFilter SelectedProject { get; set; } = AllProjects;

    [ObservableProperty] public partial string SearchText { get; set; } = "";

    [ObservableProperty] public partial CallRow? SelectedRow { get; set; }

    [ObservableProperty] public partial CallDetailViewModel? Detail { get; private set; }

    /// <summary>True when the list holds only the demo call, because no real call was found.</summary>
    [ObservableProperty] public partial bool IsDemoOnly { get; private set; }

    [ObservableProperty] public partial bool IsEmpty { get; private set; }

    /// <summary>The list is being rebuilt: the selection passes through null and back, which must not close the card.</summary>
    private bool _rebuilding;

    /// <summary>The latest <see cref="Open"/>: an older one still loading gives way to it.</summary>
    private int _opening;

    partial void OnSelectedProjectChanged(ProjectFilter value) => ApplyFilter();

    partial void OnSearchTextChanged(string value) => ApplyFilter();

    partial void OnSelectedRowChanged(CallRow? value)
    {
        if (!_rebuilding)
        {
            Open(value?.Call);
        }
    }

    public async Task RefreshAsync()
    {
        var calls = await Task.Run(_repository.Scan);
        IsDemoOnly = calls.Count == 0;
        _calls = IsDemoOnly ? [DemoCall.Create()] : calls;
        RebuildProjects();
        ApplyFilter(reload: true);
    }

    /// <summary>Selects a call by id, now or as soon as the list has it.</summary>
    public void SelectCall(string id)
    {
        _pendingCallId = id;
        ClearFilters();
        SelectPending();
    }

    public void Dispose() => Detail?.Dispose();

    /// <summary>The opened call to the Recycle Bin; the next one in the list is selected, as in Mail.</summary>
    public async Task<string?> TrashSelectedAsync()
    {
        if (SelectedRow?.Call is not { } call)
        {
            return null;
        }
        var rows = Groups.SelectMany(g => g).ToList();
        var at = rows.FindIndex(r => r.Call.Id == call.Id);
        var next = at + 1 < rows.Count ? rows[at + 1] : at > 0 ? rows[at - 1] : null;
        Detail?.Player.Dispose();
        var error = await Actions.TrashAsync(call, next?.Call.Id);
        if (error is not null)
        {
            _ = RefreshAsync(); // the call is still there: its card, with a new player
        }
        return error;
    }

    /// <summary>Ctrl+Z after a deletion: the call comes back from the Recycle Bin and is selected. The problem, or null.</summary>
    public async Task<string?> UndoTrashAsync()
    {
        var (restoredId, problem) = await Actions.UndoTrashAsync();
        if (restoredId is not null)
        {
            SelectCall(restoredId); // whatever the filter and the search say: it is the call just asked for
        }
        return problem;
    }

    private void ClearFilters()
    {
        SelectedProject = AllProjects;
        SearchText = "";
    }

    /// <summary>
    /// The projects found in the calls. The chosen one stays chosen by its slug, under its new title after a rename;
    /// when no call has it any more, the list shows all projects.
    /// </summary>
    private void RebuildProjects()
    {
        var chosen = SelectedProject.Slug;
        var known = _calls
            .Where(c => c.ProjectSlug.Length > 0)
            .GroupBy(c => c.ProjectSlug)
            .Select(g => new ProjectFilter(g.Key, g.First().ProjectTitle))
            .OrderBy(p => p.Title, StringComparer.CurrentCultureIgnoreCase);
        Projects.Clear();
        Projects.Add(AllProjects);
        foreach (var project in known)
        {
            Projects.Add(project);
        }
        SelectedProject = Projects.FirstOrDefault(p => p.Slug == chosen) ?? AllProjects;
    }

    /// <summary>
    /// Rebuilds the list for the filter and the search. The card follows the selection; after a reload from disk the
    /// selected call is read again, in place, so what is playing, the find bar and the note being typed stay.
    /// </summary>
    private void ApplyFilter(bool reload = false)
    {
        var selectedId = _pendingCallId ?? SelectedRow?.Call.Id;
        var rows = _calls.Where(Matches).Select(Row).ToList();
        _rebuilding = true;
        try
        {
            Groups.Clear();
            foreach (var group in rows.GroupBy(r => CallFormat.DayGroup(r.Call.CreatedAt)))
            {
                Groups.Add(new CallGroup(group.Key, group));
            }
            IsEmpty = rows.Count == 0;
            SelectedRow = rows.FirstOrDefault(r => r.Call.Id == selectedId);
            SelectPending();
        }
        finally
        {
            _rebuilding = false;
        }
        var call = SelectedRow?.Call;
        if (reload || call?.Id != Detail?.Call.Id)
        {
            Open(call);
        }
    }

    private void SelectPending()
    {
        if (_pendingCallId is null)
        {
            return;
        }
        var row = Groups.SelectMany(g => g).FirstOrDefault(r => r.Call.Id == _pendingCallId);
        if (row is not null)
        {
            SelectedRow = row;
            _pendingCallId = null;
        }
    }

    private bool Matches(CallRecord call)
    {
        if (SelectedProject.Slug.Length > 0 && call.ProjectSlug != SelectedProject.Slug)
        {
            return false;
        }
        return Sozvon.Core.Calls.CallSearch.Matches(SearchText, new[] { call.Title, call.ProjectTitle }.Concat(call.People));
    }

    private CallRow Row(CallRecord call)
    {
        // As the Mac's list: the call being recorded has no call.json yet, so nothing else would say what it is.
        if (Actions.IsRecording(call))
        {
            return new CallRow(call, Loc.L("Идёт запись"), "", "", true);
        }
        var description = string.Join(" · ", new[]
        {
            call.ProjectTitle,
            string.Join(", ", call.People.Take(2)),
            call.DurationSeconds > 0 ? CallFormat.Duration(call.DurationSeconds) : "",
        }.Where(p => p.Length > 0));
        return call switch
        {
            { IsUnreadable: true } => new CallRow(call, Loc.L("Не удалось прочитать call.json"), "", "", true),
            { IsWaitingForDescription: true } => new CallRow(call, description, Loc.L("Ждёт описания"), "", false),
            { Status: CallStatus.Processing } => new CallRow(call, Loc.L("Расшифровывается…"), "", "", false),
            { Status: CallStatus.Failed } => new CallRow(call, Loc.L("Не получилось расшифровать"), "", "", true),
            { IsQueued: true } => new CallRow(call, Loc.L("В очереди"), "", "", false),
            { Status: CallStatus.Recorded } => new CallRow(call, Loc.L("Без расшифровки"), "", "", false),
            { IsDemo: true } => new CallRow(call, description, "", Loc.L("Демо"), false),
            { HasSummaryWarning: true } => new CallRow(call, description, "", Loc.L("Без саммари"), false),
            _ => new CallRow(call, description, "", "", false),
        };
    }

    /// <summary>
    /// Opens the call in the card. The same call read again (a refresh, an edit) replaces the card only once its new
    /// content is loaded, and keeps the player when its audio is still free to play.
    /// </summary>
    private async void Open(CallRecord? call)
    {
        var previous = Detail;
        var same = call is not null && previous is not null && previous.Call.Id == call.Id
                   && string.Equals(previous.Call.Folder, call.Folder, StringComparison.OrdinalIgnoreCase);
        if (!same)
        {
            previous?.Dispose();
            Detail = null;
        }
        var opening = ++_opening;
        if (call is null)
        {
            return;
        }
        var (content, voices) = await Task.Run(() => (_repository.LoadContent(call), _repository.Voices()));
        if (opening != _opening || SelectedRow?.Call != call)
        {
            return;
        }
        var shown = Detail;
        Detail = new CallDetailViewModel(call, content, _engine.Name, voices, Actions, previous: same ? shown : null);
        shown?.Dispose();
    }
}
