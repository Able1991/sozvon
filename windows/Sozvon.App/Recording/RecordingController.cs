using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Sozvon.App.Capsule;
using Sozvon.App.Settings;
using Sozvon.App.Shell;
using Sozvon.App.Strings;
using Sozvon.Audio;
using Sozvon.Core.Calls;
using Sozvon.Core.Engine;

namespace Sozvon.App.Recording;

/// <summary>Connects the capsule to the recorder and the engine: one recording, then its transcription.</summary>
public sealed class RecordingController
{
    private static readonly TimeSpan SavedShownFor = TimeSpan.FromSeconds(3);
    private static readonly TimeSpan ReminderShownFor = TimeSpan.FromSeconds(8);

    private readonly CapsuleWindow _capsule;
    private readonly EngineLayout _layout;
    private readonly AppSettings _settings;
    private readonly EngineSettings _engine;
    private readonly CallInfoPrompt _prompt;
    private readonly IRecorder _recorder;
    private readonly CallProcessor _processor;
    private readonly DispatcherQueue _ui = DispatcherQueue.GetForCurrentThread();
    private readonly DispatcherTimer _clock = new() { Interval = TimeSpan.FromSeconds(1) };
    private string? _dir;
    private DateTimeOffset _startedAt;
    private CallInfo _info = new();
    private int _marks;
    private TrackWarning? _warning;
    private bool _recording;
    private bool _changing;
    private bool _remind;

    /// <summary>Asked for when the user presses Record and the engine is not installed yet.</summary>
    public event EventHandler? SetupNeeded;

    /// <summary>A recording started or ended, or a call got or lost its description.</summary>
    public event EventHandler? StateChanged;

    /// <summary>Something the user has to know about, as a sentence ready to show.</summary>
    public event EventHandler<string>? Problem;

    /// <summary>Settings: remind to say that the call is recorded.</summary>
    public Func<bool> RemindToSay { get; set; } = () => false;

    /// <summary>Settings: the capsule is on screen. Without it the reminder comes as a notification.</summary>
    public Func<bool> PanelVisible { get; set; } = () => true;

    public bool IsRecording => _recording;

    public TimeSpan Elapsed => DateTimeOffset.Now - _startedAt;

    public RecordingController(CapsuleWindow capsule, EngineLayout layout, AppSettings settings, EngineSettings engine)
    {
        _capsule = capsule;
        _layout = layout;
        _settings = settings;
        _engine = engine;
        _prompt = new CallInfoPrompt(layout, engine, settings);
        _recorder = new WasapiRecorder(RecorderOptions.ForDataDirectory(layout.Data));
        _processor = new CallProcessor(layout.Calls, new EngineSupervisor(layout, engine.Options), () => Project.All(layout.Profiles))
        {
            HoldsQueue = () => _recording,
        };
        _processor.Changed += () => _ui.TryEnqueue(ShowProcessing);
        _clock.Tick += (_, _) => RenderRecording();
        _recorder.LevelsChanged += (_, levels) => _ui.TryEnqueue(() => OnLevels(levels));
        _recorder.Failed += (_, _) => _ui.TryEnqueue(Stop);
        capsule.RecordClicked += (_, _) => Begin();
        capsule.PrimaryClicked += (_, _) => Begin();
        capsule.StopClicked += (_, _) => Stop();
        capsule.MarkClicked += (_, _) => Mark();
    }

    public void Begin() => Run(StartAsync);

    public void Stop() => Run(() => StopAsync(askNow: true));

    /// <summary>"Project and participants" during a recording: what the form after it will start with.</summary>
    public void EditInfo()
    {
        if (_prompt.IsOpen)
        {
            _prompt.BringToFront();
        }
        else if (_recording)
        {
            Ask(new CallInfoRequest(_info, Loc.L("Проект и собеседники"), Loc.L("Сохранить"), AllowLater: false), answer =>
            {
                if (_recording && answer is CallInfoAnswer.Transcribe edited)
                {
                    _info = edited.Info;
                }
            });
        }
    }

