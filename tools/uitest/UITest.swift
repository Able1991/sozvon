// UI click test: drives a copy of the preview build (own bundle id, demo data in a temp folder) with real
// mouse clicks and checks every control of every screen: the click reaches it (nothing on top), toggles toggle,
// popups open and change their value, text fields take typing, buttons that open a sheet or window ("…")
// open it, and the opened sheet is checked the same way. Run with tools/uitest.sh; needs Accessibility access
// for the terminal. It moves the pointer and brings windows to the front while it runs.
import AppKit
import ApplicationServices

// MARK: - AX helpers

func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}
func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func str(_ e: AXUIElement, _ a: String) -> String { (attr(e, a) as? String) ?? "" }
func role(_ e: AXUIElement) -> String { str(e, kAXRoleAttribute) }
func value(_ e: AXUIElement) -> String {
    guard let v = attr(e, kAXValueAttribute) else { return "" }
    return (v as? String) ?? (v as? NSNumber)?.stringValue ?? "\(v)"
}
func name(_ e: AXUIElement) -> String {
    if let n = [str(e, kAXTitleAttribute), str(e, kAXDescriptionAttribute)].first(where: { !$0.isEmpty }) { return n }
    // System form rows name their switch or pop-up through a linked label (VoiceOver reads it there).
    if let t = attr(e, kAXTitleUIElementAttribute) {
        let l = t as! AXUIElement
        return [str(l, kAXValueAttribute), str(l, kAXTitleAttribute), str(l, kAXDescriptionAttribute)].first { !$0.isEmpty } ?? ""
    }
    return ""
}
func enabled(_ e: AXUIElement) -> Bool { (attr(e, kAXEnabledAttribute) as? Bool) ?? true }
func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt)
    AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}
func parent(_ e: AXUIElement) -> AXUIElement? { attr(e, kAXParentAttribute).map { $0 as! AXUIElement } }
func descendants(_ e: AXUIElement, depth: Int = 0, into out: inout [AXUIElement]) {
    out.append(e)
    guard depth < 40 else { return }
    for k in kids(e) { descendants(k, depth: depth + 1, into: &out) }
}
func all(_ e: AXUIElement) -> [AXUIElement] { var out: [AXUIElement] = []; descendants(e, into: &out); return out }
func isAncestor(_ a: AXUIElement, of e: AXUIElement) -> Bool {
    var x: AXUIElement? = e
    var n = 0
    while let y = x, n < 60 { if CFEqual(y, a) { return true }; x = parent(y); n += 1 }
    return false
}
func wait(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

// MARK: - Input

func click(_ p: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(40_000)
    for t in [CGEventType.leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(50_000)
    }
}
func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
        usleep(30_000)
    }
}
func type(_ s: String) {
    for ch in s.utf16 {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
            var c = ch
            e?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
            e?.post(tap: .cghidEventTap)
            usleep(20_000)
        }
    }
}
let escape: CGKeyCode = 53, backspace: CGKeyCode = 51

// MARK: - App under test

final class TestApp {
    let bundle: URL, data: URL
    var pid: pid_t = 0
    var ax: AXUIElement { AXUIElementCreateApplication(pid) }

    init(bundle: URL, data: URL) { self.bundle = bundle; self.data = data }

    func launch(_ args: [String]) {
        quit()
        // Through LaunchServices (open -n), not as a child of the terminal: a permission prompt then names
        // the test app, never the terminal.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", "-g", bundle.path, "--args", "-engineDir", data.appendingPathComponent("engine").path,
                       "-callsDir", data.appendingPathComponent("Calls").path, "-AppleLanguages", "(ru)"] + args
        try! p.run(); p.waitUntilExit()
        for _ in 0..<40 {
            wait(0.25)
            if let a = NSRunningApplication.runningApplications(withBundleIdentifier: "io.github.able1991.sozvon.uitest").first {
                pid = a.processIdentifier; break
            }
        }
        for _ in 0..<40 { wait(0.25); if !windows().isEmpty { break } }
        wait(1.0)
        activate()
        baseline = all(ax).filter { role($0) == "AXMenu" }
        // A window past the screen's visible area (small CI screens): move it inside, at the top.
        if let main = NSScreen.screens.first {
            let v = main.visibleFrame
            let top = main.frame.maxY - v.maxY
            for w in windows() {
                guard let f = frame(w), f.maxY > top + v.height || f.minY < top || f.maxX > v.maxX || f.minX < v.minX else { continue }
                var p = CGPoint(x: max(v.minX, min(f.minX, v.maxX - f.width)), y: top)
                AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!)
            }
            wait(0.3)
        }
    }
    func activate() {
        NSRunningApplication(processIdentifier: pid)?.activate()
        wait(0.3)
    }
    func quit() {
        // A normal quit first: a recording the test may have started is stopped (its microphone released).
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "io.github.able1991.sozvon.uitest")
        apps.forEach { $0.terminate() }
        for _ in 0..<30 where apps.contains(where: { !$0.isTerminated }) { wait(0.1) }
        apps.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        wait(0.6)
        pid = 0
    }
    /// Menus that exist while nothing is open (the status item's): never taken for an opened popup.
    var baseline: [AXUIElement] = []
    func windows() -> [AXUIElement] { (attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? [] }
    /// Popup menus that are open (not the menu bar's).
    func openMenu() -> AXUIElement? {
        all(ax).first { m in
            guard role(m) == "AXMenu", !kids(m).isEmpty, !baseline.contains(where: { CFEqual($0, m) }) else { return false }
            guard let f = frame(m), f.width > 0, f.height > 0 else { return false }
            var x = parent(m)
            while let y = x { if role(y) == "AXMenuBar" { return false }; x = parent(y) }
            return true
        }
    }
}

// MARK: - Checks

struct Failure { let screen: String; let control: String; let problem: String }
var failures: [Failure] = []
var checked = 0
var coverage: [String] = []
var screen = ""
let shots = URL(fileURLWithPath: CommandLine.arguments[3])

func fail(_ control: String, _ problem: String) {
    failures.append(Failure(screen: screen, control: control, problem: problem))
    let safe = String((screen + "-" + control).map { $0.isLetter || $0.isNumber || " -·".contains($0) ? $0 : "_" }.prefix(80))
    let f = shots.appendingPathComponent("\(safe).png").path
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", f]
    try? p.run(); p.waitUntilExit()
    print("  FAIL \(control): \(problem)")
}

let actionable: Set<String> = ["AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXTextField", "AXTextArea",
                               "AXRadioButton", "AXSlider", "AXLink", "AXComboBox"]
