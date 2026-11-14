using CommunityToolkit.Mvvm.ComponentModel;
using Sozvon.App.Calls;
using Sozvon.App.Recording;
using Sozvon.App.Settings;
using Sozvon.App.Strings;
using Sozvon.Core.Engine;

namespace Sozvon.App.Tray;

public enum TrayState { Ready, Recording, SetupNeeded }

/// <summary>What the tray shows: the app's state and the live numbers from the calls folder.</summary>
public sealed partial class TrayViewModel : ObservableObject
{
    private const string StateArgument = "--tray-state=";
    private readonly CallRepository _repository;
    private readonly AppSettings _settings;
    private readonly EngineLayout _layout;
    private readonly Func<EngineStateKind> _engine;
    private readonly TrayState? _previewState;
    private readonly DateTime _startedAt = DateTime.Now;

    public TrayViewModel(CallRepository repository, AppSettings settings, EngineLayout layout, Func<EngineStateKind> engine)
    {
        _engine = engine;
        _repository = repository;
        _settings = settings;
        _layout = layout;
        _previewState = ParsePreview();
        Refresh();
    }

    /// <summary>Set once the capsule and the recorder exist.</summary>
    public RecordingController? Recording { get; set; }

    /// <summary>The state was forced from the command line for a screenshot.</summary>
    public bool IsPreview => _previewState is not null;

    public bool FloatingPanel => _settings.FloatingPanel;

    public int WaitingForDescription { get; private set; }

    public string? LatestCallId { get; private set; }

    /// <summary>The latest call's folder when its audio is there to transcribe again.</summary>
    public string? LatestAudioFolder { get; private set; }

    [ObservableProperty] public partial TrayState State { get; private set; }

    /// <summary>The engine can transcribe: set up, but its model may still be missing (then "Finish Setup…" instead of "Start Recording").</summary>
    public bool EngineUsable { get; private set; } = true;

    public string StatusText => State switch
    {
        TrayState.Recording => Loc.L("Идёт запись %@", CallFormat.Clock((Recording?.IsRecording == true ? Recording.Elapsed : DateTime.Now - _startedAt).TotalSeconds)) + (IsPreview ? " · " + Loc.L("предпросмотр") : ""),
        TrayState.SetupNeeded => Loc.L("Нужна настройка"),
        // As the Mac's menu: the engine has work, though a recording can still start.
        _ when !IsPreview && Recording?.Processor.HasWork == true => Loc.L("Расшифровка…"),
        _ => Loc.L("Готов к записи"),
    };

    public string ToolTip => "Sozvon · " + State switch
    {
        TrayState.Recording => Loc.L("Идёт запись") + (IsPreview ? " · " + Loc.L("предпросмотр") : ""),
        TrayState.SetupNeeded => Loc.L("Нужна настройка"),
        _ => Loc.L("Готов к записи"),
    };

    public void Refresh()
    {
        // The same check as Settings' "Python" row and the recorder (the venv and the marker of a finished install), and a
        // setup closed halfway: "Finish Setup…" continues it on the step it was closed on.
        var engine = _engine();
        EngineUsable = _previewState is not null || EngineState.IsUsable(engine);
        var setupNeeded = !_layout.IsInstalled || !SetupFlow.IsDone(SetupProgress.Load(_layout.Data), engine);
        State = _previewState ?? (Recording?.IsRecording == true ? TrayState.Recording : setupNeeded ? TrayState.SetupNeeded : TrayState.Ready);
        var calls = _repository.Scan();
        WaitingForDescription = calls.Count(c => c.IsWaitingForDescription);
        var latest = calls.FirstOrDefault(c => c.Status == CallStatus.Done && !c.IsDemo);
        LatestCallId = latest?.Id;
        LatestAudioFolder = latest is { HasAudio: true } ? latest.Folder : null;
    }

    private static TrayState? ParsePreview()
    {
        var value = Environment.GetCommandLineArgs().FirstOrDefault(a => a.StartsWith(StateArgument, StringComparison.Ordinal))?[StateArgument.Length..];
        return value switch
        {
            "recording" => TrayState.Recording,
            "ready" => TrayState.Ready,
            "setup" => TrayState.SetupNeeded,
            _ => null,
        };
    }
}
