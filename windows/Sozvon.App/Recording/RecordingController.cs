using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Sozvon.App.Capsule;
using Sozvon.App.Settings;
using Sozvon.App.Shell;
using Sozvon.App.Strings;
using Sozvon.Audio;
using Sozvon.Core.Automation;
using Sozvon.Core.Calls;
using Sozvon.Core.Engine;

namespace Sozvon.App.Recording;

/// <summary>Connects the capsule to the recorder and the engine: one recording, then its transcription.</summary>
public sealed class RecordingController
{
    private static readonly TimeSpan ReminderShownFor = TimeSpan.FromSeconds(8);

    /// <summary>The Mac's "other side audible" (0.15 on the -50...0 dB meter, -42.5 dB) on the capsule's -75...-25 dB scale.</summary>
    private const float OtherSideAudibleLevel = 0.65f;
    private static readonly TimeSpan LevelsFreshFor = TimeSpan.FromSeconds(2);

    private readonly CapsuleWindow _capsule;
    private readonly EngineLayout _layout;
    private readonly AppSettings _settings;
    private readonly EngineSettings _engine;
    private readonly CallInfoPrompt _prompt;
    private readonly IRecorder _recorder;
    private readonly CallProcessor _processor;
    private readonly CallAutomationController _call;
    private readonly HotKey _markKeys;
    private readonly MarkShortcut _markShortcut = new();
    private readonly SavedNotice _saved = new();
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
    private DateTimeOffset _levelsAt;
    private float _systemLevel;
    private (CallApp? App, int? StartIn) _shownPrompt;
    private CallApp? _notifiedPrompt;
    private bool _wasInCall;

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

    /// <summary>A call was queued, started, finished or left the queue: the list shows it.</summary>
    public event EventHandler? CallsChanged;

    public bool IsRecording => _recording;

    /// <summary>
    /// Work a restart would cut short: a recording, its start or stop, the form after a call, or the engine's queue.
    /// </summary>
    public bool IsBusy => _recording || _changing || _prompt.IsOpen || _processor.HasWork;

    /// <summary>The folder being recorded into, or null.</summary>
    public string? RecordingDirectory => _recording ? _dir : null;

    /// <summary>The engine's queue: what is transcribed, what waits.</summary>
    public CallProcessor Processor => _processor;

    /// <summary>Whether Ctrl+Alt+I marks the moment right now, and whether another program has taken it.</summary>
    public MarkShortcut MarkShortcut => _markShortcut;

    public TimeSpan Elapsed => DateTimeOffset.Now - _startedAt;

