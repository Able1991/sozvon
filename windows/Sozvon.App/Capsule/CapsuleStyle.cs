namespace Sozvon.App.Capsule;

/// <summary>
/// The capsule's geometry. Every value is a multiple of 4 DIP, so at 100, 125 and 150 % each edge is a whole pixel.
/// The inner radius follows the outer one minus the padding, so the rounding stays concentric.
/// </summary>
public sealed record CapsuleStyle(string Name, int Height, int Padding, int Radius)
{
    public const int Slot = 32;

    /// <summary>A full pill, like the Mac.</summary>
    public static readonly CapsuleStyle Pill = new("pill", 48, 8, 24);

    /// <summary>Windows 11 rounding: a 12 DIP card with 4 DIP buttons inside.</summary>
    public static readonly CapsuleStyle Rounded = new("rounded", 48, 8, 12);

    /// <summary>A lower pill that takes less of the screen.</summary>
    public static readonly CapsuleStyle Compact = new("compact", 40, 4, 20);

    public int InnerRadius => Math.Max(4, Radius - Padding);

    public static CapsuleStyle Named(string? name) => name switch
    {
        "rounded" => Rounded,
        "compact" => Compact,
        _ => Pill,
    };
}
