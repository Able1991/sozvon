using System.ComponentModel;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

namespace Sozvon.Core.Engine;

public sealed record EngineRunRequest(string Executable, IReadOnlyList<string> Arguments, IReadOnlyDictionary<string, string> Environment,
                                      string WorkingDirectory, string? LogPath = null);

/// <summary>The process could not be started; the message says why.</summary>
public sealed class EngineStartException(string message, Exception? inner = null) : Exception(message, inner);

/// <summary>
/// One process tree in its own Job: started suspended and assigned before it runs, so no child can slip out. Output and
/// errors go through one pipe, keeping their order, into the log and out line by line in UTF-8.
/// </summary>
public sealed class EngineProcess
{
    /// <summary>Exit code of a run that was ended from outside: 128 + SIGTERM, like the engine's own.</summary>
    public const int StoppedExitCode = 143;

    private static readonly TimeSpan OutputDrain = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan JobEmptyWait = TimeSpan.FromSeconds(3);

    private readonly JobObject _job;
    private readonly SafeProcessHandle _process;
    private readonly NamedPipeServerStream _output;
    private readonly FileStream? _log;
    private readonly CancellationTokenSource _stopReading = new();
    private readonly object _gate = new();
    private bool _finished;

    public int ProcessId { get; }

    /// <summary>The exit code, once the Job is empty, the output has ended and the log is closed.</summary>
    public Task<int> Completion { get; }

    /// <summary>How many processes are alive in the Job; 0 after the run ended.</summary>
    public int ActiveProcesses
    {
        get
        {
            lock (_gate) return _finished ? 0 : _job.ActiveProcesses;
        }
    }

    private EngineProcess(JobObject job, SafeProcessHandle process, int processId, NamedPipeServerStream output, FileStream? log, Action<string>? onLine)
    {
        (_job, _process, ProcessId, _output, _log) = (job, process, processId, output, log);
        var pump = PumpAsync(onLine ?? (_ => { }));
        Completion = FinishAsync(pump);
    }

    /// <param name="onLine">Called on a background thread, in order, for every output line.</param>
    public static EngineProcess Start(EngineRunRequest request, Action<string>? onLine = null)
    {
        FileStream? log = null;
        NamedPipeServerStream? output = null;
        JobObject? job = null;
        try
        {
            log = OpenLog(request.LogPath);
            job = new JobObject();
            var pipeName = $"sozvon-engine-{Guid.NewGuid():N}";
            output = new NamedPipeServerStream(pipeName, PipeDirection.In, 1, PipeTransmissionMode.Byte,
                                               PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            using var writer = new NamedPipeClientStream(".", pipeName, PipeDirection.Out, PipeOptions.CurrentUserOnly,
                                                         TokenImpersonationLevel.None, HandleInheritability.Inheritable);
            var connected = output.WaitForConnectionAsync();
            writer.Connect(5000);
            connected.GetAwaiter().GetResult();
            using var noInput = File.OpenHandle("NUL", FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Inheritable);
            var (process, processId) = Launch(request, job, noInput, writer.SafePipeHandle);
            return new EngineProcess(job, process, processId, output, log, onLine);
        }
        catch (Exception e) when (e is IOException or Win32Exception or UnauthorizedAccessException or TimeoutException)
        {
            log?.Dispose();
            output?.Dispose();
            job?.Dispose();
            throw new EngineStartException(e.Message, e);
        }
    }

    /// <summary>Ends every process of the Job at once.</summary>
    public void Terminate()
    {
        lock (_gate)
        {
            if (!_finished) _job.Terminate(StoppedExitCode);
        }
    }

    private static FileStream? OpenLog(string? path) =>
        path is null ? null : new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);

    private static (SafeProcessHandle, int) Launch(EngineRunRequest request, JobObject job, SafeFileHandle stdin, SafePipeHandle stdout)
    {
        var inherited = Marshal.AllocHGlobal(2 * nint.Size);
        nint attributes = 0;
        try
        {
            Marshal.WriteIntPtr(inherited, 0, stdin.DangerousGetHandle());
            Marshal.WriteIntPtr(inherited, nint.Size, stdout.DangerousGetHandle());
            attributes = HandleListAttribute(inherited);

            var startup = new Native.StartupInfoEx { AttributeList = attributes };
            startup.Info.Size = Marshal.SizeOf<Native.StartupInfoEx>();
            startup.Info.Flags = Native.StartfUseStdHandles;
            startup.Info.StdInput = stdin.DangerousGetHandle();
            startup.Info.StdOutput = stdout.DangerousGetHandle();
            startup.Info.StdError = stdout.DangerousGetHandle();

            var commandLine = (CommandLine.Join(request.Executable, request.Arguments) + "\0").ToCharArray();
            const uint flags = Native.CreateSuspended | Native.CreateNoWindow | Native.CreateUnicodeEnvironment | Native.ExtendedStartupInfoPresent;
            if (!Native.CreateProcessW(request.Executable, commandLine, 0, 0, inheritHandles: true, flags,
                                       CommandLine.EnvironmentBlock(request.Environment), request.WorkingDirectory, ref startup, out var info))
                throw new Win32Exception(Marshal.GetLastPInvokeError());
            return (AssignAndResume(job, info), info.ProcessId);
        }
        finally
        {
            if (attributes != 0)
            {
                Native.DeleteProcThreadAttributeList(attributes);
                Marshal.FreeHGlobal(attributes);
            }
            Marshal.FreeHGlobal(inherited);
            GC.KeepAlive(stdin);
            GC.KeepAlive(stdout);
        }
    }

