// App windows: one window per key, a single description (WindowSpec) for every window,
// close observers are removed together with the window.

import AppKit
import SwiftUI

/// What a window looks like and what it contains.
@MainActor
struct WindowSpec {
    let key: String
    var title = ""
    var style: NSWindow.StyleMask = [.titled, .closable]
    /// Transparent title bar only for windows with their own header (setup assistant, call window).
    /// Lists get a regular title bar, otherwise scrolling content slides under it.
    var transparentTitle = false
    var contentSize: NSSize?
    var toolbarStyle: NSWindow.ToolbarStyle?
    /// Autosave name for position and size.
    var autosaveName: String?
    var level: NSWindow.Level = .normal
    let content: () -> NSViewController

    /// Fixed-width SwiftUI view.
    static func hosting<V: View>(_ key: String, title: String = "", width: CGFloat, transparentTitle: Bool = true,
                                 resizable: Bool = false, level: NSWindow.Level = .normal,
                                 @ViewBuilder _ view: @escaping () -> V) -> WindowSpec {
        var style: NSWindow.StyleMask = transparentTitle ? [.titled, .closable, .fullSizeContentView] : [.titled, .closable]
        if resizable { style.insert(.resizable) }
        return WindowSpec(key: key, title: title, style: style,
                   transparentTitle: transparentTitle, level: level,
                   content: { NSHostingController(rootView: view().frame(width: width)) })
    }
}

@MainActor
final class WindowsRegistry {
    static let shared = WindowsRegistry()

    private struct Entry {
        let window: NSWindow
        let observer: NSObjectProtocol
        let onClose: (() -> Void)?
    }

    private var entries: [String: Entry] = [:]

    func window(_ key: String) -> NSWindow? { entries[key]?.window }
    var isEmpty: Bool { entries.isEmpty }

    /// Show the window; if one is already open, bring it to front. `onClose` is called once on close.
    @discardableResult
    func show(_ spec: WindowSpec, onClose: (() -> Void)? = nil) -> NSWindow {
        if let w = entries[spec.key]?.window {
            activate()
            w.makeKeyAndOrderFront(nil)
            return w
        }
        let w = NSWindow(contentViewController: spec.content())
        w.title = spec.title
        w.styleMask = spec.style
        w.titlebarAppearsTransparent = spec.transparentTitle
        if let t = spec.toolbarStyle { w.toolbarStyle = t }
        if let s = spec.contentSize { w.setContentSize(s) }
        w.isReleasedWhenClosed = false
        w.level = spec.level
        if let name = spec.autosaveName {
            w.setFrameAutosaveName(name)
            if !w.setFrameUsingName(name) { w.center() }
        } else {
            w.center()
            // SwiftUI gives the window its real size only after the first layout passes; centered before
            // that (still tiny) it ends up off center. Center again on each resize in the first second,
            // before anyone could have moved it.
            RecenterWhileSizing.watch(w)
        }
        let key = spec.key
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w,
                                                              queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closed(key) }
        }
        entries[key] = Entry(window: w, observer: observer, onClose: onClose)
        activate()
        w.makeKeyAndOrderFront(nil)
        return w
    }

    func close(_ key: String) { entries[key]?.window.close() }

    private func closed(_ key: String) {
        guard let e = entries.removeValue(forKey: key) else { return }
        NotificationCenter.default.removeObserver(e.observer)
        e.onClose?()
        // The window is still closing: change the activation policy on the next run loop pass.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                if self?.entries.isEmpty == true { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    /// While a window is open, Sozvon has a Dock icon and shows
    /// up in ⌘Tab, so the window doesn't get lost behind others.
    private func activate() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Keeps a newly opened window centered while SwiftUI settles its size (the first second).
@MainActor
private final class RecenterWhileSizing {
    private static var active: [ObjectIdentifier: RecenterWhileSizing] = [:]
    private var token: NSObjectProtocol?

    static func watch(_ w: NSWindow) {
        let r = RecenterWhileSizing()
        let id = ObjectIdentifier(w)
        active[id] = r
        r.token = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: w,
                                                         queue: .main) { [weak w] _ in
            MainActor.assumeIsolated { w?.center() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                if let t = active.removeValue(forKey: id)?.token { NotificationCenter.default.removeObserver(t) }
            }
        }
    }
}
