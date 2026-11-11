using System.Collections.ObjectModel;
using System.Globalization;
using System.IO;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Sozvon.App.Shell;
using Sozvon.Core.Calls;
using static Sozvon.App.Strings.Loc;

namespace Sozvon.App.VoicePrints;

/// <summary>A saved voice: whose, then project, seconds of speech and date.</summary>
public sealed class VoiceRow(VoiceRecord record, string title, string details, bool canDelete)
{
    public VoiceRecord Record { get; } = record;

    public string Title { get; } = title;

    public string Details { get; } = details;

    /// <summary>False while a voice.py run goes on; the rows are made again when it ends.</summary>
    public bool CanDelete { get; } = canDelete;

    /// <summary>The user's own voice gets the accent person icon, the others the people icon.</summary>
    public Visibility MeIcon => Record.Me ? Visibility.Visible : Visibility.Collapsed;

    public Visibility OtherIcon => Record.Me ? Visibility.Collapsed : Visibility.Visible;

    public string DeleteLabel => L("Удалить голос «%@»", Record.Name);

    public override string ToString() => $"{Title}, {Details}";
}

/// <summary>
/// Voices, the Mac's Settings section and "Saved voices" sheet as one page: the own sample (record, add a language,
/// record again), every saved voice print with its delete, and Delete all. The engine owns the records: there is no
/// rename, a voice gets its name from the transcript.
/// </summary>
public sealed partial class VoicesPage : UserControl
{
    private readonly MyVoice _myVoice;
    private readonly string _profiles;

    public VoicesPage(MyVoice myVoice, string profilesFolder)
    {
        _myVoice = myVoice;
        _profiles = profilesFolder;
        InitializeComponent();
        // The items mark Enter handled before the list sees it.
        VoiceList.AddHandler(KeyDownEvent, new KeyEventHandler(OnListKeyDown), handledEventsToo: true);
        myVoice.Attach(MyVoiceRow);
        Loaded += (_, _) =>
        {
            Store.Changed += OnStoreChanged;
            Store.Refresh();
            Show();
        };
        Unloaded += (_, _) => Store.Changed -= OnStoreChanged;
    }

    public ObservableCollection<VoiceRow> Rows { get; } = [];

    private VoiceStore Store => _myVoice.Store;

    private void OnStoreChanged(object? sender, EventArgs e) => Show();

    private void Show()
    {
        var titles = Project.Titles(Project.All(_profiles));
        string ProjectTitle(VoiceRecord r) => r.Profile.Length == 0 ? L("Без проекта") : titles.GetValueOrDefault(r.Profile, r.Profile);
        var selected = (VoiceList.SelectedItem as VoiceRow)?.Record.Id;
        Rows.Clear();
        foreach (var record in Sozvon.Core.Calls.Voices.ListOrder(Store.Records, ProjectTitle))
        {
            var details = new[] { record.Me ? "" : ProjectTitle(record), L("%@ с речи", (int)Math.Round(record.Seconds)), Date(record) };
            Rows.Add(new VoiceRow(record, record.Me ? L("%@ (мой голос)", record.Name) : record.Name,
                string.Join(" · ", details.Where(d => d.Length > 0)), !Store.IsBusy));
        }
        VoiceList.SelectedItem = Rows.FirstOrDefault(r => r.Record.Id == selected);
        VoiceList.Visibility = Rows.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        EmptyState.Visibility = Store.Records.Any(r => !r.Me) ? Visibility.Collapsed : Visibility.Visible;
        DeleteAllButton.IsEnabled = Rows.Count > 0 && !Store.IsBusy;
        Busy.IsActive = Store.IsBusy;
    }

    private static string Date(VoiceRecord record) =>
        DateTimeOffset.TryParse(record.UpdatedAt, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var at)
            ? at.ToLocalTime().ToString(IsRussian ? "d MMM yyyy" : "MMM d, yyyy", Culture)
            : "";

    private static string DeleteText(VoiceRecord record) => record.Me
        ? L("Sozvon перестанет узнавать тебя по голосу. Свой голос можно записать заново.")
        : L("Sozvon перестанет узнавать этого человека по голосу. Голос снова сохранится, когда ты подпишешь его в расшифровке.");

    /// <summary>
    /// Each row's trash button asks in a flyout, so the list stays where it is. The question is made on the click from
    /// the row the button shows now: the list reuses its row containers when the rows are made again.
    /// </summary>
    private void OnDeleteButtonClick(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: VoiceRow row } button && !Store.IsBusy)
        {
            Dialogs.ConfirmFlyout(L("Удалить голос «%@»?", row.Record.Name), DeleteText(row.Record), L("Удалить"),
                () => _ = DeleteAsync(row.Record)).ShowAt(button);
        }
    }

    private void OnContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.Item is VoiceRow row)
        {
            var item = new MenuFlyoutItem { Text = L("Удалить…"), IsEnabled = !Store.IsBusy };
            item.Click += async (_, _) => await ConfirmDeleteAsync(row.Record);
            args.ItemContainer.ContextFlyout = new MenuFlyout { Items = { item } };
        }
    }

    private async void OnListKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Delete && VoiceList.SelectedItem is VoiceRow row && !Store.IsBusy)
        {
            e.Handled = true;
            await ConfirmDeleteAsync(row.Record);
        }
    }

    private async Task ConfirmDeleteAsync(VoiceRecord record)
    {
        if (await Dialogs.ConfirmAsync(XamlRoot, L("Удалить голос «%@»?", record.Name), DeleteText(record), L("Удалить")))
        {
            await DeleteAsync(record);
        }
    }

    private async Task DeleteAsync(VoiceRecord record)
    {
        var outcome = await Store.DeleteAsync(record);
        ShowProblem(outcome.IsOk ? null : outcome.Message.Length > 0 ? outcome.Message : L("Не получилось удалить голос"));
    }

    private async void OnDeleteAll(object sender, RoutedEventArgs e)
    {
        var sure = await Dialogs.ConfirmAsync(XamlRoot, L("Удалить все сохранённые голоса?"),
            L("Sozvon перестанет узнавать собеседников и тебя по голосу. Свой голос можно будет записать заново."), L("Удалить"));
        if (sure)
        {
            var outcome = await Store.DeleteAllAsync();
            ShowProblem(outcome.IsOk ? null : outcome.Message.Length > 0 ? outcome.Message : L("Не получилось удалить голоса"));
        }
    }

    private void ShowProblem(string? text)
    {
        Problem.Title = text ?? "";
        Problem.IsOpen = text is not null;
    }
}
