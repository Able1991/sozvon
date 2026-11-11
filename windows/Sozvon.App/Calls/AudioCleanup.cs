using Microsoft.UI.Xaml;
using Sozvon.App.Settings;
using Sozvon.Core.Calls;

namespace Sozvon.App.Calls;

/// <summary>
/// "Delete audio automatically" (Settings, After the call): finished calls older than the chosen days lose their
/// tracks; the transcript, summary and notes stay. Runs at launch, every 6 hours and when the setting changes.
/// Calls being recorded, queued or transcribed are never touched.
/// </summary>
public sealed class AudioCleanup(Func<string> callsFolder, AppSettings settings, Func<string, bool> busy)
{
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromHours(6) };

    /// <summary>Audio was removed: the list and the card read the calls again.</summary>
    public event EventHandler? Removed;

    public void Start()
    {
        _timer.Tick += (_, _) => Run();
        _timer.Start();
        Run();
    }

    /// <summary>What a choice in Settings would remove right now: the number of calls and their bytes.</summary>
    public (int Calls, long Bytes) Preview(int choice)
    {
        var dirs = Expired(AudioRetention.Days(choice));
        return (dirs.Count, AudioRetention.Size(dirs));
    }

    /// <summary>Removes the expired audio. The bytes freed.</summary>
    public long Run()
    {
        var days = AudioRetention.Days(settings.AudioRetention);
        long freed = 0;
        foreach (var dir in Expired(days))
        {
            freed += AudioRetention.RemoveAudio(dir, DateTimeOffset.UtcNow);
        }
        if (freed > 0)
        {
            Removed?.Invoke(this, EventArgs.Empty);
        }
        return freed;
    }

    private List<string> Expired(int days) => AudioRetention.Expired(callsFolder(), days, DateTimeOffset.UtcNow, busy);
}