    /// <summary>The oldest call waiting for its description: the form again.</summary>
    public void DescribePending()
    {
        if (_prompt.IsOpen)
        {
            _prompt.BringToFront();
        }
        else if (PendingInfo.All(_layout.Calls).FirstOrDefault(p => !_processor.Contains(p.Dir)) is { } pending)
        {
            var initial = CallFile.Info(CallFile.Read(pending.Dir), fallback: _engine.NewCall());
            Ask(DescribeRequest(initial), answer => Apply(pending.Dir, answer));
        }
    }

    private static CallInfoRequest DescribeRequest(CallInfo initial, int? countdown = null) =>
        new(initial, Loc.L("О чём был звонок?"), Loc.L("Расшифровать"), AllowLater: true, countdown);

    /// <summary>Saves a recording in progress and stops the engine; the saved call waits for its description.</summary>
    public async Task ShutdownAsync()
    {
        _prompt.Close();
        if (_recording)
        {
            await StopAsync(askNow: false);
        }
        await _processor.AbortAllAsync();
    }

    public void Start()
    {
        _processor.RestoreQueue();
        _processor.StartNext();
        ShowProcessing();
        Run(RecoverInterruptedAsync);
    }

    /// <summary>A launch may find a recording the previous run never closed: it is saved and goes to the queue.</summary>
    private async Task RecoverInterruptedAsync()
    {
        foreach (var dir in RecordingRecovery.FindInterrupted(_layout.Calls))
        {
            var result = await RecordingRecovery.RecoverAsync(dir, RecorderOptions.ForDataDirectory(_layout.Data).FfmpegPath);
            var info = _engine.NewCall();
            Save(dir, Directory.GetCreationTime(dir), result, info);
            _processor.Transcribe(dir, info);
        }
        ShowProcessing();
    }

    /// <summary>Runs a step started by the user. A failure is logged and said out loud, and the capsule returns to rest.</summary>
    private async void Run(Func<Task> step)
    {
        try
        {
            await step();
        }
        catch (Exception error)
        {
            AppHost.Log(error);
            _recording = false;
            _changing = false;
            _clock.Stop();
            StateChanged?.Invoke(this, EventArgs.Empty);
            Problem?.Invoke(this, Loc.L("Не получилось: подробности в журнале программы."));
            ShowProcessing();
        }
    }

