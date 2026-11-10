namespace Sozvon.App.Capsule;

/// <summary>
/// The capsule's geometry. Every value is a multiple of 4 DIP, so at 100, 125 and 150 % each edge is a whole pixel.
/// The inner radius follows the outer one minus the padding, so the rounding stays concentric.
/// </summary>
public sealed record CapsuleStyle(string Name, int Height, int Padding, int Radius, int ButtonRadius)
{
    public const int Slot = 32;

    /// <summary>A full pill, like the Mac.</summary>
    public static readonly CapsuleStyle Pill = new("pill", 48, 12, 24, 16);

    /// <summary>Windows 11 rounding: a 12 DIP card with 4 DIP buttons inside.</summary>
    public static readonly CapsuleStyle Rounded = new("rounded", 48, 12, 12, 4);

    /// <summary>A lower pill that takes less of the screen.</summary>
    public static readonly CapsuleStyle Compact = new("compact", 40, 8, 20, 16);

    public static CapsuleStyle Named(string? name) => name switch
    {
        "rounded" => Rounded,
        "compact" => Compact,
        _ => Pill,
    };
}
