using Microsoft.UI.Xaml;

namespace Sozvon.App.Capsule;

/// <summary>Plays the capsule's states with made-up levels, for looking at it before the recorder is connected.</summary>
internal sealed class CapsuleDemo
{
    private static readonly IReadOnlyDictionary<string, CapsuleModel> States = new Dictionary<string, CapsuleModel>
    {
        ["idle"] = new(CapsulePhase.Idle),
        ["starting"] = new(CapsulePhase.Starting),
        ["recording"] = new(CapsulePhase.Recording) { Elapsed = TimeSpan.FromSeconds(767), Marks = 0 },
        ["marked"] = new(CapsulePhase.Recording) { Elapsed = TimeSpan.FromSeconds(1283), Marks = 3 },
        ["stop"] = new(CapsulePhase.Recording) { Elapsed = TimeSpan.FromSeconds(1283), Hint = CapsuleHint.StopCountdown, HintTime = TimeSpan.FromSeconds(24) },
        ["tell"] = new(CapsulePhase.Recording) { Elapsed = TimeSpan.FromSeconds(4), Hint = CapsuleHint.TellOthers },
        ["mic"] = new(CapsulePhase.Recording) { Elapsed = TimeSpan.FromSeconds(800), Hint = CapsuleHint.MicSilent, HintTime = TimeSpan.FromSeconds(72) },
        ["system"] = new(CapsulePhase.Recording) { Elapsed = TimeSpan.FromSeconds(800), Hint = CapsuleHint.SystemSilent, HintTime = TimeSpan.FromSeconds(72) },
        ["saved"] = new(CapsulePhase.Saved) { SavedMinutes = 42 },
        ["processing"] = new(CapsulePhase.Processing),
        ["prompt"] = new(CapsulePhase.Prompt) { CallApp = "Zoom" },
        ["auto"] = new(CapsulePhase.Prompt) { CallApp = "Zoom", AutoStartSeconds = 8 },
    };

    private readonly CapsuleWindow _window;
    private readonly DispatcherTimer _levels = new() { Interval = TimeSpan.FromMilliseconds(80) };
    private readonly DispatcherTimer _next = new() { Interval = TimeSpan.FromSeconds(3) };
    private readonly Random _random = new(7);
    private readonly List<string> _names = States.Keys.ToList();
    private int _index;
    private double _phase;

    public CapsuleDemo(CapsuleWindow window)
    {
        _window = window;
        _levels.Tick += (_, _) => PushLevels();
        _next.Tick += (_, _) => Next();
    }

    /// <summary>Shows one state, or goes through all of them when <paramref name="state"/> is empty.</summary>
    public void Start(string state)
    {
        _levels.Start();
        if (States.TryGetValue(state, out var model))
        {
            _window.Render(model);
            return;
        }
        _window.Render(States[_names[0]]);
        _next.Start();
    }

    private void Next()
    {
        _index = (_index + 1) % _names.Count;
        _window.Render(States[_names[_index]]);
    }

    private void PushLevels()
    {
        _phase += 0.08;
        var meTalking = Math.Sin(_phase) > 0;
        _window.PushLevels(meTalking ? 0.3 + _random.NextDouble() * 0.7 : 0.02, meTalking ? 0.02 : 0.25 + _random.NextDouble() * 0.7);
    }
}
