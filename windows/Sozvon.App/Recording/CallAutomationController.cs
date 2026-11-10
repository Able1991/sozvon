using Microsoft.UI.Xaml;
using Sozvon.App.Shell;
using Sozvon.Audio.Capture;
using Sozvon.Core.Automation;

namespace Sozvon.App.Recording;

/// <summary>
/// Around a call, as on the Mac (CallPrompt.swift): "A call is on in Zoom. Record?", or the countdown to an automatic
/// start, and the optional automatic stop once the call is over. The rules live in Sozvon.Core
/// (<see cref="CallAutomationRules"/>); this feeds them once a second with who holds a microphone.
/// </summary>
public sealed class CallAutomationController
{
    private static readonly TimeSpan Interval = TimeSpan.FromSeconds(1);

    private readonly CallAutomationRules _rules = new(Environment.ProcessId);
    private volatile bool _inCall;
    private readonly DispatcherTimer _timer = new() { Interval = Interval };
    private readonly Func<CallSituation> _situation;
    private bool _scanning;

    /// <summary>The prompt, a countdown or whether a call is on changed.</summary>
    public event EventHandler? Changed;

    /// <summary>The start countdown ran out.</summary>
    public event EventHandler? RecordRequested;

    /// <summary>The stop countdown ran out.</summary>
    public event EventHandler? StopRequested;

    public CallAutomationController(Func<CallSituation> situation)
    {
        _situation = situation;
        _timer.Tick += (_, _) => Refresh();
    }

    public CallApp? Prompt => _rules.Prompt;

    public int? StartIn => _rules.StartIn;

    public int? StopIn => _rules.StopIn;

    /// <summary>A known call app holds a microphone right now. Read from any thread (the transcription queue asks).</summary>
    public bool InCall => _inCall;

    public void Start()
    {
        _timer.Start();
        Refresh();
    }

    public void Stop() => _timer.Stop();

    /// <summary>"Record" on the prompt: this call is not offered again.</summary>
    public void Record() => Apply(_rules.Record);

    /// <summary>"Not now" or "Don't record": nothing for this call until its app lets go of the microphone.</summary>
    public void NotNow() => Apply(_rules.NotNow);

    /// <summary>"Continue" on the stop countdown: no automatic stop for the rest of this recording.</summary>
    public void KeepRecording() => Apply(_rules.KeepRecording);

    /// <summary>Reads the microphone's users off the UI thread, then applies the rules on it.</summary>
    public async void Refresh()
    {
        if (_scanning)
        {
            return;
        }
        _scanning = true;
        try
        {
            var clients = await Task.Run(CaptureSessions.Active);
            var before = Snapshot();
            var action = _rules.Update(clients.Select(ToMicClient), DateTimeOffset.Now, _situation());
            _inCall = _rules.InCall;
            if (Snapshot() != before)
            {
                Changed?.Invoke(this, EventArgs.Empty);
            }
            if (action == CallAction.Record)
            {
                RecordRequested?.Invoke(this, EventArgs.Empty);
            }
            else if (action == CallAction.Stop)
            {
                StopRequested?.Invoke(this, EventArgs.Empty);
            }
        }
        catch (Exception error)
        {
            // A timer callback must not end the app; the next tick tries again.
            AppHost.Log(error);
        }
        finally
        {
            _scanning = false;
        }
    }

    private void Apply(Action change)
    {
        change();
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private (CallApp?, int?, int?, bool) Snapshot() => (Prompt, StartIn, StopIn, InCall);

    private static MicClient ToMicClient(CaptureClient c) => new(c.ProcessId, c.ProcessName, c.ImagePath, c.ParentName, c.Package);
}
