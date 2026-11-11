using System.Collections.ObjectModel;
using System.IO;
using CommunityToolkit.Mvvm.ComponentModel;
using Sozvon.App.Strings;
using Sozvon.Core.Calls;

namespace Sozvon.App.Calls;

public enum CallBannerKind { None, Informational, Critical, Caution }

/// <summary>The button of the status banner.</summary>
public enum CallBannerAction { None, RemoveFromQueue, Retranscribe, Resummarize }

/// <summary>The line under the header: what is happening to the call, and what can be done about it.</summary>
public sealed record CallBanner(CallBannerKind Kind, string Title, string Message = "", CallBannerAction Action = CallBannerAction.None, bool Progress = false);

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
    /// <param name="previous">The same call as the card showed it before this reading; its player goes on when it can.</param>
    public CallDetailViewModel(CallRecord call, CallContent content, string myName, IReadOnlyCollection<VoiceRecord> voices, CallActions actions,
                               CallDetailViewModel? previous = null)
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
        VoiceRecords = voices;
        Rows = TranscriptRow.Parse(content.Transcript, Unsaved, me);
        Participants = Chips(call, speakers, me, voices, Unsaved);
        Notes = new ObservableCollection<NoteRow>(call.Notes.Select(Row));
        // An open file would keep the engine from renaming the folder when it finishes.
        var busy = actions.IsBusy(call) || actions.IsTranscribing(call);
        Player = previous?.HandOverPlayer(call, busy) ?? new CallPlayer(call, busy);
        foreach (var row in Rows)
        {
            row.CanPlay = Player.IsAvailable;
            row.CanEdit = !actions.IsEditLocked(call);
            row.HasAudio = call.HasAudio;
        }
        Banner = MakeBanner(call, actions, Rows.Count > 0, Blocks.Count > 0);
        TranscriptPath = Path.Combine(call.Folder, "transcript.md");
        LogPath = Path.Combine(call.Folder, "process.log");
        DiskSize = call.IsDemo ? "" : Loc.L("На диске: %@", CallFormat.Size(FolderBytes(call.Folder)));
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

    public IReadOnlyCollection<VoiceRecord> VoiceRecords { get; }

    /// <summary>"Names right?": the call has audio, a transcript that can be edited, and speakers to remember.</summary>
    public bool OffersVoices => Call.HasAudio && HasTranscript && Unsaved.Count > 0 && !Actions.IsEditLocked(Call)
                                && !Actions.VoicesDismissed.Contains(Call.Id);

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
    public CallBanner Banner { get; }

    /// <summary>The More menu: Transcribe again, Describe or Transcribe, as the call's state says; empty when not offered.</summary>
    public string TranscribeTitle =>
        !Call.HasAudio || Call.IsDemo || !Actions.CanTranscribe || Actions.IsBusy(Call) ? ""
        : Call.IsWaitingForDescription ? Loc.L("Описать…")
        : HasTranscript ? Loc.L("Расшифровать заново…") : Loc.L("Расшифровать…");

    public bool CanResummarize => HasTranscript && Actions.CanTranscribe && !Actions.IsEditLocked(Call) && !Actions.IsSummarizing(Call);

    public bool CanRemoveFromQueue => Actions.IsWaiting(Call);
    public string TranscriptPath { get; }
    public string LogPath { get; }
    public string DiskSize { get; }
    public bool CanOpenFolder => !Call.IsDemo && Call.Folder.Length > 0;
    public bool HasLog => CanOpenFolder && File.Exists(LogPath);
    public bool HasTranscriptFile => CanOpenFolder && File.Exists(TranscriptPath);

    private bool _playerHandedOver;

    /// <summary>Lets the audio go, unless the player went on to the next reading of this call.</summary>
    public void Dispose()
    {
        if (!_playerHandedOver)
        {
            Player.Dispose();
        }
    }

    /// <summary>
    /// The player, for the same call read again: it keeps playing where it was. Not when the engine now works on the
    /// call (the files must be let go) or the audio changed.
    /// </summary>
    private CallPlayer? HandOverPlayer(CallRecord next, bool busy)
    {
        if (busy || Player.IsDisposed || !Player.IsAvailable || next.AudioRemoved != Call.AudioRemoved || next.HasAudio != Call.HasAudio)
        {
            return null;
        }
        _playerHandedOver = true;
        return Player;
    }

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

    /// <summary>The Mac's status banners, then the Windows ones for a failed or summary-less run.</summary>
    private static CallBanner MakeBanner(CallRecord call, CallActions actions, bool hasTranscript, bool hasSummary)
    {
        if (call.IsDemo)
        {
            return new(CallBannerKind.Informational, Loc.L("Это демо-звонок: настоящих звонков пока нет"));
        }
        if (call.IsUnreadable)
        {
            return new(CallBannerKind.Critical, Loc.L("Не удалось прочитать call.json"));
        }
        if (actions.IsTranscribing(call))
        {
            return new(CallBannerKind.Informational, Loc.L(hasTranscript ? "Расшифровываю заново…" : "Расшифровывается…"), Progress: true);
        }
        if (actions.IsSummarizing(call))
        {
            return new(CallBannerKind.Informational, Loc.L("Обновляю саммари…"), Progress: true);
        }
        if (actions.IsWaiting(call))
        {
            return new(CallBannerKind.Informational, Loc.L("В очереди."), Loc.L("Начнётся, когда освободится движок и закончится звонок."),
                       CallBannerAction.RemoveFromQueue);
        }
        var canTranscribe = call.HasAudio && actions.CanTranscribe && !actions.IsBusy(call);
        if (call.Status == CallStatus.Failed)
        {
            // The last run failed; a transcript on screen is from the run before it.
            return new(CallBannerKind.Critical, Loc.L(hasTranscript ? "Не получилось расшифровать." : "Не получилось расшифровать"),
                       hasTranscript ? Loc.L("Здесь расшифровка с прошлого раза.") : "",
                       canTranscribe ? CallBannerAction.Retranscribe : CallBannerAction.None);
        }
        if (hasSummary && SummaryStale(call.Folder) && !actions.IsEditLocked(call))
        {
            // The transcript was edited after the summary was written (names fixed, lines moved).
            return new(CallBannerKind.Caution, Loc.L("Саммари устарело."), Loc.L("Расшифровку изменили после того, как оно было написано."),
                       actions.CanTranscribe ? CallBannerAction.Resummarize : CallBannerAction.None);
        }
        if (call.HasSummaryWarning)
        {
            // The Mac's notification for this carries the Update Summary button; the banner offers the same.
            return new(CallBannerKind.Caution, Loc.L("Готово, но саммари не получилось"), "",
                       hasTranscript && actions.CanTranscribe && !actions.IsEditLocked(call) ? CallBannerAction.Resummarize : CallBannerAction.None);
        }
        return new(CallBannerKind.None, "");
    }

    /// <summary>transcript.txt is newer than summary.md: the transcript was edited after the summary.</summary>
    private static bool SummaryStale(string folder)
    {
        var transcript = new FileInfo(Path.Combine(folder, "transcript.txt"));
        var summary = new FileInfo(Path.Combine(folder, "summary.md"));
        return transcript.Exists && summary.Exists && (transcript.LastWriteTimeUtc - summary.LastWriteTimeUtc).TotalSeconds > 2;
    }

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
}
