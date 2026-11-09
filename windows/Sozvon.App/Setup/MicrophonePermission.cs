using Microsoft.Win32;

namespace Sozvon.App.Setup;

/// <summary>Reads the Windows privacy switches for the microphone. Never changes them.</summary>
internal static class MicrophonePermission
{
    private const string Store = @"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";

    public static bool IsAllowed =>
        !IsDenied(Registry.LocalMachine, Store) && !IsDenied(Registry.CurrentUser, Store) && !IsDenied(Registry.CurrentUser, Store + @"\NonPackaged");

    private static bool IsDenied(RegistryKey hive, string path)
    {
        using var key = hive.OpenSubKey(path);
        return string.Equals(key?.GetValue("Value") as string, "Deny", StringComparison.OrdinalIgnoreCase);
    }
}
