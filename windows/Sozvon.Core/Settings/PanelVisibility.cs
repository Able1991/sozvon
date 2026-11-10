namespace Sozvon.Core.Settings;

/// <summary>
/// When the capsule is on screen, the Mac's rule (FloatingPanel.sync): a countdown to an automatic start or stop always
/// shows, even with the panel turned off, so it never happens unseen; otherwise only with the panel on, and at rest only
/// with "Show the panel when not recording".
/// </summary>
public static class PanelVisibility
{
    /// <param name="active">Anything but rest: starting, recording, saved, transcribing, or a call prompt.</param>
    /// <param name="counting">A countdown to an automatic start or stop is running.</param>
    /// <param name="panelOn">"Floating panel" (the capsule's own hide button turns it off).</param>
    /// <param name="whenIdle">"Show the panel when not recording".</param>
    public static bool Shows(bool active, bool counting, bool panelOn, bool whenIdle) =>
        counting || (panelOn && (active || whenIdle));
}
