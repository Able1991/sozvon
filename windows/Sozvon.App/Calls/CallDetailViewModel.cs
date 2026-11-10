using System.IO;
using CommunityToolkit.Mvvm.ComponentModel;
using Sozvon.App.Strings;
using Sozvon.Core.Calls;

namespace Sozvon.App.Calls;

public enum CallBannerKind { None, Informational, Critical, Caution }

public sealed record NoteRow(string Text, string Stamp);

/// <summary>An opened call: header, status, the summary feed, the transcript and the player.</summary>
public sealed partial class CallDetailViewModel : ObservableObject, IDisposable
{
    public CallDetailViewModel(CallRecord call, CallContent content, string myName, IReadOnlyCollection<VoiceRecord> voices)
    {
        Call = call;
        Transcript = content.Transcript;
        Summary = content.Summary;
        Meta = CallFormat.Meta(call);
        Blocks = SummaryParser.Parse(content.Summary);
        var me = myName.Trim();
        var speakers = Core.Calls.Transcript.Lines(content.Transcript).Select(l => l.Speaker);
        Rows = TranscriptRow.Parse(content.Transcript, Voices.Unsaved(speakers, call.ProjectSlug, voices, me), me);
        Notes = call.Notes.Select(n => new NoteRow(n.Text, Stamp(n))).ToList();
        Player = new CallPlayer(call);
        (BannerKind, BannerText) = Banner(call);
        TranscriptPath = Path.Combine(call.Folder, "transcript.md");
        LogPath = Path.Combine(call.Folder, "process.log");
        DiskSize = call.IsDemo ? "" : Loc.L("На диске: %@", FormatSize(FolderBytes(call.Folder)));
    }

    public CallRecord Call { get; }
    public string Transcript { get; }
    public string Summary { get; }
    public string Meta { get; }
    public string Title => Call.Title;
    public string People => string.Join(", ", Call.People);
    public bool HasPeople => Call.People.Count > 0;
    public IReadOnlyList<SummaryBlock> Blocks { get; }
    public IReadOnlyList<TranscriptRow> Rows { get; }
    public IReadOnlyList<NoteRow> Notes { get; }
    public bool HasNotes => Notes.Count > 0;
    public bool HasSummary => Blocks.Count > 0;
    public bool HasTranscript => Rows.Count > 0;
    public CallPlayer Player { get; }
    public CallBannerKind BannerKind { get; }
    public string BannerText { get; }
    public string TranscriptPath { get; }
    public string LogPath { get; }
    public string DiskSize { get; }
    public bool CanOpenFolder => !Call.IsDemo && Call.Folder.Length > 0;
    public bool HasLog => CanOpenFolder && File.Exists(LogPath);
    public bool HasTranscriptFile => CanOpenFolder && File.Exists(TranscriptPath);

    public void Dispose() => Player.Dispose();

    private static string Stamp(CallNote note) =>
        string.Join(" · ", new[] { CallFormat.DateAndTime(note.At), note.Source }.Where(p => p.Length > 0));

    private static (CallBannerKind, string) Banner(CallRecord call) => call switch
    {
        { IsDemo: true } => (CallBannerKind.Informational, Loc.L("Это демо-звонок: настоящих звонков пока нет")),
        { IsUnreadable: true } => (CallBannerKind.Critical, Loc.L("Не удалось прочитать call.json")),
        { Status: CallStatus.Failed } => (CallBannerKind.Critical, Loc.L("Не получилось расшифровать")),
        { Status: CallStatus.Processing } => (CallBannerKind.Informational, Loc.L("Расшифровывается…")),
        { IsQueued: true } => (CallBannerKind.Informational, Loc.L("В очереди")),
        { HasSummaryWarning: true } => (CallBannerKind.Caution, Loc.L("Готово, но саммари не получилось")),
        _ => (CallBannerKind.None, ""),
    };

    private static long FolderBytes(string folder)
    {
        try
        {
            return new DirectoryInfo(folder).EnumerateFiles("*", SearchOption.AllDirectories).Sum(f => f.Length);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return 0;
        }
    }

    private static string FormatSize(long bytes)
    {
        var megabytes = bytes / 1_048_576.0;
        return megabytes >= 1024
            ? (megabytes / 1024).ToString("0.0", Loc.Culture) + (Loc.IsRussian ? " ГБ" : " GB")
            : megabytes.ToString("0", Loc.Culture) + (Loc.IsRussian ? " МБ" : " MB");
    }
}
