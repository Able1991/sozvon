using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace Sozvon.Audio.Capture;

/// <summary>A process using a microphone right now.</summary>
/// <param name="ProcessId">0 when known only from the privacy store.</param>
/// <param name="ProcessName">The executable's name without ".exe"; empty for a Store app known only by its package.</param>
/// <param name="ParentName">The parent's executable name, for shared helpers (WebView2 audio runs for Teams, WhatsApp...).</param>
public sealed record CaptureClient(int ProcessId, string ProcessName, string? ImagePath = null, string? ParentName = null, string? Package = null);

/// <summary>
/// Who captures audio input: the processes with an active capture session on any microphone that is on. Only reads:
/// nothing here opens a device or changes a setting. Call from an MTA thread (the thread pool).
/// </summary>
public static class CaptureSessions
{
    private const uint DeviceStateActive = 1;
    private const uint ClsctxAll = 23;
    private const int SessionStateActive = 1;
    private const int SystemSoundsSession = 0;
    private const string ConsentStore = @"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";

    private static Guid s_sessionManager2 = new("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F");

    /// <summary>
    /// The audio sessions first; when they cannot be read, the privacy store, which Windows keeps for the microphone
    /// icon in the taskbar: an app that started using the microphone and has not stopped yet.
    /// </summary>
    public static IReadOnlyList<CaptureClient> Active()
    {
        try
        {
            return Describe(ActiveSessionProcesses());
        }
        catch (Exception ex) when (ex is COMException or InvalidCastException)
        {
            return FromPrivacyStore();
        }
    }

    /// <summary>Process ids with an active, non-system capture session.</summary>
    internal static HashSet<int> ActiveSessionProcesses()
    {
        var pids = new HashSet<int>();
        var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
        IMMDeviceCollection? devices = null;
        try
        {
            enumerator.EnumAudioEndpoints(EDataFlow.Capture, DeviceStateActive, out devices);
            devices.GetCount(out uint count);
            for (uint i = 0; i < count; i++)
            {
                devices.Item(i, out IMMDevice device);
                try
                {
                    AddActive(device, pids);
                }
                catch (COMException)
                {
                    // A microphone unplugged in the middle of the scan: the others still count.
                }
                finally
                {
                    Marshal.ReleaseComObject(device);
                }
            }
        }
        finally
        {
            if (devices is not null) Marshal.ReleaseComObject(devices);
            Marshal.ReleaseComObject(enumerator);
        }
        return pids;
    }

    private static void AddActive(IMMDevice device, HashSet<int> pids)
    {
        device.Activate(ref s_sessionManager2, ClsctxAll, IntPtr.Zero, out object instance);
        var manager = (IAudioSessionManager2)instance;
        IAudioSessionEnumerator? sessions = null;
        try
        {
            manager.GetSessionEnumerator(out sessions);
            sessions.GetCount(out int count);
            for (int i = 0; i < count; i++)
            {
                sessions.GetSession(i, out object session);
                try
                {
                    var control = (IAudioSessionControl2)session;
                    control.GetState(out int state);
                    if (state == SessionStateActive && control.IsSystemSoundsSession() != SystemSoundsSession
                        && control.GetProcessId(out uint pid) >= 0 && pid != 0)
                    {
                        pids.Add((int)pid);
                    }
                }
                finally
                {
                    Marshal.ReleaseComObject(session);
                }
            }
        }
        finally
        {
            if (sessions is not null) Marshal.ReleaseComObject(sessions);
            Marshal.ReleaseComObject(manager);
        }
    }

    private static List<CaptureClient> Describe(HashSet<int> pids)
    {
        if (pids.Count == 0) return [];
        var processes = ProcessTable.Snapshot();
        var clients = new List<CaptureClient>();
        foreach (int pid in pids)
        {
            // A process that ended between the scan and the snapshot is gone from the call too.
            if (!processes.TryGetValue(pid, out var entry)) continue;
            string? parent = processes.TryGetValue(entry.ParentId, out var p) ? p.Name : null;
            clients.Add(new CaptureClient(pid, StripExe(entry.Name), ProcessTable.ImagePath(pid), parent is null ? null : StripExe(parent)));
        }
        return clients;
    }

    /// <summary>
    /// The privacy store: one key per app, LastUsedTimeStop 0 while it holds the microphone. Desktop apps are under
    /// NonPackaged with their path ("C:#Program Files#Zoom#bin#Zoom.exe"), Store apps by package family name. An app
    /// that ended without saying so stays "in use" there, so a desktop app counts only while it runs.
    /// </summary>
    public static IReadOnlyList<CaptureClient> FromPrivacyStore()
    {
        var running = ProcessTable.Snapshot().Values.Select(e => StripExe(e.Name)).ToHashSet(StringComparer.OrdinalIgnoreCase);
        return StillRunning(ReadPrivacyStore(), running);
    }

    internal static List<CaptureClient> StillRunning(IEnumerable<CaptureClient> clients, IReadOnlySet<string> runningNames) =>
        clients.Where(c => c.Package is not null || runningNames.Contains(c.ProcessName)).ToList();

    private static List<CaptureClient> ReadPrivacyStore()
    {
        var clients = new List<CaptureClient>();
        try
        {
            using var root = Registry.CurrentUser.OpenSubKey(ConsentStore);
            if (root is null) return clients;
            foreach (string name in root.GetSubKeyNames())
            {
                using var key = root.OpenSubKey(name);
                if (key is null) continue;
                if (name == "NonPackaged")
                {
                    foreach (string app in key.GetSubKeyNames())
                    {
                        using var appKey = key.OpenSubKey(app);
                        if (appKey is not null && InUse(appKey)) clients.Add(FromStorePath(app.Replace('#', '\\')));
                    }
                }
                else if (InUse(key))
                {
                    clients.Add(new CaptureClient(0, "", Package: name));
                }
            }
        }
        catch (Exception ex) when (ex is System.Security.SecurityException or IOException or UnauthorizedAccessException)
        {
            // Nothing readable: no call is known.
        }
        return clients;
    }

    internal static CaptureClient FromStorePath(string path) => new(0, StripExe(Path.GetFileName(path)), path);

    internal static bool InUse(long start, long stop) => start > 0 && stop == 0;

    private static bool InUse(RegistryKey key) =>
        key.GetValue("LastUsedTimeStart") is long start && key.GetValue("LastUsedTimeStop") is long stop && InUse(start, stop);

    private static string StripExe(string name) =>
        name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? name[..^4] : name;
}
