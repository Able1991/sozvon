using Microsoft.UI.Dispatching;
using Sozvon.Core.Assistants;
using Sozvon.Core.Engine;
using Sozvon.Core.Settings;

namespace Sozvon.App.Settings;

/// <summary>
/// Whether each assistant's CLI answers, through the very command a summary uses (bin\check_assistant.py), as the Mac's
/// AssistantChecks: run when an assistant is chosen or connected, and once per launch when the Assistants tab opens.
/// "Connected" alone says nothing about a CLI that is logged out, too old or cannot start. The check runs off the UI
/// thread; results and <see cref="Changed"/> come on the thread that created this object.
/// </summary>
/// <param name="l">The text table of the process: Loc in the app, the wizard's own Strings in the setup process.</param>
public sealed class AssistantChecks(EngineLayout layout, Func<EngineOptions> options, Func<string, object[], string> l, TimeSpan? timeout = null)
{
    private readonly DispatcherQueue _ui = DispatcherQueue.GetForCurrentThread();
    private readonly Dictionary<Assistant, AssistantCheck> _results = [];

    public event EventHandler? Changed;

    /// <summary>The last check of the assistant; null when it was never checked.</summary>
    public AssistantCheck? Result(Assistant a) => _results.GetValueOrDefault(a);

    public bool IsRunning(Assistant a) => Result(a)?.State == AssistantCheckState.Running;

    public void RunOnce(Assistant a)
    {
        if (!_results.ContainsKey(a)) Run(a);
    }

    public void Run(Assistant a)
    {
        if (a == Assistant.None || IsRunning(a)) return;
        if (AssistantCli.Find(a, AssistantHome.FromEnvironment()) is null)
        {
            Set(a, AssistantCheck.Failed(l("не найден %@", [AssistantCli.Name(a)!])));
            return;
        }
        // Without the engine there is nothing to ask through; the install brings the check.
        if (!layout.IsInstalled) return;
        Set(a, AssistantCheck.Running);
        var engineOptions = options();
        _ = Task.Run(async () =>
        {
            AssistantCheck result;
            try
            {
                result = await AssistantCheckScript.RunAsync(layout, engineOptions, a, timeout);
            }
            catch (Exception e)
            {
                result = AssistantCheck.Failed(e.Message);
            }
            _ui.TryEnqueue(() => Set(a, result));
        });
    }

    /// <summary>The line under a failed check: what the CLI said with the engine's hint; null when it answered or was not checked.</summary>
    public string? Problem(Assistant a)
    {
        if (Result(a) is not { State: AssistantCheckState.Failed } failed) return null;
        var title = AssistantCli.Title(a);
        if (failed.TimedOut) return l("%@ не ответил за %@ с", [title, (int)(timeout ?? AssistantCheckScript.DefaultTimeout).TotalSeconds]);
        return failed.Message.Length == 0
            ? l("%@ не ответил. Подробности в assistant.log", [title])
            : l("%@ не ответил: %@", [title, failed.Message]);
    }

    private void Set(Assistant a, AssistantCheck result)
    {
        _results[a] = result;
        Changed?.Invoke(this, EventArgs.Empty);
    }
}
