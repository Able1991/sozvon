using System.Diagnostics;
using System.Text;

namespace Sozvon.App.Setup;

/// <summary>Runs engine\setup.ps1 as a child process and passes on its output line by line, also into setup.log.</summary>
internal sealed class EngineInstaller(SetupContext context)
{
    private static readonly UTF8Encoding Utf8 = new(encoderShouldEmitUTF8Identifier: false);
    private readonly Lock _lock = new();
    private Process? _process;

    /// <summary>Raised on a background thread.</summary>
    public event Action<string>? LineReceived;

    /// <summary>Runs the installer to its end and returns its exit code.</summary>
    public async Task<int> RunAsync(bool gpu)
    {
        Directory.CreateDirectory(context.DataFolder);
        await using var log = new StreamWriter(
            new FileStream(context.LogFile, FileMode.Create, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete), Utf8) { AutoFlush = true };

        using var process = Process.Start(StartInfo(gpu)) ?? throw new InvalidOperationException("powershell did not start");
        lock (_lock)
        {
            _process = process;
        }
        var readers = Task.WhenAll(Pump(process.StandardOutput, log), Pump(process.StandardError, log));
        await process.WaitForExitAsync();
        // A grandchild that outlived the tree could keep the pipes open for ever.
        await Task.WhenAny(readers, Task.Delay(TimeSpan.FromSeconds(2)));
        lock (_lock)
        {
            _process = null;
        }
        return process.ExitCode;
    }

    public void Stop()
    {
        lock (_lock)
        {
            try
            {
                _process?.Kill(entireProcessTree: true);
            }
            catch (Exception e) when (e is InvalidOperationException or AggregateException)
            {
                // It ended on its own in the meantime, or a child could not be reached; the installer is safe to run again.
            }
        }
    }

    private ProcessStartInfo StartInfo(bool gpu)
    {
        var powershell = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");
        var start = new ProcessStartInfo(powershell)
        {
            WorkingDirectory = context.DataFolder,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Utf8,
            StandardErrorEncoding = Utf8,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        foreach (var argument in new[] { "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", context.SetupScript, "-DataDir", context.DataFolder })
        {
            start.ArgumentList.Add(argument);
        }
        if (gpu)
        {
            start.ArgumentList.Add("-Gpu");
        }
        start.Environment["SOZVON_UI_LANG"] = Strings.EngineLanguage;
        return start;
    }

    private async Task Pump(StreamReader reader, StreamWriter log)
    {
        while (await reader.ReadLineAsync() is { } line)
        {
            lock (_lock)
            {
                log.WriteLine(line);
            }
            LineReceived?.Invoke(line);
        }
    }
}