/// Buttons that leave the app (browser, Finder, Terminal) or end it: hit-tested, never clicked.
let external = ["Finder", "Подключ", "Connect", "Claude", "ChatGPT", "Codex", "Cursor", "Терминал", "Terminal", "Выйти", "Quit",
                "браузер", "Перезапустить", "Relaunch", "Cloudflare", "Открыть сайт", "GitHub", "Системные настройки",
                "Скачать модель", "Переустановить", "Установить", "Повторить", "Записать", "Обновить сервер",
                "Проверить", "Сохранить архив", "Save Archive", "Синхронизировать", "Импорт", "Выбрать папку", "Choose Folder", "Сменить папку", "Change Folder",
                "Показать логи", "Show Logs",
                // Asks in place inside the trim panel (no sheet): trimBoardTest and trimInCallsTest click it.
                "Обрезать…", "Trim…",
                "Запись одним нажатием", "Record in one tap"]
/// Toggles that ask macOS for a permission (Calendar, Reminders, notifications): hit-tested, never switched.
let permissionToggles = ["Календар", "Calendar", "Напоминан", "Reminders", "уведомлен"]
/// Menu items never picked by the popup check.
let unsafeItem = ["Удал", "Delete", "Корзин", "Trash", "…", "Выйти", "Расшифровать заново", "Переимен"]

/// The control is on screen inside its window: scroll it into view first.
func reveal(_ e: AXUIElement, in w: AXUIElement) -> CGRect? {
    // The part of the window on screen (AX coordinates: top-left origin of the main screen).
    func visible() -> CGRect? {
        guard let wf = frame(w), let main = NSScreen.screens.first else { return nil }
        let s = main.visibleFrame
        let screen = CGRect(x: s.minX, y: main.frame.maxY - s.maxY, width: s.width, height: s.height)
        var v = wf.intersection(screen)
        // Clip to the enclosing scroll view, if any.
        var x = parent(e)
        while let y = x { if role(y) == "AXScrollArea", let sf = frame(y) { v = v.intersection(sf); break }; x = parent(y) }
        return v.insetBy(dx: 1, dy: 0)  // a center on the last visible row still takes a click (reachable checks it)
    }
    AXUIElementPerformAction(e, "AXScrollToVisible" as CFString)
    wait(0.15)
    for _ in 0..<30 {
        guard let f = frame(e), let v = visible(), f.width > 1, f.height > 1 else { return nil }
        let c = CGPoint(x: f.midX, y: f.midY)
        if v.contains(c) { return f }
        guard v.height > 20 else { return nil }
        // Scroll the content toward the control with the wheel over the visible area.
        let down = c.y > v.maxY
        let at = CGPoint(x: v.midX, y: v.midY)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: at, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: down ? -120 : 120, wheel2: 0, wheel3: 0)?
            .post(tap: .cghidEventTap)
        wait(0.25)
        // The wheel didn't move it (a system Form on some macOS versions): move the scroll bar instead.
        if let after = frame(e), abs(after.midY - f.midY) < 1 { nudgeScrollBar(of: e, down: down) }
    }
    return nil
}

/// Move the vertical scroll bar of the control's scroll area a tenth of the way.
func nudgeScrollBar(of e: AXUIElement, down: Bool) {
    var x = parent(e)
    while let y = x, role(y) != "AXScrollArea" { x = parent(y) }
    guard let area = x, let bar = attr(area, kAXVerticalScrollBarAttribute) else { return }
    let b = bar as! AXUIElement
    let v = (attr(b, kAXValueAttribute) as? NSNumber)?.doubleValue ?? 0
    let next = min(1, max(0, v + (down ? 0.1 : -0.1)))
    AXUIElementSetAttributeValue(b, kAXValueAttribute as CFString, NSNumber(value: next))
    wait(0.25)
}

/// What a real click at the control's center lands on is the control (or inside it).
func reachable(_ e: AXUIElement, at f: CGRect) -> Bool {
    let c = CGPoint(x: f.midX, y: f.midY)
    var hit: AXUIElement?
    AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(c.x), Float(c.y), &hit)
    guard let h = hit else { return false }
    // AX sometimes answers with a second element for the same control.
    if role(h) == role(e), !name(e).isEmpty, name(h) == name(e) { return true }
    // The control or something inside it; or a container of it (AX on some macOS versions answers with the
    // toolbar or group rather than the leaf). Anything else (another view, sheet or window) is on top of it.
    return isAncestor(e, of: h) || isAncestor(h, of: e)
}

func label(_ e: AXUIElement) -> String {
    let n = name(e)
    return "\(role(e).replacingOccurrences(of: "AX", with: "")) «\(n.isEmpty ? "?" : n)»"
}

