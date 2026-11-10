using System.IO;
using Sozvon.App.Recording;
using Sozvon.App.Settings;
using Sozvon.App.Strings;
using Sozvon.Core.Calls;
using Sozvon.Core.Engine;

namespace Sozvon.App.Calls;

/// <summary>
/// What the card does to a call: transcript edits, the queue, the Recycle Bin. Every change ends in
/// <see cref="Changed"/>, and the list and the card read the call again.
/// </summary>
public sealed class CallActions(string dataDir, EngineSettings engine, Func<RecordingController?> recording)
{
    /// <summary>A call changed on disk; the id of the call to select afterwards, or null to keep the selection.</summary>
    public event Action<string?>? Changed;

    public bool CanTranscribe => recording() is not null;

    /// <summary>Being recorded, transcribed or waiting for it: not deleted, transcribed again or edited.</summary>
    public bool IsBusy(CallRecord call)
    {
        if (call.IsDemo || call.Folder.Length == 0)
        {
            return false;
        }
        var controller = recording();
        return call.IsQueued
            || controller?.Processor.Contains(call.Folder) == true
            || (controller?.RecordingDirectory is { } dir && SameFolder(dir, call.Folder));
    }

    /// <summary>Busy here, or call.json says processing (a run Sozvon didn't start): the engine would overwrite an edit.</summary>
    public bool IsEditLocked(CallRecord call) => call.IsDemo || IsBusy(call) || call.Status == CallStatus.Processing;

    /// <summary>The engine is transcribing this call right now.</summary>
    public bool IsTranscribing(CallRecord call) =>
        call.Status == CallStatus.Processing
        || (recording()?.Processor.Running is { Kind: ProcessingKind.Transcribe } job && SameFolder(job.Dir, call.Folder));

    /// <summary>Waiting in the engine's queue.</summary>
    public bool IsWaiting(CallRecord call) =>
        call.IsQueued || recording()?.Processor.Waiting.Any(j => SameFolder(j.Dir, call.Folder)) == true;

    /// <summary>The summary is being made again right now.</summary>
    public bool IsSummarizing(CallRecord call) =>
        recording()?.Processor.Running is { Kind: ProcessingKind.SummaryOnly } job && SameFolder(job.Dir, call.Folder);

    public string? RenameSpeaker(CallRecord call, string from, string to) => Edit(call, () => TranscriptEdit.RenameSpeaker(call.Folder, from, to),
        notFound: Loc.L("Говорящий «%@» не найден в расшифровке", from));

    public string? SwapSpeakers(CallRecord call, string a, string b) => Edit(call, () => TranscriptEdit.SwapSpeakers(call.Folder, a, b),
        notFound: Loc.L("Говорящий «%@» не найден в расшифровке", a));

    public string? ReassignLine(CallRecord call, TranscriptRow row, string to) => Edit(call, () => TranscriptEdit.ReassignLine(call.Folder, row.Line, row.Occurrence, to),
        notFound: Loc.L("Расшифровка изменилась, открой звонок заново"));

    public string? FixWord(CallRecord call, TranscriptRow row, string wrong, string right) => Edit(call, () => TranscriptEdit.FixWord(call.Folder, row.Line, row.Occurrence, wrong, right),
        notFound: Loc.L("Расшифровка изменилась, открой звонок заново"));

    /// <summary>The fix becomes an auto-replacement for the call's project, or for all calls without one.</summary>
    public string? Remember(string wrong, string right, Project? project)
    {
        try
        {
            ReplacementStore.Add(wrong, right, project?.Slug ?? "", dataDir);
            return null;
        }
        catch (Exception e) when (e is ReplacementException or IOException or UnauthorizedAccessException)
        {
            return Loc.L("Не получилось запомнить замену: %@", e.Message);
        }
    }

    /// <summary>The call's project, when this computer has it.</summary>
    public Project? ProjectOf(CallRecord call) =>
        call.ProjectSlug.Length == 0 ? null : Project.All(Path.Combine(dataDir, "profiles")).FirstOrDefault(p => p.Slug == call.ProjectSlug);

    /// <summary>"Transcribe again…": the form with the call's answers, then the queue.</summary>
    public void Retranscribe(CallRecord call)
    {
        if (!IsBusy(call) && recording() is { } controller)
        {
            controller.Retranscribe(call.Folder);
        }
    }

    /// <summary>"Update summary": the engine writes a new summary from the transcript as it is now.</summary>
    public void Resummarize(CallRecord call)
    {
        if (!IsEditLocked(call) && recording() is { } controller && controller.Resummarize(call.Folder))
        {
            Changed?.Invoke(null);
        }
    }

    /// <summary>"Remove from queue": back to how it was before.</summary>
    public void RemoveFromQueue(CallRecord call)
    {
        if (recording()?.Processor.RemoveFromQueue(call.Folder) == true)
        {
            Changed?.Invoke(null);
        }
    }

    /// <summary>Moves the call's folder to the Recycle Bin, as on the Mac without asking. The reason it didn't, or null.</summary>
    public string? Trash(CallRecord call, string? selectNext)
    {
        if (call.IsDemo || call.Folder.Length == 0)
        {
            return null;
        }
        if (IsBusy(call))
        {
            return Loc.L("Звонок сейчас записывается или расшифровывается");
        }
        try
        {
            RecycleBin.Move(call.Folder);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return Loc.L("Не получилось удалить звонок") + ": " + e.Message;
        }
        Changed?.Invoke(selectNext);
        return null;
    }

    private string? Edit(CallRecord call, Action edit, string notFound)
    {
        if (IsEditLocked(call))
        {
            return Loc.L("Звонок сейчас записывается или расшифровывается");
        }
        try
        {
            edit();
        }
        catch (TranscriptEditException e)
        {
            return e.Failure == TranscriptEditFailure.BadName
                ? Loc.L("Имя не может быть пустым или содержать «:», «*», «[» и «]»")
                : notFound;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return Loc.L("Не получилось сохранить расшифровку: %@", e.Message);
        }
        Edited(call);
        return null;
    }

    /// <summary>call.json participants follow the edited transcript; names stay as typed. Best effort.</summary>
    private void Edited(CallRecord call)
    {
        try
        {
            CallParticipants.Update(call.Folder, engine.Name);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Shell.AppHost.Log(e);
        }
        Changed?.Invoke(null);
    }

    internal static bool SameFolder(string a, string b) =>
        string.Equals(Path.TrimEndingDirectorySeparator(Path.GetFullPath(a)), Path.TrimEndingDirectorySeparator(Path.GetFullPath(b)),
                      StringComparison.OrdinalIgnoreCase);
}
