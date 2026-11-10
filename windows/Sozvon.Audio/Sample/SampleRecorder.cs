using System.Diagnostics;
using Sozvon.Audio.Capture;

namespace Sozvon.Audio.Sample;

/// <summary>
/// Records the default microphone into a 16-bit mono WAV for the own voice sample, with the level of the last
/// packets and the time recorded. One recording per instance. With <c>silent</c> it records silence for as long as it
/// runs and never opens a device (<see cref="RecorderOptions.SilentCapture"/>).
/// </summary>
public sealed class SampleRecorder : IDisposable
{
    private readonly string _path;
    private readonly Func<ICaptureDevices>? _devices;
    private readonly Stopwatch _clock = new();
    private readonly TaskCompletionSource _opened = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource _finished = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private volatile bool _stopping;
    private double _rms;
    private Thread? _thread;

    public SampleRecorder(string path, bool silent)
        : this(path, silent ? null : () => new WasapiDevices(CaptureKind.Microphone))
    {
    }

    /// <param name="devices">Null records silence.</param>
    internal SampleRecorder(string path, Func<ICaptureDevices>? devices)
    {
        _path = path;
        _devices = devices;
    }

    /// <summary>Recorded so far; stays at the final length after <see cref="StopAsync"/>.</summary>
    public TimeSpan Elapsed => _clock.Elapsed;

    /// <summary>The RMS (0…1) of the packets read since the last call.</summary>
    public double TakeRms() => Interlocked.Exchange(ref _rms, 0);

    /// <summary>The microphone failed while recording: the file is incomplete.</summary>
    public Exception? Failure { get; private set; }

    /// <summary>Opens the device and starts writing <c>path</c>, which must not exist yet.</summary>
    /// <exception cref="RecorderStartException">No microphone could be opened, or the file could not be created.</exception>
    public Task StartAsync()
    {
        if (_thread is not null) throw new InvalidOperationException("already started");
        _thread = new Thread(Run) { IsBackground = true, Name = "Sozvon voice sample" };
        _thread.Start();
        return _opened.Task;
    }

    /// <summary>Stops and closes the file.</summary>
    public async Task StopAsync()
    {
        _stopping = true;
        if (_thread is null) return;
        await _finished.Task.ConfigureAwait(false);
    }

    public void Dispose() => _stopping = true;

    private void Run()
    {
        ICaptureDevices? devices = null;
        ICaptureEndpoint? endpoint = null;
        WavWriter? wav = null;
        try
        {
            try
            {
                wav = new WavWriter(_path, RecordingFormat.SampleRate);
                if (_devices is not null)
                {
                    devices = _devices();
                    endpoint = devices.Open();
                }
            }
            catch (EndpointUnavailableException e)
            {
                throw new RecorderStartException(e.Message, e.AccessDenied, e);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException)
            {
                throw new RecorderStartException(e.Message, accessDenied: false, e);
            }
            _clock.Start();
            _opened.TrySetResult();
            Record(endpoint, wav);
        }
        catch (RecorderStartException e)
        {
            _opened.TrySetException(e);
        }
        catch (Exception e) when (e is EndpointLostException or IOException)
        {
            Failure = e;
        }
        finally
        {
            _clock.Stop();
            endpoint?.Dispose();
            devices?.Dispose();
            try
            {
                wav?.Dispose();
            }
            catch (IOException e)
            {
                Failure ??= e;
            }
            _opened.TrySetResult();
            _finished.TrySetResult();
        }
    }

    private void Record(ICaptureEndpoint? endpoint, WavWriter wav)
    {
        var buffer = new float[RecordingFormat.SampleRate];
        while (!_stopping)
        {
            if (endpoint is null)
            {
                // Silence for as long as the clock runs, so the file is as long as the recording looked.
                wav.WriteSilence((int)(_clock.Elapsed.TotalSeconds * RecordingFormat.SampleRate - wav.Samples));
                Thread.Sleep(20);
                continue;
            }
            if (!endpoint.TryRead(ref buffer, out var packet))
            {
                Thread.Sleep(10);
                continue;
            }
            var samples = buffer.AsSpan(0, packet.Frames * RecordingFormat.MicChannels);
            wav.Write(samples);
            double sum = 0;
            foreach (var s in samples) sum += s * s;
            if (samples.Length > 0) Interlocked.Exchange(ref _rms, Math.Max(Volatile.Read(ref _rms), Math.Sqrt(sum / samples.Length)));
        }
    }
}