    /// <summary>Only the two listed handles reach the child, whatever else in the app happens to be inheritable.</summary>
    private static nint HandleListAttribute(nint handles)
    {
        nint size = 0;
        Native.InitializeProcThreadAttributeList(0, 1, 0, ref size);
        var list = Marshal.AllocHGlobal(size);
        if (!Native.InitializeProcThreadAttributeList(list, 1, 0, ref size))
        {
            var error = Marshal.GetLastPInvokeError();
            Marshal.FreeHGlobal(list);
            throw new Win32Exception(error);
        }
        if (!Native.UpdateProcThreadAttribute(list, 0, Native.ProcThreadAttributeHandleList, handles, 2 * nint.Size, 0, 0))
        {
            var error = Marshal.GetLastPInvokeError();
            Native.DeleteProcThreadAttributeList(list);
            Marshal.FreeHGlobal(list);
            throw new Win32Exception(error);
        }
        return list;
    }

    private static SafeProcessHandle AssignAndResume(JobObject job, Native.ProcessInformation info)
    {
        var process = new SafeProcessHandle(info.Process, ownsHandle: true);
        try
        {
            job.Assign(info.Process);
            if (Native.ResumeThread(info.Thread) == uint.MaxValue) throw new Win32Exception(Marshal.GetLastPInvokeError());
            return process;
        }
        catch
        {
            Native.TerminateProcess(info.Process, 1);
            process.Dispose();
            throw;
        }
        finally
        {
            Native.CloseHandle(info.Thread);
        }
    }

    private async Task PumpAsync(Action<string> onLine)
    {
        var splitter = new LineSplitter(onLine);
        var buffer = new byte[64 * 1024];
        var log = _log;
        try
        {
            while (true)
            {
                var count = await _output.ReadAsync(buffer, _stopReading.Token);
                if (count == 0) break;
                log = Append(log, buffer.AsSpan(0, count));
                splitter.Feed(buffer.AsSpan(0, count));
            }
        }
        catch (Exception e) when (e is OperationCanceledException or IOException)
        {
            // The output ended without an end of file: what was read stands.
        }
        splitter.Finish();
    }

    /// <summary>A full disk must not end the run: the log just stops.</summary>
    private static FileStream? Append(FileStream? log, ReadOnlySpan<byte> bytes)
    {
        if (log is null) return null;
        try
        {
            log.Write(bytes);
            log.Flush();
            return log;
        }
        catch (IOException)
        {
            return null;
        }
    }

    private async Task<int> FinishAsync(Task pump)
    {
        await WaitForExitAsync();
        Native.GetExitCodeProcess(_process, out var exitCode);
        lock (_gate) _job.Terminate(exitCode); // workers outliving the engine have nobody to work for
        await _job.WaitUntilEmptyAsync(JobEmptyWait);
        try
        {
            await pump.WaitAsync(OutputDrain);
        }
        catch (TimeoutException)
        {
            _stopReading.Cancel();
            await pump;
        }
        lock (_gate)
        {
            _finished = true;
            _job.Dispose();
        }
        _output.Dispose();
        _log?.Dispose();
        _process.Dispose();
        return (int)exitCode;
    }

    private Task WaitForExitAsync()
    {
        var exited = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var handle = new ProcessWait(_process);
        var registration = ThreadPool.RegisterWaitForSingleObject(handle, (_, _) => exited.TrySetResult(), null, Timeout.Infinite, executeOnlyOnce: true);
        return exited.Task.ContinueWith(_ =>
        {
            registration.Unregister(null);
            handle.Dispose();
        }, TaskScheduler.Default);
    }

    private sealed class ProcessWait : WaitHandle
    {
        internal ProcessWait(SafeProcessHandle process) => SafeWaitHandle = new SafeWaitHandle(process.DangerousGetHandle(), ownsHandle: false);
    }
}
