using System.Text;

namespace Sozvon.Core.Engine;

/// <summary>Cuts a byte stream into UTF-8 lines. A character split across two reads stays whole.</summary>
internal sealed class LineSplitter(Action<string> onLine)
{
    private readonly MemoryStream _pending = new();

    internal void Feed(ReadOnlySpan<byte> bytes)
    {
        while (true)
        {
            var newline = bytes.IndexOf((byte)'\n');
            if (newline < 0) break;
            _pending.Write(bytes[..newline]);
            Emit();
            bytes = bytes[(newline + 1)..];
        }
        _pending.Write(bytes);
    }

    /// <summary>The output ended: a last line without a line end still counts.</summary>
    internal void Finish()
    {
        if (_pending.Length > 0) Emit();
    }

    private void Emit()
    {
        onLine(Encoding.UTF8.GetString(_pending.GetBuffer(), 0, (int)_pending.Length).TrimEnd('\r'));
        _pending.SetLength(0);
    }
}
