using Sozvon.App.Settings;
using Sozvon.Core.Calls;
using Sozvon.Core.Engine;

namespace Sozvon.App.Recording;

/// <summary>How "What was the call about?" was answered.</summary>
public abstract record CallInfoAnswer
{
    public sealed record Transcribe(CallInfo Info) : CallInfoAnswer;

    /// <summary>"Later". Null: the window was closed, call.json keeps what it has.</summary>
    public sealed record Later(CallInfo? Info) : CallInfoAnswer;

    /// <summary>"Don't transcribe", or a cancelled edit.</summary>
    public sealed record Cancel : CallInfoAnswer;
}

/// <param name="Countdown">Seconds until the form goes ahead by itself; editing it stops the countdown.</param>
public sealed record CallInfoRequest(CallInfo Initial, string Title, string OkTitle, bool AllowLater, int? Countdown = null);

/// <summary>Shows the form, one window at a time: a new question closes the one still open, which ends its wait.</summary>
public sealed class CallInfoPrompt(EngineLayout layout, EngineSettings engine, AppSettings settings)
{
    private CallInfoWindow? _window;

    public bool IsOpen => _window is not null;

    public void BringToFront() => _window?.Activate();

    public void Close() => _window?.Close();

    public async Task<CallInfoAnswer> AskAsync(CallInfoRequest request)
    {
        _window?.Close();
        var window = new CallInfoWindow(request, layout, engine, settings);
        window.Closed += (_, _) => Forget(window);
        _window = window;
        window.Activate();
        var answer = await window.Answer;
        // The answer comes before the window has closed: whoever acts on it must already see the form as gone,
        // or a relaunch waiting for the form never goes ahead.
        Forget(window);
        return answer;
    }

    private void Forget(CallInfoWindow window)
    {
        if (_window == window)
        {
            _window = null;
        }
    }
}