/// Check every control of the window; explore sheets opened by "…" buttons (depth 1).
func sweep(_ app: TestApp, window w: AXUIElement, depth: Int = 0, seen: inout Set<String>) {
    // The tree is read again before each control: a click may change the window (a filter, a tab).
    func ids() -> [(String, AXUIElement)] {
        var count: [String: Int] = [:]
        return all(w).filter { actionable.contains(role($0)) }.map { e in
            let base = "\(role(e))|\(name(e))|\(depth)"
            count[base, default: 0] += 1
            return ("\(base)#\(count[base]!)", e)
        }
    }
    while let (id, e) = ids().first(where: { !seen.contains($0.0) }) {
        seen.insert(id)
        let n = name(e), r = role(e)
        if r.isEmpty { continue }
        // The window's own traffic lights.
        if ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"].contains(str(e, kAXSubroleAttribute)) { continue }
        // Scroll bar arrows and pages.
        if parent(e).map({ role($0) == "AXScrollBar" }) ?? false { continue }
        guard enabled(e) else { continue }
        app.activate()
        // Someone else's window came to the front (the Mac is in use): wait until ours is back.
        for _ in 0..<20 where NSWorkspace.shared.frontmostApplication?.processIdentifier != app.pid {
            app.activate(); wait(0.5)
        }
        guard let f = reveal(e, in: w) else {
            if let f = frame(e), f.width > 1, f.height > 1 {
                var sa = "", x = parent(e)
                while let y = x { if role(y) == "AXScrollArea" { sa = "\(frame(y) ?? .zero)"; break }; x = parent(y) }
                fail(label(e), "can't scroll it into view (at \(Int(f.midX)),\(Int(f.midY)); window \(frame(w) ?? .zero); scroll area \(sa); screen \(NSScreen.screens.first?.visibleFrame ?? .zero))")
            }
            continue
        }
        checked += 1
        coverage.append("\(screen): \(label(e))")
        var ok = reachable(e, at: f)
        for _ in 0..<3 where !ok {
            // Retry after bringing our window forward: a transient overlay (another app, a fading menu).
            app.activate(); AXUIElementPerformAction(w, kAXRaiseAction as CFString); wait(0.6)
            ok = reachable(e, at: f)
        }
        // The element went away meanwhile (the window changed): nothing to check.
        if !ok && role(e).isEmpty { continue }
        if !ok {
            // AX can't tell: click for real and see whether anything happens (a menu, a sheet, a change).
            func signature() -> String { all(w).map { "\(role($0))|\(name($0))|\(value($0))" }.joined(separator: "\n") }
            let before = signature(), windowsBefore = app.windows().count
            click(CGPoint(x: f.midX, y: f.midY)); wait(1.0)
            if (attr(e, kAXSelectedAttribute) as? Bool) == true || value(e) == "1" { ok = true }  // the selected tab
            else if app.openMenu() != nil { ok = true; key(escape); wait(0.4) }
            else if app.windows().count != windowsBefore || all(w).contains(where: { role($0) == "AXSheet" }) {
                ok = true; key(escape); wait(0.6)
            } else if signature() != before || role(e).isEmpty { ok = true }
            if ok { print("    \(label(e)): AX hit test unsure, the real click works"); continue }
        }
        if !ok {
            var hit: AXUIElement?
            AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(f.midX), Float(f.midY), &hit)
            let near = parent(e).map { name($0) + " " + role($0) } ?? ""
            fail(label(e), "the click doesn't reach it: \(hit.map { label($0) } ?? "nothing") is on top (at \(Int(f.midX)),\(Int(f.midY)), in \(near))")
            continue
        }
        if n.isEmpty && r != "AXTextField" && r != "AXTextArea" {
            fail(label(e), "no accessibility label (VoiceOver can't name it)")
        }
        switch r {
        case "AXCheckBox":
            if permissionToggles.contains(where: { n.contains($0) }) { continue }
            let before = value(e)
            click(CGPoint(x: f.midX, y: f.midY)); wait(0.5)
            let after = value(e)
            if after == before { fail(label(e), "click doesn't toggle it (stays \(before))") }
            else {
                click(CGPoint(x: f.midX, y: f.midY)); wait(0.5)
                // "Detect automatically" is the choice left when no language is picked: it can't be unchecked.
                let required = ["Определять сам", "Detect automatically"].contains(n)
                if value(e) != before && !required { fail(label(e), "second click doesn't toggle it back") }
            }
        case "AXMenuButton", "AXPopUpButton":
            let before = value(e)
            click(CGPoint(x: f.midX, y: f.midY)); wait(0.7)
            guard let m = app.openMenu() else {
                // A button with a menu whose click runs its main action (opens a sheet) works too.
                if let sheet = all(w).first(where: { role($0) == "AXSheet" }) { close(app, sheet); continue }
                fail(label(e), "click doesn't open its menu"); continue
            }
            let items = kids(m).filter { !name($0).isEmpty && enabled($0) }
            if items.isEmpty { fail(label(e), "menu has no enabled items") }
            let pick = before.isEmpty ? nil : items.first { i in
                let t = name(i)
                return t != before && !before.hasPrefix(t) && !unsafeItem.contains { t.contains($0) }
            }
            if let pick, let pf = frame(pick) {
                let title = name(pick)
                click(CGPoint(x: pf.midX, y: pf.midY)); wait(0.8)
                if app.openMenu() != nil { key(escape); wait(0.3) }
                let after = value(e)
                if after == before { fail(label(e), "picking «\(title)» doesn't change it (stays «\(before)»)") }
                else if let f2 = frame(e) {
                    // Put the old value back.
                    click(CGPoint(x: f2.midX, y: f2.midY)); wait(0.7)
                    if let m2 = app.openMenu() {
                        let back = kids(m2).first { name($0) == before } ?? kids(m2).first { name($0) == title }
                        if let b = back, let bf = frame(b) { click(CGPoint(x: bf.midX, y: bf.midY)); wait(0.6) }
                        if app.openMenu() != nil { key(escape); wait(0.3) }
                    }
                }
            } else {
                key(escape); wait(0.4)
            }
        case "AXTextField", "AXTextArea":
            if str(e, kAXSubroleAttribute) == "AXSecureTextField" { continue }
            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(e, kAXValueAttribute as CFString, &settable)
            if !settable.boolValue { continue }  // read-only text (selectable, not typed into)
            click(CGPoint(x: f.midX, y: f.midY)); wait(0.3)
            let before = value(e)
            type("ж"); wait(0.3)
            let after = value(e)
            if after == before { fail(label(e), "typing doesn't reach it") }
            key(backspace); wait(0.3)
            if value(e) != before { fail(label(e), "backspace doesn't restore it") }
            key(escape); wait(0.2)
        case "AXButton":
            if n.hasSuffix("…") || n.hasSuffix("...") { print("    button \(n)") }
            guard depth == 0, n.hasSuffix("…"), !external.contains(where: { n.contains($0) }) else { continue }
            let wins = app.windows().count
            let sheetsBefore = all(w).filter { role($0) == "AXSheet" }.count
            click(CGPoint(x: f.midX, y: f.midY)); wait(1.2)
            let sheet = all(w).first { role($0) == "AXSheet" }
            let newWindow = app.windows().count > wins ? app.windows().first : nil
            let menu = app.openMenu()
            if let menu { print("    \(n) opened a menu: \(kids(menu).map(name))"); key(escape); wait(0.4); continue }
            guard let target = (all(w).filter { role($0) == "AXSheet" }.count > sheetsBefore ? sheet : nil) ?? newWindow else {
                fail(label(e), "click opens nothing (no sheet, window or menu)"); continue
            }
            print("  → \(n)")
            sweep(app, window: target, depth: depth + 1, seen: &seen)
            close(app, target)
        default:
            break
        }
    }
}

/// Close a sheet or window: Cancel/Done/Close button, else Escape, else its close button.
func close(_ app: TestApp, _ t: AXUIElement) {
    app.activate()
    key(escape); wait(0.6)
    guard !kids(t).isEmpty, frame(t) != nil else { return }
    for n in ["Отмена", "Готово", "Закрыть", "Не сейчас", "Cancel", "Done", "Close"] {
        if let b = all(t).first(where: { role($0) == "AXButton" && name($0) == n }), let f = frame(b) {
            click(CGPoint(x: f.midX, y: f.midY)); wait(0.6); return
        }
    }
    if let c = attr(t, kAXCloseButtonAttribute) { AXUIElementPerformAction(c as! AXUIElement, kAXPressAction as CFString); wait(0.5) }
}

/// Click the control named `n` in the front window (a step of a scenario before the sweep).
func step(_ app: TestApp, _ n: String) -> Bool {
    app.activate()
    let found = app.windows().lazy.compactMap { w in
        all(w).first(where: { actionable.contains(role($0)) && name($0) == n && enabled($0) }).map { (w, $0) }
    }.first
    guard let (w, e) = found, let f = reveal(e, in: w) else { fail("step «\(n)»", "control not found or not visible"); return false }
    click(CGPoint(x: f.midX, y: f.midY)); wait(1.2)
    return true
}

