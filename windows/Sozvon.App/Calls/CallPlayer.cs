using System.IO;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Sozvon.App.Strings;
using Windows.Media;
using Windows.Media.Core;
using Windows.Media.Playback;

namespace Sozvon.App.Calls;

/// <summary>Plays a call: listen.m4a when it is there, otherwise the tracks together, aligned by their offsets.</summary>
public sealed partial class CallPlayer : ObservableObject, IDisposable
{
    private const long MinListenFileBytes = 1024;
    private static readonly double[] Rates = [1, 1.5, 2];

    private readonly MediaTimelineController _clock = new();
    private readonly List<MediaPlayer> _players = [];
    private readonly SynchronizationContext _ui = SynchronizationContext.Current!;

    public CallPlayer(CallRecord call)
    {
        Duration = call.DurationSeconds;
        var tracks = call.IsDemo || call.AudioRemoved ? [] : FindTracks(call);
        IsAvailable = tracks.Count > 0;
        Unavailable = IsAvailable ? "" : Loc.L(call.IsDemo ? "В демо-звонке нет записи" : "Запись недоступна");
        foreach (var (path, offset) in tracks)
        {
            AddTrack(path, offset);
        }
        _clock.PositionChanged += OnPositionChanged;
    }

    public bool IsAvailable { get; private set; }

    public string Unavailable { get; private set; }

    [ObservableProperty] public partial double Position { get; private set; }

    [ObservableProperty] public partial double Duration { get; private set; }

    [ObservableProperty] public partial bool IsPlaying { get; private set; }

    [ObservableProperty] public partial string Error { get; private set; } = "";

    [ObservableProperty] public partial int RateIndex { get; set; }

    partial void OnRateIndexChanged(int value) => _clock.ClockRate = Rates[value];

    [RelayCommand]
    private void TogglePlay()
    {
        if (!IsAvailable)
        {
            return;
        }
        if (IsPlaying)
        {
            _clock.Pause();
        }
        else
        {
            _clock.Resume();
        }
        IsPlaying = !IsPlaying;
    }

    [RelayCommand]
    private void Back() => Seek(Position - 15);

    [RelayCommand]
    private void Forward() => Seek(Position + 15);

    /// <summary>A click on a transcript line: plays from its start.</summary>
    public void PlayFrom(double seconds)
    {
        Seek(seconds);
        if (!IsPlaying)
        {
            TogglePlay();
        }
    }

    public void Seek(double seconds)
    {
        var target = Math.Clamp(seconds, 0, Math.Max(Duration, 0));
        _clock.Position = TimeSpan.FromSeconds(target);
        Position = target;
    }

    public void Dispose()
    {
        _clock.PositionChanged -= OnPositionChanged;
        _clock.Pause();
        foreach (var player in _players)
        {
            player.Dispose();
        }
    }

    private static List<(string Path, double Offset)> FindTracks(CallRecord call)
    {
        var listen = Path.Combine(call.Folder, "listen.m4a");
        if (File.Exists(listen) && new FileInfo(listen).Length >= MinListenFileBytes)
        {
            return [(listen, 0)];
        }
        var tracks = new List<(string, double)>();
        var earliest = Math.Min(call.MicStart ?? double.MaxValue, call.SystemStart ?? double.MaxValue);
        var clean = Path.Combine(call.Folder, "mic.clean.m4a");
        var mic = Path.Combine(call.Folder, "mic.m4a");
        if (File.Exists(clean))
        {
            tracks.Add((clean, 0));
        }
        else if (File.Exists(mic))
        {
            tracks.Add((mic, Offset(call.MicStart, earliest)));
        }
        var system = Path.Combine(call.Folder, "system.m4a");
        if (File.Exists(system))
        {
            tracks.Add((system, Offset(call.SystemStart, earliest)));
        }
        return tracks;
    }

    private static double Offset(double? start, double earliest) => start is { } value ? value - earliest : 0;

    private void AddTrack(string path, double offset)
    {
        var player = new MediaPlayer { TimelineController = _clock };
        player.CommandManager.IsEnabled = false;
        player.TimelineControllerPositionOffset = TimeSpan.FromSeconds(offset);
        player.MediaFailed += (_, args) => _ui.Post(_ => Error = args.ErrorMessage, null);
        player.PlaybackSession.NaturalDurationChanged += (session, _) => OnNaturalDuration(session.NaturalDuration.TotalSeconds + offset);
        player.Source = MediaSource.CreateFromUri(new Uri(path));
        _players.Add(player);
    }

    private void OnNaturalDuration(double seconds) => _ui.Post(_ => Duration = Math.Max(Duration, seconds), null);

    private void OnPositionChanged(MediaTimelineController sender, object args)
    {
        var seconds = sender.Position.TotalSeconds;
        _ui.Post(_ =>
        {
            Position = Math.Min(seconds, Duration);
            if (IsPlaying && Duration > 0 && seconds >= Duration)
            {
                _clock.Pause();
                _clock.Position = TimeSpan.Zero;
                Position = 0;
                IsPlaying = false;
            }
        }, null);
    }
}
