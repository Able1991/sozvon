namespace Sozvon.Core.Foundation;

/// <summary>Writes a whole file or nothing: a temporary file beside it, then a rename.</summary>
public static class AtomicFile
{
    public static void Write(string path, byte[] content)
    {
        var folder = Path.GetDirectoryName(path) ?? throw new ArgumentException("no folder in the path", nameof(path));
        var temporary = Path.Combine(folder, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(content);
                stream.Flush(flushToDisk: true);
            }
            BusyRetry.Run(() => File.Move(temporary, path, overwrite: true));
        }
        catch
        {
            File.Delete(temporary);
            throw;
        }
    }
}