func run(_ app: TestApp, _ title: String, _ args: [String], steps: [String] = []) {
    screen = title
    print("• \(title)")
    app.launch(args)
    for s in steps { guard step(app, s) else { return } }
    // The screen's window, not the floating capsule: the largest one.
    func area(_ w: AXUIElement) -> CGFloat {
        guard let f = frame(w) else { return 0 }
        return f.width * f.height
    }
    let ws = app.windows().sorted { area($0) > area($1) }
    // After a step that opens a sheet, sweep the sheet.
    guard let top = ws.first else { fail("window", "no window opened"); return }
    let w = steps.isEmpty ? top : (all(top).first { role($0) == "AXSheet" } ?? top)
    var seen = Set<String>()
    sweep(app, window: w, seen: &seen)
}

/// A screenshot of the app's largest window (no shadow), kept next to the failure shots.
func windowShot(_ pid: pid_t, _ label: String) -> NSBitmapImageRep? {
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid }
    func h(_ w: [String: Any]) -> CGFloat { (w[kCGWindowBounds as String] as? [String: CGFloat])?["Height"] ?? 0 }
    guard let id = mine.max(by: { h($0) < h($1) })?[kCGWindowNumber as String] as? Int else { return nil }
    let f = shots.appendingPathComponent(label.map { $0.isLetter || $0.isNumber ? $0 : "-" } + ".png")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l\(id)", f.path]
    try? p.run(); p.waitUntilExit()
    return (try? Data(contentsOf: f)).flatMap { NSBitmapImageRep(data: $0) }
}
/// Mean per-channel difference (0...255) of two same-size screenshots over a band of rows (fractions of the height).
func meanDiff(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, fromTop: CGFloat, to: CGFloat) -> Double {
    guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return 255 }
    var sum = 0.0, n = 0.0
    for y in stride(from: Int(CGFloat(a.pixelsHigh) * fromTop), to: Int(CGFloat(a.pixelsHigh) * to), by: 2) {
        for x in stride(from: 0, to: a.pixelsWide, by: 4) {
            guard let c = a.colorAt(x: x, y: y), let d = b.colorAt(x: x, y: y) else { continue }
            sum += (abs(c.redComponent - d.redComponent) + abs(c.greenComponent - d.greenComponent)
                    + abs(c.blueComponent - d.blueComponent)) / 3 * 255
            n += 1
        }
    }
    return n > 0 ? sum / n : 0
}

/// Switch the Settings tabs back and forth, fast and slow, and check that each pane comes back the same:
/// the window height and where its first control sits. A pane that picked up the toolbar as a top inset
/// during the resize animation showed a blurred band over its first section and grew the window.
func settingsTabSwitching(_ app: TestApp) {
    screen = "Настройки · переключение вкладок"
    print("• \(screen)")
    // First visit of each tab in a fresh app, then a second one: the pane must look the same. On macOS 26
    // the crossfade left a scroll edge band (the toolbar's height) over the top of a pane on its first visit.
    for t in ["Распознавание", "Ассистенты", "Облако"] {
        app.launch(["--preview", "settings", "--tab", "0"])
        guard let w1 = app.windows().first else { fail("tab «\(t)»", "no window opened"); continue }
        func go(_ to: String) -> Bool {
            guard let b = all(w1).first(where: { e in
                name(e) == to && ["AXButton", "AXRadioButton", "AXCheckBox"].contains(role(e))
                    && sequence(first: e, next: parent).contains { role($0) == "AXToolbar" }
            }), let f = frame(b) else { fail("tab «\(to)»", "toolbar tab not found"); return false }
            click(CGPoint(x: f.midX, y: f.midY)); wait(1.5); return true
        }
        guard go(t) else { continue }
        guard let first = windowShot(app.pid, "first visit \(t)") else { fail("tab «\(t)»", "no screenshot of the window"); continue }
        guard go("Основные"), go(t) else { continue }
        guard let again = windowShot(app.pid, "second visit \(t)") else { fail("tab «\(t)»", "no screenshot of the window"); continue }
        checked += 1
        // The band sits right under the toolbar: compare that strip.
        let d = meanDiff(first, again, fromTop: 0.12, to: 0.35)
        print("  «\(t)»: first and second visit differ by \(String(format: "%.1f", d)) under the toolbar")
        if d > 2 { fail("tab «\(t)»", "the first visit looks different under the toolbar (a band over the first section)") }
    }
    app.launch(["--preview", "settings", "--tab", "0"])
    guard let w = app.windows().first else { fail("window", "no window opened"); return }
    let tabs = ["Основные", "Распознавание", "Ассистенты", "Облако"]
    func tabButton(_ t: String) -> AXUIElement? {
        all(w).first { e in
            name(e) == t && ["AXButton", "AXRadioButton", "AXCheckBox"].contains(role(e))
                && sequence(first: e, next: parent).contains { role($0) == "AXToolbar" }
        }
    }
    /// Window height and the first control's distance from the top of the pane's scroll area.
    func layout() -> (CGFloat, CGFloat)? {
        guard let wf = frame(w), let area = all(w).first(where: { role($0) == "AXScrollArea" }), let af = frame(area)
        else { return nil }
        let tops = all(area).filter { actionable.contains(role($0)) }.compactMap { frame($0)?.minY }
        guard let first = tops.min() else { return nil }
        return (wf.height, first - af.minY)
    }
    var expected: [String: (CGFloat, CGFloat)] = [:]
    let round = tabs + tabs.reversed() + ["Основные", "Облако", "Распознавание", "Ассистенты", "Основные", "Ассистенты"]
    let order = Array(repeating: round, count: 4).flatMap { $0 }
    // Most switches land mid-animation of the previous one, at different points of it: the bug is a race.
    let pauses: [Double] = [1.0, 0.08, 0.15, 0.3, 0.04, 0.2]
    for (i, t) in order.enumerated() {
        guard let b = tabButton(t), let f = frame(b) else { fail("tab «\(t)»", "toolbar tab not found"); return }
        click(CGPoint(x: f.midX, y: f.midY))
        let pause = pauses[i % pauses.count]
        wait(pause)
        if pause < 1 { continue }
        checked += 1
        guard let now = layout() else { fail("tab «\(t)»", "pane has no controls"); continue }
        if let was = expected[t] {
            if abs(was.0 - now.0) > 4 || abs(was.1 - now.1) > 4 {
                fail("tab «\(t)»", "layout drifted after switching: window height \(Int(was.0)) → \(Int(now.0)), first control \(Int(was.1)) → \(Int(now.1)) from the top")
            }
        } else {
            expected[t] = now
        }
    }
}

