using System.Globalization;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Sozvon.App.Capsule;
using Sozvon.Audio;
using Sozvon.Core.Calls;
using Sozvon.Core.Engine;

namespace Sozvon.App.Recording;

/// <summary>Connects the capsule to the recorder and the engine: one recording, then its transcription.</summary>
internal sealed class RecordingController
{
    private static readonly TimeSpan SavedShownFor = TimeSpan.FromSeconds(3);

    private readonly CapsuleWindow _capsule;
    private readonly EngineLayout _layout;
    private readonly IRecorder _recorder;
    private readonly CallProcessor _processor;
    private readonly DispatcherQueue _ui = DispatcherQueue.GetForCurrentThread();
    private readonly DispatcherTimer _clock = new() { Interval = TimeSpan.FromSeconds(1) };
    private string? _dir;
    private DateTimeOffset _startedAt;
    private int _marks;
    private TrackWarning? _warning;
    private bool _recording;

    /// <summary>Asked for when the user presses Record and the engine is not installed yet.</summary>
    public event EventHandler? SetupNeeded;

    public RecordingController(CapsuleWindow capsule, EngineLayout layout)
    {
        _capsule = capsule;
        _layout = layout;
        _recorder = new WasapiRecorder(RecorderOptions.ForDataDirectory(layout.Data));
        var language = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "ru" ? "ru" : "en";
        _processor = new CallProcessor(layout.Calls, new EngineSupervisor(layout, new EngineOptions(language)), () => Project.All(layout.Profiles))
        {
            HoldsQueue = () => _recording,
        };
        _processor.Changed += () => _ui.TryEnqueue(ShowProcessing);
        _clock.Tick += (_, _) => RenderRecording();
        _recorder.LevelsChanged += (_, levels) => _ui.TryEnqueue(() => OnLevels(levels));
        _recorder.Failed += (_, _) => _ui.TryEnqueue(() => _ = StopAsync());
        capsule.RecordClicked += (_, _) => _ = StartAsync();
        capsule.PrimaryClicked += (_, _) => _ = StartAsync();
        capsule.StopClicked += (_, _) => _ = StopAsync();
        capsule.MarkClicked += (_, _) => Mark();
    }

    public void Start()
    {
        _processor.RestoreQueue();
        _processor.StartNext();
        ShowProcessing();
    }

    private async Task StartAsync()
    {
        if (_recording)
        {
            return;
        }
        if (!_layout.IsInstalled)
        {
            SetupNeeded?.Invoke(this, EventArgs.Empty);
            return;
        }
        _capsule.Render(new CapsuleModel(CapsulePhase.Starting));
        var dir = CallFolder.Create(_layout.Calls);
        try
        {
            await _recorder.StartAsync(dir);
        }
        catch (RecorderStartException)
        {
            Directory.Delete(dir, recursive: true);
            _capsule.Render(new CapsuleModel(CapsulePhase.Idle));
            return;
        }
        _dir = dir;
        _startedAt = DateTimeOffset.Now;
        _marks = 0;
        _warning = null;
        _recording = true;
        _clock.Start();
        RenderRecording();
    }

    private async Task StopAsync()
    {
        if (!_recording || _dir is not { } dir)
        {
            return;
        }
        _recording = false;
        _clock.Stop();
        _capsule.Render(new CapsuleModel(CapsulePhase.Starting));
        var result = await _recorder.StopAsync();
        var minutes = (int)Math.Round((DateTimeOffset.Now - _startedAt).TotalMinutes);
        var info = new CallInfo();
        var audio = result.Audio;
        CallFile.SaveStopped(dir, _startedAt, new Sozvon.Core.Calls.AudioTimes(audio.MicStart, audio.SystemStart, audio.MicSeconds, audio.SystemSeconds), info);
        _capsule.Render(new CapsuleModel(CapsulePhase.Saved) { SavedMinutes = minutes > 0 ? minutes : null });
        await Task.Delay(SavedShownFor);
        _processor.Transcribe(dir, info);
        ShowProcessing();
    }

    private void Mark()
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
        if (_recording)
        {
            return;
        }
        _capsule.Render(new CapsuleModel(_processor.HasWork ? CapsulePhase.Processing : CapsulePhase.Idle));
    }
}
