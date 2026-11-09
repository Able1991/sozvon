using System.Security.Cryptography;
using System.Text;
using Sozvon.Core.Foundation;
using Sozvon.Core.Settings;

namespace Sozvon.Core.Engine;

public enum EngineStateKind { NotInstalled, NeedsUpdate, ModelMissing, Ready }

/// <summary>Install state in the data folder.</summary>
public static class EngineState
{
    private const int HashLength = 16;

    /// <param name="isDevEngine">The developer's own engine: its environment is not compared with uv.lock.</param>
    public static EngineStateKind Evaluate(EngineLayout layout, WhisperModel model, bool isDevEngine = false)
    {
        if (!layout.IsInstalled) return EngineStateKind.NotInstalled;
        if (!isDevEngine && NeedsUpdate(layout)) return EngineStateKind.NeedsUpdate;
        return model.IsDownloaded(layout.Data) ? EngineStateKind.Ready : EngineStateKind.ModelMissing;
    }

    public static bool IsUsable(EngineStateKind state) => state is EngineStateKind.Ready or EngineStateKind.NeedsUpdate;

    /// <summary>The first 16 hex characters of the sha256 of uv.lock.</summary>
    public static string LockHash(byte[] lockFile) => Hex(lockFile)[..HashLength];

    /// <summary>
    /// The hash of a GPU install (engine install.environment_hash): the requirements file replaces torch on top of the
    /// lock, so both decide what the environment holds.
    /// </summary>
    public static string GpuLockHash(byte[] lockFile, byte[] overlay) =>
        Hex(Encoding.UTF8.GetBytes(Hex(lockFile) + Hex(overlay)))[..HashLength];

    private static bool NeedsUpdate(EngineLayout layout)
    {
        var lockFile = SharedFile.ReadBytes(Path.Combine(layout.Data, "uv.lock"));
        if (lockFile is null) return false;
        var installed = SharedFile.ReadText(Path.Combine(layout.Data, ".venv-lock"))?.Trim();
        return installed is null || !AcceptedHashes(layout, lockFile).Contains(installed);
    }

    /// <summary>Which GPU build was installed is the engine's knowledge: any shipped overlay matches.</summary>
    private static IEnumerable<string> AcceptedHashes(EngineLayout layout, byte[] lockFile)
    {
        yield return LockHash(lockFile);
        var gpu = Path.Combine(layout.Data, "gpu");
        if (!Directory.Exists(gpu)) yield break;
        foreach (var file in Directory.GetFiles(gpu, "*.txt"))
            if (SharedFile.ReadBytes(file) is { } overlay) yield return GpuLockHash(lockFile, overlay);
    }

    private static string Hex(byte[] data) => Convert.ToHexStringLower(SHA256.HashData(data));
}
