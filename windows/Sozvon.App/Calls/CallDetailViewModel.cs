using System.Collections.ObjectModel;
using System.IO;
using CommunityToolkit.Mvvm.ComponentModel;
using Sozvon.App.Strings;
using Sozvon.Core.Calls;

namespace Sozvon.App.Calls;

public enum CallBannerKind { None, Informational, Critical, Caution }

/// <summary>A note as the card lists it.</summary>
public sealed record NoteRow(CallNote Note, string Stamp)
{
    public string Text => Note.Text;
}

/// <summary>A participant: a green check when their voice is saved, coral while it is not and they speak.</summary>
public sealed record ParticipantChip(string Name, bool Saved, bool Unconfirmed, string Hint);

/// <summary>An opened call: header, status, the summary feed, the transcript and the player.</summary>
public sealed partial class CallDetailViewModel : ObservableObject, IDisposable
{
    public CallDetailViewModel(CallRecord call, CallContent content, string myName, IReadOnlyCollection<VoiceRecord> voices, CallActions actions)
    {
        Call = call;
        Actions = actions;
        Me = myName.Trim();
        Transcript = content.Transcript;
        Summary = content.Summary;
        Meta = CallFormat.Meta(call);
        Blocks = SummaryParser.Parse(content.Summary);
        var me = myName.Trim();
        var speakers = Core.Calls.Transcript.Lines(content.Transcript).Select(l => l.Speaker).ToList();
        Unsaved = Voices.Unsaved(speakers, call.ProjectSlug, voices, me);
        Rows = TranscriptRow.Parse(content.Transcript, Unsaved, me);
        Participants = Chips(call, speakers, me, voices, Unsaved);
        Notes = new ObservableCollection<NoteRow>(call.Notes.Select(Row));
        Player = new CallPlayer(call);
        foreach (var row in Rows)
        {
            row.CanPlay = Player.IsAvailable;
            row.CanEdit = !actions.IsEditLocked(call);
        }
        (BannerKind, BannerText) = Banner(call);
        TranscriptPath = Path.Combine(call.Folder, "transcript.md");
        LogPath = Path.Combine(call.Folder, "process.log");
        DiskSize = call.IsDemo ? "" : Loc.L("На диске: %@", FormatSize(FolderBytes(call.Folder)));
    }

    public CallRecord Call { get; }
    public CallActions Actions { get; }

    /// <summary>The user's name as the transcript writes it.</summary>
    public string Me { get; }
    public string Transcript { get; }
    public string Summary { get; }
    public string Meta { get; }
    public string Title => Call.Title;
    public IReadOnlyList<ParticipantChip> Participants { get; }

    /// <summary>Named speakers whose voice is not saved yet.</summary>
    public IReadOnlyList<string> Unsaved { get; }
    public IReadOnlyList<SummaryBlock> Blocks { get; }
    public IReadOnlyList<TranscriptRow> Rows { get; }

    /// <summary>Paragraph start times, for the line being played.</summary>
    public IReadOnlyList<double> Starts => _starts ??= Rows.Select(r => r.Line.Start).ToList();

    private List<double>? _starts;
    public ObservableCollection<NoteRow> Notes { get; }

    /// <summary>Notes live in call.json: not on the demo call, an old call without call.json or an unreadable one.</summary>
    public bool CanEditNotes => CanOpenFolder && !Call.IsUnreadable && File.Exists(Path.Combine(Call.Folder, CallFile.Name));
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

    /// <summary>Adds a note to call.json. The reason it was not saved, or null.</summary>
    public string? AddNote(string text, string source = "app", DateTimeOffset? at = null)
    {
        try
        {
            // Oldest first, as call.json lists them: a note put back keeps its place.
            var row = Row(CallNotes.Add(text, Call.Folder, source, at));
            Notes.Insert(Notes.Count(n => string.CompareOrdinal(n.Note.At, row.Note.At) <= 0), row);
            return null;
        }
        catch (CallNoteException e)
        {
            return e.Failure switch
            {
                CallNoteFailure.Empty => null,
                CallNoteFailure.TooLong => Loc.L("Заметка длиннее %@ символов", CallNotes.MaxText),
                CallNoteFailure.TooMany => Loc.L("У звонка уже %@ заметок, больше нельзя", CallNotes.MaxNotes),
                _ => Loc.L("Не получилось сохранить заметку: call.json повреждён"),
            };
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return Loc.L("Не получилось сохранить заметку: call.json повреждён");
        }
    }

    /// <summary>Deletes a note; its id stays as a tombstone in call.json. Whether it was deleted.</summary>
    public bool DeleteNote(NoteRow row)
    {
        try
        {
            CallNotes.Delete(row.Note.Id, Call.Folder);
        }
        catch (Exception e) when (e is CallNoteException or IOException or UnauthorizedAccessException)
        {
            return false;
        }
        Notes.Remove(row);
        return true;
    }

    private static NoteRow Row(CallNote note) => new(note, Stamp(note));

    /// <summary>"8 ноября в 16:02", and where the note came from when not typed here ("claude-code").</summary>
    private static string Stamp(CallNote note)
    {
        var when = note.Date is { } date ? CallFormat.DateAndTime(date) : note.At;
        return note.Source is "" or "app" ? when : when + " · " + note.Source;
    }

    /// <summary>
    /// Everyone on the call: the user first when they speak (or there is no transcript yet), then call.json
    /// <c>participants</c>, or for an older call the names derived from the transcript, never written on open.
    /// </summary>
    private static List<ParticipantChip> Chips(CallRecord call, List<string> speakers, string me,
                                               IReadOnlyCollection<VoiceRecord> voices, IReadOnlyList<string> unsaved)
    {
        var others = call.HasParticipants || speakers.Count == 0
            ? call.People.ToList()
            : CallParticipants.Derived(call.People, speakers, me);
        bool IsMe(string n) => me.Length > 0 && n.Equals(me, StringComparison.OrdinalIgnoreCase);
        var speaks = speakers.Count == 0 || speakers.Any(IsMe);
        var names = (me.Length > 0 && speaks && !others.Any(IsMe) ? [me] : new List<string>()).Concat(others);
        var myVoice = Voices.Me(voices) is not null;
        return names.Select(n =>
        {
            var mine = IsMe(n);
            var saved = mine ? myVoice : voices.Any(v => !v.Me && (v.Profile == call.ProjectSlug || v.Profile.Length == 0)
                                                         && Voices.SameName(v.Name, n));
            var hint = mine
                ? Loc.L(saved ? "Твой голос сохранён" : "Твой голос не записан: запиши его в Настройках")
                : Loc.L(saved ? "Голос сохранён: Sozvon узнаёт этого человека в следующих звонках" : "Голос не сохранён");
            return new ParticipantChip(n, saved, !mine && unsaved.Contains(n), hint);
        }).ToList();
    }

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
