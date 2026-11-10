using Microsoft.UI.Xaml;
using Sozvon.App.Settings;
using Sozvon.App.Shell;
using Sozvon.App.Strings;
using Sozvon.Core.Calls;
using Sozvon.Core.Engine;

namespace Sozvon.App.Recording;

/// <summary>
/// Recordings from the phone, as on the Mac: every half a minute one new audio file of the chosen folder becomes a call
/// and goes to transcription with no questions, as a recording of one person thinking out loud. The file moves to the
/// folder's Imported subfolder. The rules are in <see cref="PhoneInbox"/>.
/// </summary>
public sealed class PhoneInboxWatcher(AppSettings settings, EngineLayout layout, EngineSettings engine, RecordingController recording)
{
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(30) };

    /// <summary>Files that could not leave the folder: said once, not tried again until the next launch.</summary>
    private readonly HashSet<string> _stuck = new(StringComparer.OrdinalIgnoreCase);
    private bool _working;

    /// <summary>Something the user has to know, as a sentence ready to show.</summary>
    public event EventHandler<string>? Problem;

    /// <summary>A recording became a call: the list shows it.</summary>
    public event EventHandler? Imported;

    public void Start()
    {
        _timer.Tick += (_, _) => Tick();
        _timer.Start();
    }

    /// <summary>One step: nothing while recording, without the engine or with nothing ready.</summary>
    public async void Tick()
    {
        var folder = settings.PhoneFolder;
        if (_working || folder.Length == 0 || recording.IsRecording || !layout.IsInstalled)
        {
            return;
        }
        _working = true;
        try
        {
            var ffmpeg = Path.Combine(layout.ScriptsFolder, "ffmpeg.exe");
            var result = await Task.Run(() => PhoneInbox.ImportNextAsync(folder, layout.Calls, ffmpeg, _stuck, DateTime.UtcNow));
            switch (result)
            {
                case PhoneImport.Imported imported:
                    var info = engine.NewCall() with { Topic = imported.Topic, Reflection = true };
                    if (recording.Processor.Transcribe(imported.CallDir, info) == EnqueueResult.NotSaved)
                    {
                        Problem?.Invoke(this, Loc.L("Не удалось сохранить данные звонка"));
                    }
                    Imported?.Invoke(this, EventArgs.Empty);
                    break;
                case PhoneImport.Stuck stuck:
                    _stuck.Add(stuck.File);
                    Problem?.Invoke(this, Loc.L("Не получилось перенести «%@» в папку Imported", Path.GetFileName(stuck.File)) + "\n"
                        + Loc.L("Запись не импортирована: разреши запись в эту папку."));
                    break;
                case PhoneImport.Failed failed:
                    Problem?.Invoke(this, Loc.L("Не получилось импортировать «%@»", Path.GetFileName(failed.File)) + "\n"
                        + (failed.Message.Length > 0 ? failed.Message : Loc.L("В файле нет звуковой дорожки")));
                    break;
            }
        }
        catch (Exception error)
        {
            AppHost.Log(error);
        }
        finally
        {
            _working = false;
        }
    }
}
