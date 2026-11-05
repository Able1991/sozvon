// Точка входа: приложение в строке меню без значка в Dock (значок появляется, пока открыто окно).

import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