    public RecordingController(CapsuleWindow capsule, EngineLayout layout, AppSettings settings, EngineSettings engine)
    {
        _capsule = capsule;
        _layout = layout;
        _settings = settings;
        _engine = engine;
        _prompt = new CallInfoPrompt(layout, engine, settings);
        // SOZVON_SILENT_CAPTURE=1: a test run of the whole app records silence, never the room.
        _recorder = new WasapiRecorder(RecorderOptions.ForDataDirectory(layout.Data) with
        {
            SilentCapture = Environment.GetEnvironmentVariable("SOZVON_SILENT_CAPTURE") == "1",
        });
        _call = new CallAutomationController(() => new CallSituation(
            CallAutomation.Mode(_settings.CallStartAction), _settings.StopAfterCall,
            Busy: _recording || _changing || !_layout.IsInstalled, Recording: _recording, OtherSideAudible: OtherSideAudible));
        _processor = new CallProcessor(layout.Calls, new EngineSupervisor(layout, engine.Options), () => Project.All(layout.Profiles))
        {
            // As on the Mac, transcription waits while a call is on: the call app needs the processor more.
            HoldsQueue = () => _recording || _call.InCall,
        };
        _processor.Changed += () => _ui.TryEnqueue(() =>
        {
            ShowProcessing();
            CallsChanged?.Invoke(this, EventArgs.Empty);
        });
        _processor.RunFinished += _ => _ui.TryEnqueue(() => CallsChanged?.Invoke(this, EventArgs.Empty));
        // Registered for each recording only, as on the Mac: other programs keep the keys in between.
        _markKeys = HotKey.Important(WinRT.Interop.WindowNative.GetWindowHandle(capsule), Mark);
        _call.Changed += (_, _) => OnCallChanged();
        _call.RecordRequested += (_, _) => Begin();
        _call.StopRequested += (_, _) => Stop();
        _clock.Tick += (_, _) => RenderRecording();
        _recorder.LevelsChanged += (_, levels) => _ui.TryEnqueue(() => OnLevels(levels));
        _recorder.Failed += (_, _) => _ui.TryEnqueue(Stop);
        _recorder.AlertRaised += (_, alert) => _ui.TryEnqueue(() => Tell(alert));
        capsule.RecordClicked += (_, _) => Begin();
        capsule.PrimaryClicked += (_, _) => Primary();
        capsule.SecondaryClicked += (_, _) => _call.NotNow();
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

    /// <summary>"Transcribe again…" (or "Describe…" for a call that waits): the form with the call's answers, then the queue.</summary>
    public void Retranscribe(string dir)
    {
        if (_prompt.IsOpen)
        {
            _prompt.BringToFront();
            return;
        }
        var call = CallFile.Read(dir);
        var initial = CallFile.Info(call, fallback: _engine.NewCall());
        var pending = PendingInfo.IsPending(call);
        Ask(new CallInfoRequest(initial, Loc.L("О чём был звонок?"), Loc.L("Расшифровать"), AllowLater: pending), answer => Apply(dir, answer));
    }

    /// <summary>"Update summary": a new summary from the transcript as it is now.</summary>
    public bool Resummarize(string dir)
    {
        var saved = _processor.Resummarize(dir) != EnqueueResult.NotSaved;
        if (!saved)
        {
            Problem?.Invoke(this, Loc.L("Не удалось сохранить данные звонка"));
        }
        return saved;
    }

    private static CallInfoRequest DescribeRequest(CallInfo initial, int? countdown = null) =>
        new(initial, Loc.L("О чём был звонок?"), Loc.L("Расшифровать"), AllowLater: true, countdown);

    /// <summary>Saves a recording in progress and stops the engine; the saved call waits for its description.</summary>
    public async Task ShutdownAsync()
    {
        _call.Stop();
        _prompt.Close();
        if (_recording)
        {
            await StopAsync(askNow: false);
        }
        _markKeys.Dispose();
        await _processor.AbortAllAsync();
    }

    public void Start()
    {
        CreateVocabularyIfMissing();
        _processor.RestoreQueue();
        _processor.StartNext();
        ShowProcessing();
        Run(RecoverInterruptedAsync);
        _call.Start();
    }

    /// <summary>As on the Mac, the default dictionary becomes vocab.json only on first install.</summary>
    private void CreateVocabularyIfMissing()
    {
        var vocabulary = Path.Combine(_layout.Data, "vocab.json");
        var initial = Path.Combine(_layout.Data, "vocab.default.json");
        if (!File.Exists(vocabulary) && File.Exists(initial))
        {
            File.Copy(initial, vocabulary);
        }
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
            ReleaseMarkKeys();
            _saved.End();
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
        await PlayChimeAsync(Chime.Start);
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
        _markShortcut.Registered(_markKeys.Register());
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
        // Busy until the call is saved and its form is up: no new recording and no restart in between.
        _changing = true;
        _clock.Stop();
        ReleaseMarkKeys();
        StateChanged?.Invoke(this, EventArgs.Empty);
        _capsule.Render(new CapsuleModel(CapsulePhase.Starting));
        var result = await _recorder.StopAsync();
        _ = PlayChimeAsync(Chime.Stop);
        var minutes = (int)Math.Round((DateTimeOffset.Now - _startedAt).TotalMinutes);
        Save(dir, _startedAt, result, _info);
        CallFile.SetInfoPending(dir, true);
        if (!askNow)
        {
            _changing = false;
            StateChanged?.Invoke(this, EventArgs.Empty);
            return;
        }
        // The queue going on reports a change, which redraws the resting capsule: the notice holds it off for its time.
        _processor.StartNext();
        _capsule.Render(new CapsuleModel(CapsulePhase.Saved) { SavedMinutes = minutes > 0 ? minutes : null });
        _saved.Show(DateTimeOffset.Now);
        var (info, sure) = CallGuess.Fill(_info, _settings.LastProject, _startedAt, calendarEvent: null, heard: [], Project.All(_layout.Profiles));
        if (info != _info)
        {
            CallFile.WriteInfo(dir, info);
        }
        var countdown = sure && _settings.TranscribeWhenClear ? CallGuess.FormCountdown : (int?)null;
        Ask(DescribeRequest(info, countdown), answer => Apply(dir, answer));
        _changing = false;
        StateChanged?.Invoke(this, EventArgs.Empty);
        await Task.Delay(SavedNotice.ShownFor);
        _saved.End();
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

    /// <summary>Settings: the tones at the start and the stop, never during a call (the microphone would carry them).</summary>
    private Task PlayChimeAsync(Chime chime) => _settings.PlaySounds && !_call.InCall ? Chimes.PlayAsync(chime) : Task.CompletedTask;

    private static void Save(string dir, DateTimeOffset startedAt, RecordingResult result, CallInfo info)
    {
        var audio = result.Audio;
        CallFile.SaveStopped(dir, startedAt, new Sozvon.Core.Calls.AudioTimes(audio.MicStart, audio.SystemStart, audio.MicSeconds, audio.SystemSeconds), info);
    }

    /// <summary>The star on the capsule, the tray menu or Ctrl+Alt+I from any program: this moment matters.</summary>
    public void Mark()
    {
        if (_recorder.Mark())
        {
            _marks++;
            RenderRecording();
        }
    }

    private void ReleaseMarkKeys()
    {
        _markKeys.Unregister();
        _markShortcut.Released();
    }

    private void OnLevels(RecorderLevels levels)
    {
        _capsule.PushLevels(levels.Microphone, levels.System);
        _warning = levels.Warning;
        _systemLevel = levels.System;
        _levelsAt = DateTimeOffset.Now;
    }

    /// <summary>The other side's track has sound right now: the call is not over, whatever the microphone says.</summary>
    private bool OtherSideAudible => _recording && DateTimeOffset.Now - _levelsAt < LevelsFreshFor && _systemLevel > OtherSideAudibleLevel;

    /// <summary>The capsule's one action button: "Record" on the prompt, "Continue" on the stop countdown.</summary>
    private void Primary()
    {
        if (_recording)
        {
            _call.KeepRecording();
            return;
        }
        if (_call.Prompt is not null)
        {
            _call.Record();
        }
        Begin();
    }

    private void OnCallChanged()
    {
        if (_wasInCall && !_call.InCall)
        {
            _processor.StartNext();
        }
        _wasInCall = _call.InCall;
        NotifyWithoutPanel();
        if (_recording)
        {
            RenderRecording();
        }
        else if (_shownPrompt != (_call.Prompt, _call.StartIn))
        {
            ShowProcessing();
        }
    }

    /// <summary>With the capsule hidden, the prompt comes as a notification, once per call.</summary>
    private void NotifyWithoutPanel()
    {
        if (_call.Prompt is not { } app)
        {
            _notifiedPrompt = null;
            return;
        }
        if (PanelVisible() || _notifiedPrompt == app)
        {
            return;
        }
        _notifiedPrompt = app;
        Problem?.Invoke(this, _call.StartIn is { } seconds
            ? Loc.L("Звонок в %@ · запись через %@ с", app.Name, seconds)
            : Loc.L("Идёт звонок в %@. Записать?", app.Name));
    }

    /// <summary>A track silent long enough after its recapture, or a very quiet voice: said unless turned off in Settings.</summary>
    private void Tell(RecorderAlert alert)
    {
        if (!_recording || !_settings.WarnOnSilence)
        {
            return;
        }
        var time = Call.Clock(alert.Seconds, "0:00");
        Problem?.Invoke(this, alert.Kind switch
        {
            RecorderAlertKind.MicrophoneSilent => Loc.L("Тебя не слышно %@", time) + "\n"
                + Loc.L("Микрофон молчит, и переподключение не помогло. Проверь, какой микрофон выбран в параметрах Windows: Система, Звук, и не отключились ли наушники."),
            RecorderAlertKind.SystemSilent => Loc.L("Их не слышно %@", time) + "\n"
                + Loc.L("Звук собеседников не приходит, и переподключение не помогло. Если они говорят, проверь, что звук звонка идёт через этот компьютер, а не через телефон или другое устройство."),
            _ => Loc.L("Тебя очень тихо слышно") + "\n"
                + Loc.L("Три минуты твой голос почти не слышен в микрофоне. Подними громкость входа или сядь ближе к компьютеру."),
        });
    }

    private void RenderRecording()
    {
        if (!_recording)
        {
            return;
        }
        // The call is over: the countdown to the automatic stop comes before any warning.
        var (hint, seconds) = (_call.StopIn, _warning) switch
        {
            ({ } stopIn, _) => (CapsuleHint.StopCountdown, stopIn),
            (_, { Track: RecordingTrack.Microphone } w) => (CapsuleHint.MicSilent, w.Seconds),
            (_, { Track: RecordingTrack.System } w) => (CapsuleHint.SystemSilent, w.Seconds),
            _ when _remind && Elapsed < ReminderShownFor => (CapsuleHint.TellOthers, 0),
            _ => (CapsuleHint.None, 0),
        };
        _capsule.Render(new CapsuleModel(CapsulePhase.Recording)
        {
            Elapsed = DateTimeOffset.Now - _startedAt,
            Marks = _marks,
            MarkShortcutHeld = _markShortcut.Held,
            Hint = hint,
            HintTime = TimeSpan.FromSeconds(seconds),
        });
    }

    /// <summary>At rest: the call prompt first, then the transcription in progress, otherwise the Record button.</summary>
    private void ShowProcessing()
    {
        if (_recording || _changing || _saved.Holds(DateTimeOffset.Now))
        {
            return;
        }
        _shownPrompt = (_call.Prompt, _call.StartIn);
        if (_call.Prompt is { } app)
        {
            _capsule.Render(new CapsuleModel(CapsulePhase.Prompt) { CallApp = app.Name, AutoStartSeconds = _call.StartIn });
            return;
        }
        _capsule.Render(new CapsuleModel(_processor.HasWork ? CapsulePhase.Processing : CapsulePhase.Idle));
    }
}
