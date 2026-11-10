using Microsoft.Win32;

namespace Sozvon.Core.Settings;

/// <summary>Whether Windows starts Sozvon at sign-in.</summary>
public enum SignInState
{
    Off,

    /// <summary>The Run value starts this copy of Sozvon.</summary>
    On,

    /// <summary>The Run value is there, but it was switched off in Task Manager's startup apps.</summary>
    OffInTaskManager,
}

/// <summary>
/// "Open at sign-in", as SMAppService does on the Mac: a value in the user's Run key that starts this executable. Only
/// the user's own keys (HKCU) are touched, and only the value named Sozvon. The keys are given by the caller, so tests use
/// a key of their own and never the real Run key.
/// </summary>
public sealed class SignInLaunch(string runKey = SignInLaunch.RunKey, string approvedKey = SignInLaunch.ApprovedKey, string valueName = "Sozvon")
{
    public const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    /// <summary>Where Task Manager keeps its own switch for each Run value.</summary>
    public const string ApprovedKey = @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";

    /// <summary>The command of the Run value: the executable in quotes, nothing else; the app starts in the tray.</summary>
    public static string Command(string exe) => $"\"{exe}\"";

    /// <summary>On only when the value starts this very executable; another copy's value reads as off.</summary>
    public SignInState State(string exe)
    {
        using var run = Registry.CurrentUser.OpenSubKey(runKey);
        if (run?.GetValue(valueName) is not string command || !SameExecutable(command, exe)) return SignInState.Off;
        return DisabledInTaskManager() ? SignInState.OffInTaskManager : SignInState.On;
    }

    /// <summary>
    /// Writes the value for this executable. The user asked for it here, so a "Disabled" left by Task Manager for this
    /// value goes too: otherwise Windows would keep ignoring it.
    /// </summary>
    public void Enable(string exe)
    {
        using (var run = Registry.CurrentUser.CreateSubKey(runKey, writable: true))
        {
            run.SetValue(valueName, Command(exe), RegistryValueKind.String);
        }
        if (DisabledInTaskManager())
        {
            using var approved = Registry.CurrentUser.OpenSubKey(approvedKey, writable: true);
            approved?.DeleteValue(valueName, throwOnMissingValue: false);
        }
    }

    /// <summary>Removes the value, but only when it starts this executable: another copy of Sozvon keeps its own.</summary>
    public void Disable(string exe)
    {
        using var run = Registry.CurrentUser.OpenSubKey(runKey, writable: true);
        if (run?.GetValue(valueName) is string command && SameExecutable(command, exe))
            run.DeleteValue(valueName, throwOnMissingValue: false);
    }

    /// <summary>Task Manager writes 12 bytes per value; an odd first byte means switched off there.</summary>
    private bool DisabledInTaskManager()
    {
        using var approved = Registry.CurrentUser.OpenSubKey(approvedKey);
        return approved?.GetValue(valueName) is byte[] { Length: > 0 } flags && (flags[0] & 1) == 1;
    }

    /// <summary>The executable of a Run command: quoted or not, arguments after it ignored.</summary>
    internal static bool SameExecutable(string command, string exe)
    {
        var text = command.Trim();
        string path;
        if (text.StartsWith('"'))
        {
            var end = text.IndexOf('"', 1);
            path = end > 0 ? text[1..end] : text.Trim('"');
        }
        else
        {
            var at = text.IndexOf(".exe", StringComparison.OrdinalIgnoreCase);
            path = at >= 0 ? text[..(at + 4)] : text;
        }
        try
        {
            return string.Equals(Path.GetFullPath(Environment.ExpandEnvironmentVariables(path)), Path.GetFullPath(exe), StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return false;
        }
    }
}
