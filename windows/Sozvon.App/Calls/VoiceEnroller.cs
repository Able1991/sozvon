using System.IO;
using Microsoft.UI.Dispatching;
using Sozvon.App.Strings;
using Sozvon.Core.Calls;
using Sozvon.Core.Engine;

namespace Sozvon.App.Calls;

/// <summary>
/// "Remember voices": the engine's bin\voice.py learns a named speaker's voice from a call, one run at a time, so the
/// next calls get the name on their own. The result is a short notice in the card.
/// </summary>
public sealed class VoiceEnroller(EngineLayout layout, Func<EngineOptions> options)
{
    private readonly DispatcherQueue _ui = DispatcherQueue.GetForCurrentThread();
    private readonly SemaphoreSlim _one = new(1, 1);
    private int _waiting;

    /// <summary>A run started or ended, or a notice came: the card shows it.</summary>
    public event EventHandler? Changed;

    public bool IsBusy => _waiting > 0;

    /// <summary>What the last run did, for a few seconds; null when there is nothing to say.</summary>
    public (bool Ok, string Text)? Notice { get; private set; }

    /// <summary>Learns each named speaker's voice from the call; generic labels and the user are skipped.</summary>
    public async Task EnrollAsync(IEnumerable<string> names, string profile, string dir, string me, IReadOnlyCollection<VoiceRecord> records)
    {
        var own = records.Where(r => r.Me).Select(r => r.Name).ToList();
        foreach (var name in Voices.NamesToEnroll(names, me, own))
        {
            var outcome = await RunAsync(Voices.EnrollCall(name, profile, dir, name));
            Show(outcome.IsOk, outcome.IsOk
                ? Loc.L("Голос «%@» сохранён", name)
                : Loc.L("Голос «%@» не сохранён: %@", name, outcome.Message.Length > 0 ? outcome.Message : Loc.L("подробности в voice.log")));
        }
    }

    private async Task<RunOutcome> RunAsync(IReadOnlyList<string> arguments)
    {
        Interlocked.Increment(ref _waiting);
        Changed?.Invoke(this, EventArgs.Empty);
        await _one.WaitAsync();
        try
        {
            if (!layout.IsInstalled)
            {
                return new RunOutcome.Failed(-1, Loc.L("Движок не установлен"));
            }
            var tracker = new OutputTracker();
            var request = new EngineRunRequest(layout.Python, [layout.Script(Voices.Script), .. arguments],
                EngineEnvironment.Build(layout, options()), layout.Data, Path.Combine(layout.Data, "voice.log"));
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
            _ui.TryEnqueue(() => Changed?.Invoke(this, EventArgs.Empty));
        }
    }

    private void Show(bool ok, string text)
    {
        _ui.TryEnqueue(() =>
        {
            Notice = (ok, text);
            Changed?.Invoke(this, EventArgs.Empty);
        });
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
