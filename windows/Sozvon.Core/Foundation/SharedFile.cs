using System.Text;

namespace Sozvon.Core.Foundation;

/// <summary>Reading files the engine may hold open or replace at the same moment.</summary>
public static class SharedFile
{
    private const FileShare ShareAll = FileShare.ReadWrite | FileShare.Delete;

    /// <summary>The whole file, or null when it is missing or cannot be read.</summary>
    public static byte[]? ReadBytes(string path)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, ShareAll);
            using var copy = new MemoryStream();
            stream.CopyTo(copy);
            return copy.ToArray();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// <summary>The file as UTF-8 text, or null when it is missing or cannot be read.</summary>
    public static string? ReadText(string path)
    {
        var bytes = ReadBytes(path);
        if (bytes is null) return null;
        var start = bytes.AsSpan().StartsWith(Encoding.UTF8.Preamble) ? Encoding.UTF8.Preamble.Length : 0;
        return Encoding.UTF8.GetString(bytes, start, bytes.Length - start);
    }
}
