// Окна приложения: одно окно на ключ, единое описание (WindowSpec) для всех окон,
// подписки на закрытие снимаются вместе с окном.

import AppKit
import SwiftUI

/// Как выглядит и из чего состоит окно.
@MainActor
struct WindowSpec {
    let key: String
    var title = ""
    var style: NSWindow.StyleMask = [.titled, .closable]
    /// Прозрачный заголовок только у окон со своей шапкой (мастер, окно звонка).
    /// У списков обычный заголовок, иначе прокручиваемое содержимое лезет под него.
    var transparentTitle = false
    var contentSize: NSSize?
    var toolbarStyle: NSWindow.ToolbarStyle?
    /// Имя для запоминания положения и размера.
    var autosaveName: String?
    var level: NSWindow.Level = .normal
    let content: () -> NSViewController

    /// SwiftUI-вид фиксированной ширины.
    static func hosting<V: View>(_ key: String, title: String = "", width: CGFloat, transparentTitle: Bool = true,
                                 level: NSWindow.Level = .normal, @ViewBuilder _ view: @escaping () -> V) -> WindowSpec {
        WindowSpec(key: key, title: title,
                   style: transparentTitle ? [.titled, .closable, .fullSizeContentView] : [.titled, .closable],
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

    /// Показать окно; если такое уже открыто, вывести его вперёд. `onClose` вызывается один раз при закрытии.
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
        // Окно ещё закрывается: политику меняем на следующем витке цикла.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                if self?.entries.isEmpty == true { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    /// Пока открыто окно, у Sozvon есть значок в Dock и в ⌘Tab: окно не потеряется за другими.
    private func activate() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
