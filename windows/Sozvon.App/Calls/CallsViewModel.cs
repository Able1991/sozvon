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
public sealed partial class CallsViewModel(CallRepository repository, AppSettings settings) : ObservableObject, IDisposable
{
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

    partial void OnSelectedProjectChanged(ProjectFilter value) => ApplyFilter();

    partial void OnSearchTextChanged(string value) => ApplyFilter();

    partial void OnSelectedRowChanged(CallRow? value) => Open(value?.Call);

    public async Task RefreshAsync()
    {
        var calls = await Task.Run(repository.Scan);
        IsDemoOnly = calls.Count == 0;
        _calls = IsDemoOnly ? [DemoCall.Create()] : calls;
        RebuildProjects();
        ApplyFilter();
    }

    /// <summary>Selects a call by id, now or as soon as the list has it.</summary>
    public void SelectCall(string id)
    {
        _pendingCallId = id;
        ClearFilters();
        SelectPending();
    }

    public void Dispose() => Detail?.Dispose();

    private void ClearFilters()
    {
        SelectedProject = AllProjects;
        SearchText = "";
    }

    private void RebuildProjects()
    {
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
    }

    private void ApplyFilter()
    {
        var selectedId = _pendingCallId ?? SelectedRow?.Call.Id;
        var rows = _calls.Where(Matches).Select(Row).ToList();
        Groups.Clear();
        foreach (var group in rows.GroupBy(r => CallFormat.DayGroup(r.Call.CreatedAt)))
        {
            Groups.Add(new CallGroup(group.Key, group));
        }
        IsEmpty = rows.Count == 0;
        SelectedRow = rows.FirstOrDefault(r => r.Call.Id == selectedId);
        SelectPending();
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
        var query = SearchText.Trim();
        return query.Length == 0
            || new[] { call.Title, call.ProjectTitle }.Concat(call.People).Any(t => t.Contains(query, StringComparison.CurrentCultureIgnoreCase));
    }

    private static CallRow Row(CallRecord call)
    {
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

    private async void Open(CallRecord? call)
    {
        Detail?.Dispose();
        Detail = null;
        if (call is null)
        {
            return;
        }
        var content = await Task.Run(() => repository.LoadContent(call));
        if (SelectedRow?.Call == call)
        {
            Detail = new CallDetailViewModel(call, content, settings.DisplayName);
        }
    }
}