/// The idle capsule: a pointing hand anywhere on it, and a drag that starts on "Record" moves it (and doesn't
/// start a recording). The label used to be a Button, which kept the mouse to itself.
func capsuleDrag(_ app: TestApp) {
    screen = "Капсула · перетаскивание"
    print("• \(screen)")
    app.launch(["--preview", "panel-idle"])
    wait(1.5)
    // The capsule is a non-activating panel, not in the app's accessibility windows: find it on screen.
    func capsule() -> CGRect? {
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        return list.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == app.pid }
            .compactMap { w -> CGRect? in
                guard let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
                return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            }
            .first { $0.height >= 36 && $0.height <= 60 && $0.width >= 80 && $0.width <= 400 }
    }
    let calls = app.data.appendingPathComponent("Calls")
    func recordings() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: calls.path).count) ?? 0 }
    guard let wf = capsule() else { fail("capsule", "no idle capsule on screen"); return }
    let before = recordings()
    // On the word «Записать» (right part of the capsule), not the ring.
    let start = CGPoint(x: wf.minX + wf.width * 0.62, y: wf.midY)
    for dx in [0.0, 2, 4] {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: start.x - dx, y: start.y),
                mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(80_000)
    }
    wait(0.3)
    checked += 1
    if let c = NSCursor.currentSystem, c.hotSpot != NSCursor.pointingHand.hotSpot || c.image.size != NSCursor.pointingHand.image.size {
        fail("cursor", "not a pointing hand over «Записать» (hot spot \(c.hotSpot), size \(c.image.size))")
    }
    let move = CGVector(dx: -160, dy: 90)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(60_000)
    for i in 1...20 {
        let t = CGFloat(i) / 20
        let p = CGPoint(x: start.x + move.dx * t, y: start.y + move.dy * t)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(16_000)
    }
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
            mouseCursorPosition: CGPoint(x: start.x + move.dx, y: start.y + move.dy), mouseButton: .left)?.post(tap: .cghidEventTap)
    wait(1.5)
    checked += 2
    if recordings() != before { fail("drag", "dragging the capsule by «Записать» started a recording") }
    guard let nf = capsule() else { fail("drag", "the capsule is gone after the drag"); return }
    if abs(nf.minX - wf.minX - move.dx) > 12 || abs(nf.minY - wf.minY - move.dy) > 12 {
        fail("drag", "the capsule moved by \(Int(nf.minX - wf.minX)), \(Int(nf.minY - wf.minY)) instead of \(Int(move.dx)), \(Int(move.dy))")
    }
}

// MARK: - Trim, silence hint, time estimate, quiet icon, disk warnings

/// The app's largest window: the screen's own, not the capsule.
func mainWindow(_ app: TestApp) -> AXUIElement? {
    func area(_ w: AXUIElement) -> CGFloat { frame(w).map { $0.width * $0.height } ?? 0 }
    return app.windows().max { area($0) < area($1) }
}
/// The first element under `root` whose name starts with `prefix` (of the role, when given).
func firstNamed(_ root: AXUIElement, _ prefix: String, role r: String? = nil) -> AXUIElement? {
    all(root).first { e in (r == nil || role(e) == r) && name(e).hasPrefix(prefix) }
}
/// A button under `root` named exactly `n`.
func button(_ root: AXUIElement, _ n: String) -> AXUIElement? {
    all(root).first { role($0) == "AXButton" && name($0) == n }
}
/// Any text under `root` (a value or a name) that contains `part`.
func textContaining(_ root: AXUIElement, _ part: String) -> String? {
    for e in all(root) { for s in [value(e), name(e)] where s.contains(part) { return s } }
    return nil
}
/// A real click at the element's center, after scrolling it into view.
@discardableResult func press(_ app: TestApp, _ w: AXUIElement, _ e: AXUIElement) -> Bool {
    app.activate()
    guard let f = reveal(e, in: w) else { return false }
    click(CGPoint(x: f.midX, y: f.midY))
    return true
}
/// A real click at the center of a control pinned over the scrolling content (the trim panel at the bottom of the
/// card): no AXScrollToVisible and no wheel, which only scroll the content under it. False, with the frames in the
/// log, when the control is not inside the window.
@discardableResult func pressPinned(_ app: TestApp, _ w: AXUIElement, _ e: AXUIElement) -> Bool {
    app.activate()
    guard let f = frame(e), let wf = frame(w), wf.contains(CGPoint(x: f.midX, y: f.midY)) else {
        print("    note: «\(label(e))» at \(frame(e).map { "\($0)" } ?? "-") is outside the window \(frame(w).map { "\($0)" } ?? "-")")
        return false
    }
    click(CGPoint(x: f.midX, y: f.midY))
    return true
}
/// Waits up to `limit` seconds for `done`; its last answer.
@discardableResult func waitFor(_ limit: Double, _ done: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(limit)
    while Date() < end { if done() { return true }; wait(0.1) }
    return done()
}

/// Seconds of a "6:12" or "1:05:20" at the end of a label ("Начало, 6:12").
func seconds(_ label: String) -> Int? {
    guard let t = label.split(separator: " ").last else { return nil }
    let parts = t.split(separator: ":").compactMap { Int($0) }
    guard parts.count >= 2 else { return nil }
    return parts.reduce(0) { $0 * 60 + $1 }
}
/// The card's "Ещё" menu: by its identifier ("call-more-menu" in CallDetail), else by name. The toolbar names it
/// "Еще" (without ё) on the CI runner, so both spellings count.
func moreMenu(_ w: AXUIElement) -> AXUIElement? {
    let items = all(w)
    if let e = items.first(where: { str($0, "AXIdentifier") == "call-more-menu" }) { return e }
    for n in ["Ещё", "Еще"] {
        if let e = items.first(where: { role($0) == "AXMenuButton" && name($0).hasPrefix(n) }) { return e }
    }
    return items.first { e in ["Ещё", "Еще"].contains { name(e).hasPrefix($0) } }
}
/// The card's "Ещё" menu opened, and its item `n` (nil, with a failure, when either is missing).
func moreMenuItem(_ app: TestApp, _ w: AXUIElement, _ n: String) -> AXUIElement? {
    guard let more = moreMenu(w) else {
        let menus = all(w).filter { role($0) == "AXMenuButton" }.map { "\(name($0))#\(str($0, "AXIdentifier"))" }
        fail("«Ещё»", "no «Ещё» menu in the card's toolbar; menu buttons: \(menus)"); return nil
    }
    press(app, w, more); wait(0.8)
    guard let m = app.openMenu() else { fail("«Ещё»", "click doesn't open its menu"); return nil }
    guard let item = kids(m).first(where: { name($0) == n }) else {
        fail("«Ещё»", "no «\(n)» in the menu: \(kids(m).map(name))"); key(escape); wait(0.4); return nil
    }
    return item
}
/// The trim panel (its group), or nil when it is closed.
func trimPanel(_ w: AXUIElement) -> AXUIElement? { firstNamed(w, "Обрезка записи") }
func trimHandle(_ w: AXUIElement, _ which: String) -> AXUIElement? { firstNamed(w, which + ", ") }
/// The player bar under the card: its controls, or the "can't be read" line in their place.
func playerShown(_ w: AXUIElement) -> Bool {
    button(w, "Назад на 15 секунд") != nil || textContaining(w, "Запись недоступна") != nil
}
let rightArrow: CGKeyCode = 124, leftArrow: CGKeyCode = 123
/// What a real arrow key carries.
let arrowFlags: CGEventFlags = [.maskNumericPad, .maskSecondaryFn]

