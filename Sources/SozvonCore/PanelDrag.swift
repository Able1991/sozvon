// The floating capsule: a press that moves more than a few points is a window drag, not a click.
import CoreGraphics

public enum PanelDrag {
    /// Points the mouse may move between press and release and still count as a click.
    public static let threshold: CGFloat = 3

    /// The mouse (or the window) moved past the threshold since the press. Screen coordinates.
    public static func moved(_ a: CGPoint?, _ b: CGPoint?) -> Bool {
        guard let a, let b else { return false }
        return abs(a.x - b.x) > threshold || abs(a.y - b.y) > threshold
    }
}