    private async Task StartAsync()
    {
        if (_recording || _changing)
        {
            return;
        }
        if (!_layout.IsInstalled)
        {
            SetupNeeded?.Invoke(this, EventArgs.Empty);
            return;
        }
        _changing = true;
        _capsule.Render(new CapsuleModel(CapsulePhase.Starting));
        var dir = CallFolder.Create(_layout.Calls);
        try
        {
            await _recorder.StartAsync(dir);
        }
        catch (RecorderStartException error)
        {
            AppHost.Log(error);
            _changing = false;
            Directory.Delete(dir, recursive: true);
            Problem?.Invoke(this, error.AccessDenied
                ? Loc.L("Нет доступа к микрофону. Разреши его в параметрах Windows: Конфиденциальность и защита, Микрофон.")
                : Loc.L("Микрофон не открылся. Проверь, что он подключён."));
            ShowProcessing();
            return;
        }
        _changing = false;
        _dir = dir;
        _startedAt = DateTimeOffset.Now;
        _info = _engine.NewCall() with { Profile = _settings.LastProject };
        _marks = 0;
        _warning = null;
        _recording = true;
        _clock.Start();
        _remind = RemindToSay();
        if (_remind && !PanelVisible())
        {
            Problem?.Invoke(this, CapsuleText.TellOthers);
        }
        RenderRecording();
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>
    /// The call stays pending until the form is answered: ignored, closed or the app gone, it waits under
    /// "Waiting for description" rather than being lost.
    /// </summary>
    private async Task StopAsync(bool askNow)
    {
        if (!_recording || _dir is not { } dir)
        {
            return;
        }
        _recording = false;
        _clock.Stop();
        StateChanged?.Invoke(this, EventArgs.Empty);
        _capsule.Render(new CapsuleModel(CapsulePhase.Starting));
        var result = await _recorder.StopAsync();
        var minutes = (int)Math.Round((DateTimeOffset.Now - _startedAt).TotalMinutes);
        Save(dir, _startedAt, result, _info);
        CallFile.SetInfoPending(dir, true);
        StateChanged?.Invoke(this, EventArgs.Empty);
        if (!askNow)
        {
            return;
        }
        _processor.StartNext();
        _capsule.Render(new CapsuleModel(CapsulePhase.Saved) { SavedMinutes = minutes > 0 ? minutes : null });
        var (info, sure) = CallGuess.Fill(_info, _settings.LastProject, _startedAt, calendarEvent: null, heard: [], Project.All(_layout.Profiles));
        if (info != _info)
        {
            CallFile.WriteInfo(dir, info);
        }
        var countdown = sure && _settings.TranscribeWhenClear ? CallGuess.FormCountdown : (int?)null;
        Ask(DescribeRequest(info, countdown), answer => Apply(dir, answer));
        await Task.Delay(SavedShownFor);
        ShowProcessing();
    }

    /// <summary>Waits for the form outside <see cref="Run"/>: by the time it is answered a new recording may be going on.</summary>
    private async void Ask(CallInfoRequest request, Action<CallInfoAnswer> apply)
    {
        try
        {
            apply(await _prompt.AskAsync(request));
        }
        catch (Exception error)
        {
            AppHost.Log(error);
            Problem?.Invoke(this, Loc.L("Не получилось: подробности в журнале программы."));
        }
    }

    private void Apply(string dir, CallInfoAnswer answer)
    {
        var saved = true;
        switch (answer)
        {
            case CallInfoAnswer.Transcribe { Info: var info }:
                _settings.LastProject = info.Profile;
                saved = _processor.Transcribe(dir, info) != EnqueueResult.NotSaved;
                break;
            case CallInfoAnswer.Later { Info: var info }:
                saved = (info is null || CallFile.WriteInfo(dir, info)) && CallFile.SetInfoPending(dir, true);
                break;
            case CallInfoAnswer.Cancel:
                saved = CallFile.SetInfoPending(dir, false);
                break;
        }
        if (!saved)
        {
            Problem?.Invoke(this, Loc.L("Не удалось сохранить данные звонка"));
        }
        StateChanged?.Invoke(this, EventArgs.Empty);
        ShowProcessing();
    }

    private static void Save(string dir, DateTimeOffset startedAt, RecordingResult result, CallInfo info)
    {
        var audio = result.Audio;
        CallFile.SaveStopped(dir, startedAt, new Sozvon.Core.Calls.AudioTimes(audio.MicStart, audio.SystemStart, audio.MicSeconds, audio.SystemSeconds), info);
    }

    public void Mark()
    {
        if (_recorder.Mark())
        {
            _marks++;
            RenderRecording();
        }
    }

    private void OnLevels(RecorderLevels levels)
    {
        _capsule.PushLevels(levels.Microphone, levels.System);
        _warning = levels.Warning;
    }

    private void RenderRecording()
    {
        if (!_recording)
        {
            return;
        }
        var hint = _warning?.Track switch
        {
            RecordingTrack.Microphone => CapsuleHint.MicSilent,
            RecordingTrack.System => CapsuleHint.SystemSilent,
            _ when _remind && Elapsed < ReminderShownFor => CapsuleHint.TellOthers,
            _ => CapsuleHint.None,
        };
        _capsule.Render(new CapsuleModel(CapsulePhase.Recording)
        {
            Elapsed = DateTimeOffset.Now - _startedAt,
            Marks = _marks,
            Hint = hint,
            HintTime = TimeSpan.FromSeconds(_warning?.Seconds ?? 0),
        });
    }

    private void ShowProcessing()
    {
        if (_recording || _changing)
        {
            return;
        }
        _capsule.Render(new CapsuleModel(_processor.HasWork ? CapsulePhase.Processing : CapsulePhase.Idle));
    }
}