/// Focus a handle with a click on its knob, as the user would, press an arrow, and check the handle and the
/// "6:12 → 58:40" times moved by exactly that much.
func nudgeHandle(_ app: TestApp, _ w: AXUIElement, _ which: String, _ code: CGKeyCode, shift: Bool) {
    checked += 1
    let step = (code == rightArrow ? 1 : -1) * (shift ? 10 : 1)
    let keyName = "\(shift ? "Shift+" : "")\(code == rightArrow ? "→" : "←")"
    guard let h = trimHandle(w, which), let f = frame(h) else { fail("handle «\(which)»", "not found"); return }
    let before = name(h), timesBefore = textContaining(w, "→") ?? ""
    app.activate()
    AXUIElementSetAttributeValue(h, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    click(CGPoint(x: f.midX, y: f.midY)); wait(0.4)
    key(code, flags: shift ? arrowFlags.union(.maskShift) : arrowFlags); wait(0.6)
    let after = trimHandle(w, which).map(name) ?? ""
    print("  \(which) \(keyName): «\(before)» → «\(after)»")
    guard let b = seconds(before), let a = seconds(after) else { fail("handle «\(which)»", "no time in its label «\(before)» / «\(after)»"); return }
    if a - b != step { fail("handle «\(which)»", "\(keyName) moved it from «\(before)» to «\(after)», not by \(step) s") }
    let timesAfter = textContaining(w, "→") ?? ""
    if timesAfter == timesBefore { fail("times", "«\(timesBefore)» didn't change after \(keyName) on «\(which)»") }
}

/// The panel's controls: both handles with their VoiceOver labels, the arrows, "Прослушать конец", and
/// "Обрезать…" with its in-panel confirmation, "Отмена" back to editing. `listenMustWork`: the player can play
/// (the preview board); in the Calls window the demo tracks may not decode on the runner.
func checkTrimPanel(_ app: TestApp, _ w: AXUIElement, listenMustWork: Bool) {
    checked += 2
    guard trimPanel(w) != nil else { fail("panel", "no «Обрезка записи» panel"); return }
    for which in ["Начало", "Конец"] {
        guard let h = trimHandle(w, which) else { fail("handle «\(which)»", "no handle with a VoiceOver label «\(which), m:ss»"); return }
        if seconds(name(h)) == nil { fail(label(h), "the VoiceOver label has no time") }
        if str(h, kAXHelpAttribute).isEmpty { print("    note: \(label(h)) has no AXHelp (the arrows hint)") }
    }
    nudgeHandle(app, w, "Начало", rightArrow, shift: false)
    nudgeHandle(app, w, "Начало", rightArrow, shift: true)
    nudgeHandle(app, w, "Конец", leftArrow, shift: false)

    checked += 1
    guard let p = trimPanel(w), let listen = firstNamed(p, "Прослушать конец") else { fail("«Прослушать конец»", "not in the panel"); return }
    let play = firstNamed(p, "Слушать с начала обрезки") ?? firstNamed(p, "Пауза")
    if listenMustWork, !enabled(listen) { fail(label(listen), "disabled") }
    if !listenMustWork, !enabled(listen) {
        if let play, enabled(play) { fail(label(listen), "disabled while play works") }
        else { print("    note: the demo tracks can't be read here, play and «Прослушать конец» are off") }
    }

    checked += 3
    guard let trim = button(p, "Обрезать…"), enabled(trim) else { fail("«Обрезать…»", "no enabled «Обрезать…» in the panel"); return }
    pressPinned(app, w, trim)
    waitFor(2) { trimPanel(w).flatMap { button($0, "Обрезать и расшифровать") } != nil }
    guard let p2 = trimPanel(w) else { fail("«Обрезать…»", "the panel closed instead of asking"); return }
    if button(p2, "Обрезать и расшифровать") == nil { fail("confirmation", "no «Обрезать и расшифровать»") }
    if textContaining(p2, "вернуть его нельзя") == nil { fail("confirmation", "no warning that the cut audio is gone for good") }
    guard let cancel = button(p2, "Отмена") else { fail("confirmation", "no «Отмена»"); return }
    pressPinned(app, w, cancel)
    waitFor(2) { trimPanel(w).flatMap { button($0, "Обрезать…") } != nil }
    guard let p3 = trimPanel(w) else { fail("confirmation «Отмена»", "closed the panel instead of going back to editing"); return }
    if button(p3, "Обрезать и расшифровать") != nil { fail("confirmation «Отмена»", "the confirmation is still shown") }
    if button(p3, "Обрезать…") == nil || trimHandle(w, "Начало") == nil { fail("confirmation «Отмена»", "not back to editing") }
}

/// The preview board: the handles where the board puts them, and every control of the panel.
func trimBoardTest(_ app: TestApp) {
    screen = "Обрезка · ручки и подтверждение"
    print("• \(screen)")
    app.launch(["--preview", "trim"])
    guard let w = mainWindow(app) else { fail("window", "no window opened"); return }
    checked += 1
    let s = trimHandle(w, "Начало").map(name), e = trimHandle(w, "Конец").map(name)
    if s != "Начало, 6:12" || e != "Конец, 58:40" { fail("handles", "labels «\(s ?? "-")», «\(e ?? "-")», not «Начало, 6:12», «Конец, 58:40»") }
    checkTrimPanel(app, w, listenMustWork: true)
}

/// The Calls window: "Ещё" > "Обрезать…" grows the player into the trim panel; "Отмена" and Escape give the
/// player back.
func trimInCallsTest(_ app: TestApp) {
    screen = "Обрезка · из меню «Ещё»"
    print("• \(screen)")
    app.launch(["--preview", "calls", "--size", callsSize])
    wait(0.8)
    guard let w = mainWindow(app) else { fail("window", "no window opened"); return }
    checked += 2
    if !playerShown(w) { fail("player", "no player bar under the card") }
    guard let item = moreMenuItem(app, w, "Обрезать…") else { return }
    guard enabled(item), let f = frame(item) else {
        fail("«Обрезать…»", "disabled on a call that can be trimmed (\(str(item, kAXHelpAttribute)))"); key(escape); return
    }
    click(CGPoint(x: f.midX, y: f.midY)); wait(1.2)
    guard trimPanel(w) != nil, trimHandle(w, "Начало").map(name) == "Начало, 0:00" else {
        fail("«Обрезать…»", "no trim panel with the handles on the whole call (start «\(trimHandle(w, "Начало").map(name) ?? "-")»)"); return
    }
    if button(w, "Назад на 15 секунд") != nil { fail("panel", "the player bar is still shown next to the panel") }
    checkTrimPanel(app, w, listenMustWork: false)

    checked += 2
    guard let p = trimPanel(w), let cancel = button(p, "Отмена") else { fail("«Отмена»", "not in the panel"); return }
    // VoiceOver (and `press`) ask for "scroll to visible" first: the panel floats over the card and stays put.
    checked += 1
    if let before = frame(p) {
        AXUIElementPerformAction(cancel, "AXScrollToVisible" as CFString); wait(0.5)
        let after = trimPanel(w).flatMap(frame), wf = frame(w)
        if after == nil || wf == nil || !wf!.contains(after!) || abs(after!.minY - before.minY) > 2 {
            fail("«Отмена»", "scroll to visible moved the panel from \(before) to \(after.map { "\($0)" } ?? "-") (window \(wf.map { "\($0)" } ?? "-"))")
        }
    }
    pressPinned(app, w, cancel)
    waitFor(2) { trimPanel(w) == nil && playerShown(w) }
    if trimPanel(w) != nil || trimHandle(w, "Начало") != nil { fail("«Отмена»", "the panel is still open") }
    if !playerShown(w) { fail("«Отмена»", "the player bar didn't come back") }

    // Escape from a focused handle closes it too.
    guard let again = moreMenuItem(app, w, "Обрезать…"), let af = frame(again) else { return }
    click(CGPoint(x: af.midX, y: af.midY)); wait(1.2)
    guard let h = trimHandle(w, "Конец"), let hf = frame(h) else { fail("«Обрезать…»", "the panel didn't open a second time"); return }
    click(CGPoint(x: hf.midX, y: hf.midY)); wait(0.3)
    key(escape)
    waitFor(2) { trimPanel(w) == nil && playerShown(w) }
    if trimPanel(w) != nil { fail("Escape", "Escape on a handle doesn't close the panel") }
    if !playerShown(w) { fail("Escape", "the player bar didn't come back") }
}

/// The demo contract call is quiet for its first six minutes (call.json `silence`): the card offers the trim,
/// "Обрезать" opens the panel on the speech edges, "×" hides it for good. Runs last among the Calls tests: the
/// dismissal is written to the demo call.
func trimHintTest(_ app: TestApp) {
    screen = "Обрезка · подсказка о тишине"
    print("• \(screen)")
    app.launch(["--preview", "calls", "--size", callsSize, "--select", "14-05"])
    wait(1.2)
    guard let w = mainWindow(app) else { fail("window", "no window opened"); return }
    checked += 1
    guard textContaining(w, "Первые 6 минут тишина") != nil else {
        fail("banner", "no «Первые 6 минут тишина.» on the quiet contract call"); return
    }
    guard let trim = button(w, "Обрезать") else { fail("banner", "no «Обрезать» button"); return }
    checked += 2
    press(app, w, trim); wait(1.2)
    let s = trimHandle(w, "Начало").map(name) ?? "-", e = trimHandle(w, "Конец").map(name) ?? "-"
    // 372 s of quiet less the 2 s margin; the end stays at the call's end (65:20).
    if s != "Начало, 6:10" || seconds(e) != 3920 { fail("banner «Обрезать»", "handles at «\(s)», «\(e)», not 6:10 and the end 1:05:20") }
    if textContaining(w, "минут тишина") != nil { fail("banner", "still shown while the panel is open") }
    checked += 1
    if let p = trimPanel(w), let cancel = button(p, "Отмена") {
        pressPinned(app, w, cancel)
        waitFor(2) { textContaining(w, "Первые 6 минут тишина") != nil }
    }
    else { fail("«Отмена»", "not in the panel"); return }
    if textContaining(w, "Первые 6 минут тишина") == nil { fail("banner", "didn't come back after «Отмена»") }
    checked += 2
    guard let x = button(w, "Больше не предлагать для этого звонка") else { fail("banner «×»", "no «×» with a VoiceOver label"); return }
    press(app, w, x); wait(1.0)
    if textContaining(w, "Первые 6 минут тишина") != nil { fail("banner «×»", "the banner is still shown") }
    let calls = app.data.appendingPathComponent("Calls")
    let folder = (try? FileManager.default.contentsOfDirectory(atPath: calls.path))?.first { $0.contains("14-05") }
    let json = folder.flatMap { try? Data(contentsOf: calls.appendingPathComponent($0).appendingPathComponent("call.json")) }
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    if json?["trim_hint_dismissed"] as? Bool != true { fail("banner «×»", "call.json has no trim_hint_dismissed: true") }
}

/// One call transcribing, one waiting, with a speed of this Mac: the list shows "осталось ≈ …" and "≈ …", and
/// "Обрезать…" is off with its reason while the call is busy.
func trimBusyAndEstimateTest(_ app: TestApp) {
    screen = "Звонки · очередь и оценка времени"
    print("• \(screen)")
    app.launch(["--preview", "calls", "--size", callsSize, "--queue"])
    wait(1.5)
    guard let w = mainWindow(app) else { fail("window", "no window opened"); return }
    checked += 2
    let texts = all(w).flatMap { [value($0), name($0)] }.filter { $0.contains("≈") || $0.contains("почти готово") }
    print("  estimates: \(Set(texts).sorted())")
    if !texts.contains(where: { $0.contains("осталось ≈") || $0.contains("почти готово") }) {
        fail("estimate", "no «осталось ≈ …» on the call being transcribed")
    }
    if !texts.contains(where: { $0.contains("≈") && !$0.contains("осталось") }) { fail("estimate", "no «≈ …» on the waiting call") }
    checked += 1
    guard let item = moreMenuItem(app, w, "Обрезать…") else { return }
    if enabled(item) { fail("«Обрезать…»", "enabled while the call is being transcribed") }
    let help = str(item, kAXHelpAttribute)
    if help.isEmpty { print("    note: the disabled «Обрезать…» has no AXHelp; its reason shows as a tooltip only") }
    else if !help.contains("расшифровывается") { fail("«Обрезать…»", "reason «\(help)», not the busy one") }
    key(escape); wait(0.4)
}

/// Settings > General: "Спокойный значок во время записи" is there and flips both ways.
func quietIconTest(_ app: TestApp) {
    screen = "Настройки · спокойный значок"
    print("• \(screen)")
    app.launch(["--preview", "settings", "--tab", "0"])
    guard let w = app.windows().first else { fail("window", "no window opened"); return }
    checked += 2
    guard let t = firstNamed(w, "Спокойный значок во время записи", role: "AXCheckBox") else {
        fail("toggle", "no «Спокойный значок во время записи» switch"); return
    }
    let before = value(t)
    guard press(app, w, t) else { fail(label(t), "can't scroll it into view"); return }
    wait(0.5)
    let after = value(t)
    if after == before { fail(label(t), "click doesn't flip it (stays \(before))") }
    press(app, w, t); wait(0.5)
    if value(t) != before { fail(label(t), "second click doesn't flip it back") }
}

/// The capsule's disk warnings render (the capsule states board).
func diskWarningsTest(_ app: TestApp) {
    screen = "Капсула · предупреждения о диске"
    print("• \(screen)")
    app.launch(["--preview", "capsules"])
    guard let w = mainWindow(app) else { fail("window", "no window opened"); return }
    for t in ["Запись не сохраняется: на диске нет места", "Запись не сохраняется: не удаётся записать файл",
              "На диске меньше 1 ГБ, запись скоро остановится"] {
        checked += 1
        if textContaining(w, t) == nil { fail("warning", "«\(t)» not shown") }
    }
}

/// Screenshots of the new screens, light and dark, for review: shot-<screen>-<light|dark>.png in the shots folder.
func newScreenShots(_ app: TestApp) {
    screen = "Снимки новых экранов"
    print("• \(screen)")
    let calls = ["--preview", "calls", "--size", callsSize]
    let list: [(String, [String])] = [
        ("trim-panel", ["--preview", "trim"]),
        ("trim-confirm", ["--preview", "trim-confirm"]),
        ("trim-working", ["--preview", "trim-working"]),
        ("trim-hints", ["--preview", "trim-banner"]),
        ("calls-trim", calls + ["--trim"]),
        ("calls-silence-hint", calls + ["--select", "14-05"]),
        ("calls-queue-estimate", calls + ["--queue"]),
        ("capsule-states", ["--preview", "capsules"]),
        // Not --tall: the whole pane is taller than the runner's screen, and a window past the screen's edge lays
        // its pane out under the toolbar (the first section cut off). A normal window, scrolled to the new row.
        ("settings-general", ["--preview", "settings", "--tab", "0"]),
    ]
    for (n, args) in list {
        for look in ["light", "dark"] {
            app.launch(args + ["--appearance", look])
            wait(1.5)
            if n == "settings-general", let w = mainWindow(app),
               let row = firstNamed(w, "Спокойный значок", role: "AXCheckBox") {
                _ = reveal(row, in: w); wait(0.4)
            }
            checked += 1
            if windowShot(app.pid, "shot \(n) \(look)") == nil { fail("shot \(n) \(look)", "no screenshot of the window") }
        }
    }
}

// MARK: - Main

guard AXIsProcessTrusted() else { print("Give the terminal Accessibility access (System Settings > Privacy)."); exit(2) }
let app = TestApp(bundle: URL(fileURLWithPath: CommandLine.arguments[1]), data: URL(fileURLWithPath: CommandLine.arguments[2]))
let only = CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : ""

/// The Calls window: 1100x900, smaller on a small screen (CI runners).
let callsSize: String = {
    let v = NSScreen.screens.first?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
    return "\(Int(min(1100, v.width - 40)))x\(Int(min(900, v.height - 40)))"
}()
let screens: [(String, [String], [String])] = [
    ("Настройки · Основные", ["--preview", "settings", "--tab", "0"], []),
    ("Настройки · Распознавание", ["--preview", "settings", "--tab", "1"], []),
    ("Настройки · Ассистенты", ["--preview", "settings", "--tab", "2"], []),
    ("Настройки · Облако", ["--preview", "settings", "--tab", "3"], []),
    ("Настройки · Обновление скачано", ["--preview", "settings", "--tab", "4", "--update-ready"], []),
    ("Настройки · Настройка не завершена", ["--preview", "settings", "--tab", "0", "--setup-incomplete"], []),
    ("Мастер · Приветствие", ["--preview", "setup", "--tab", "0"], []),
    ("Мастер · Ассистент", ["--preview", "setup", "--tab", "1"], []),
    ("Мастер · Аккаунт", ["--preview", "setup", "--tab", "2"], []),
    ("Мастер · Модель", ["--preview", "setup", "--tab", "3"], []),
    ("Мастер · Установка (идёт)", ["--preview", "setup", "--tab", "4", "--setup-state", "installing"], []),
    ("Мастер · Установка (ошибка)", ["--preview", "setup", "--tab", "4", "--setup-state", "failed"], []),
    ("Мастер · Разрешения", ["--preview", "setup", "--tab", "5", "--setup-state", "installed"], []),
    ("Мастер · Проекты", ["--preview", "setup", "--tab", "6", "--setup-state", "found"], []),
    ("Мастер · Переустановка", ["--preview", "repair"], []),
    ("Звонки · Итоги", ["--preview", "calls", "--size", callsSize], []),
    ("Звонки · Расшифровка", ["--preview", "calls", "--size", callsSize], ["Расшифровка"]),
    ("Звонки · Новая заметка", ["--preview", "calls", "--size", callsSize], ["Добавить заметку"]),
    ("Звонки · Идёт запись", ["--preview", "calls", "--size", callsSize, "--live"], []),
    ("Обрезка", ["--preview", "trim"], []),
    ("Обрезка · подтверждение", ["--preview", "trim-confirm"], []),
    ("Обрезка · идёт", ["--preview", "trim-working"], []),
    ("Обрезка · подсказка", ["--preview", "trim-banner"], []),
    ("Звонки · Обрезка", ["--preview", "calls", "--size", callsSize, "--trim"], []),
    ("Проекты", ["--preview", "projects"], []),
    ("Проекты · новый", ["--preview", "projects"], ["Новый проект"]),
    ("О чём был звонок", ["--preview", "callinfo"], []),
    ("О чём был звонок · проект", ["--preview", "callinfo-proj"], []),
    ("Образец голоса", ["--preview", "voicesheet"], []),
    ("Исправить слово", ["--preview", "fixword"], []),
    ("В Напоминания", ["--preview", "reminders"], []),
]
for (t, a, st) in screens where only.isEmpty || t.localizedCaseInsensitiveContains(only) { run(app, t, a, steps: st) }
if only.isEmpty || "Настройки · переключение вкладок".localizedCaseInsensitiveContains(only) { settingsTabSwitching(app) }
if only.isEmpty || "Капсула · перетаскивание".localizedCaseInsensitiveContains(only) { capsuleDrag(app) }
// The new screens: shots first (the hint test below dismisses the demo call's hint).
let newTests: [(String, (TestApp) -> Void)] = [
    ("Снимки новых экранов", newScreenShots),
    ("Обрезка · ручки и подтверждение", trimBoardTest),
    ("Обрезка · из меню «Ещё»", trimInCallsTest),
    ("Звонки · очередь и оценка времени", trimBusyAndEstimateTest),
    ("Обрезка · подсказка о тишине", trimHintTest),
    ("Настройки · спокойный значок", quietIconTest),
    ("Капсула · предупреждения о диске", diskWarningsTest),
]
for (t, test) in newTests where only.isEmpty || t.localizedCaseInsensitiveContains(only) { test(app) }
app.quit()

print("\nCovered:"); coverage.forEach { print("  \($0)") }
print("\nChecked \(checked) controls, \(failures.count) problems.")
for f in failures { print("- [\(f.screen)] \(f.control): \(f.problem)") }
exit(failures.isEmpty ? 0 : 1)
