using System.IO;
using Microsoft.UI.Dispatching;
using Sozvon.App.Strings;
using Sozvon.Core.Calls;
using Sozvon.Core.Engine;

namespace Sozvon.App.VoicePrints;

/// <summary>
/// The saved voice prints and the engine's bin\voice.py, one run at a time, as the Mac's VoiceStore: learning a named
/// speaker's voice from a call, the user's own sample, deleting. The engine owns the records; the app reads them
/// again after every run and when the folder changes.
/// </summary>
public sealed class VoiceStore : IDisposable
{
    private readonly DispatcherQueue _ui = DispatcherQueue.GetForCurrentThread();
    private readonly SemaphoreSlim _one = new(1, 1);
    private readonly EngineLayout _layout;
    private readonly Func<EngineOptions> _options;
    private readonly FileSystemWatcher? _watcher;
    private int _waiting;
    private bool _refreshQueued;

    public VoiceStore(EngineLayout layout, Func<EngineOptions> options)
    {
        _layout = layout;
        _options = options;
        Records = Sozvon.Core.Calls.Voices.All(layout.Voices);
        try
        {
            Directory.CreateDirectory(layout.Voices);
            _watcher = new FileSystemWatcher(layout.Voices, "*.json") { EnableRaisingEvents = true };
            _watcher.Created += OnFolderChanged;
            _watcher.Changed += OnFolderChanged;
            _watcher.Deleted += OnFolderChanged;
            _watcher.Renamed += OnFolderChanged;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        {
            // Without a watcher the records are still read after every run and when a page opens.
            Shell.AppHost.Log(e);
        }
    }

    /// <summary>A run started or ended, the records changed, or a notice came. Always on the UI thread.</summary>
    public event EventHandler? Changed;

    /// <summary>Every readable record, sorted by name.</summary>
    public IReadOnlyList<VoiceRecord> Records { get; private set; }

    /// <summary>The user's own sample, if recorded.</summary>
    public VoiceRecord? Me => Sozvon.Core.Calls.Voices.Me(Records);

    /// <summary>A voice.py run is going on or waiting.</summary>
    public bool IsBusy => _waiting > 0;

    /// <summary>What the last "remember voice" did, for a few seconds; null when there is nothing to say.</summary>
    public (bool Ok, string Text)? Notice { get; private set; }

    /// <summary>Reads the records again; on the UI thread.</summary>
    public void Refresh()
    {
        var fresh = Sozvon.Core.Calls.Voices.All(_layout.Voices);
        if (!fresh.SequenceEqual(Records))
        {
            Records = fresh;
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    /// <summary>Learns each named speaker's voice from the call; generic labels and the user are skipped.</summary>
    public async Task EnrollAsync(IEnumerable<string> names, string profile, string dir, string me)
    {
        var own = Records.Where(r => r.Me).Select(r => r.Name).ToList();
        foreach (var name in Sozvon.Core.Calls.Voices.NamesToEnroll(names, me, own))
        {
            var outcome = await RunAsync(Sozvon.Core.Calls.Voices.EnrollCall(name, profile, dir, name));
            Show(outcome.IsOk, outcome.IsOk
                ? Loc.L("Голос «%@» сохранён", name)
                : Loc.L("Голос «%@» не сохранён: %@", name, outcome.Message.Length > 0 ? outcome.Message : Loc.L("подробности в voice.log")));
        }
    }

    /// <summary>
    /// The own sample: a new recording replaces the voice print (older own records are dropped), <paramref name="add"/>
    /// merges one more sample into it (another call language).
    /// </summary>
    public async Task<RunOutcome> EnrollMeAsync(string file, string name, bool add)
    {
        var before = Records.Where(r => r.Me).Select(r => r.Id).ToHashSet();
        var outcome = await RunAsync(Sozvon.Core.Calls.Voices.EnrollFile(name, "", me: true, add, file));
        if (outcome.IsOk && !add)
        {
            foreach (var old in Sozvon.Core.Calls.Voices.Superseded(before, Records))
            {
                await DeleteAsync(old);
            }
        }
        return outcome;
    }

    public Task<RunOutcome> DeleteAsync(VoiceRecord record) => RunAsync(Sozvon.Core.Calls.Voices.Delete(record.Id));

    public Task<RunOutcome> DeleteAllAsync() => RunAsync(Sozvon.Core.Calls.Voices.DeleteAll());

    public void Dispose() => _watcher?.Dispose();

    /// <summary>Runs voice.py after the runs before it; the records are read again when it ends. Called on the UI thread.</summary>
    private async Task<RunOutcome> RunAsync(IReadOnlyList<string> arguments)
    {
        Interlocked.Increment(ref _waiting);
        Changed?.Invoke(this, EventArgs.Empty);
        await _one.WaitAsync();
        try
        {
            if (!_layout.IsInstalled)
            {
                return new RunOutcome.Failed(-1, Loc.L("Движок не установлен"));
            }
            var tracker = new OutputTracker();
            var request = new EngineRunRequest(_layout.Python, [_layout.Script(Sozvon.Core.Calls.Voices.Script), .. arguments],
                EngineEnvironment.Build(_layout, _options()), _layout.Data, Path.Combine(_layout.Data, "voice.log"));
            var process = EngineProcess.Start(request, tracker.Consume);
            var code = await process.Completion;
            return RunOutcome.Parse(code, tracker.Result, tracker.LastLine);
        }
        catch (EngineStartException e)
        {
            return new RunOutcome.Failed(-1, e.Message);
        }
        finally
        {
            _one.Release();
            Interlocked.Decrement(ref _waiting);
            Refresh();
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    /// <summary>The engine wrote or removed a record: read them again once the burst of events is over.</summary>
    private void OnFolderChanged(object sender, FileSystemEventArgs e)
    {
        _ui.TryEnqueue(async () =>
        {
            if (_refreshQueued)
            {
                return;
            }
            _refreshQueued = true;
            await Task.Delay(300);
            _refreshQueued = false;
            Refresh();
        });
    }

    private void Show(bool ok, string text)
    {
        Notice = (ok, text);
        Changed?.Invoke(this, EventArgs.Empty);
        _ui.TryEnqueue(DispatcherQueuePriority.Low, async () =>
        {
            await Task.Delay(TimeSpan.FromSeconds(6));
            if (Notice == (ok, text))
            {
                Notice = null;
                Changed?.Invoke(this, EventArgs.Empty);
            }
        });
    }
}
