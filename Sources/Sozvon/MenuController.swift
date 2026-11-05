// Значок в строке меню и его меню, главное меню приложения (видно, пока открыто окно).
// Меню собирается при открытии (menuNeedsUpdate); раз в секунду меняется только строка с таймером.

import AppKit
import ServiceManagement
import SozvonCore

/// Пункт меню с замыканием вместо селектора.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { handler() }
}

/// Что меню умеет делать: всё, кроме показа, делегирует владельцу.
@MainActor
struct MenuActions {
    var toggleRecording: () -> Void
    var editInfo: () -> Void
    var showSetup: () -> Void
    var openLast: () -> Void
    var redoLast: () -> Void
    var showCalls: () -> Void
    var showProjects: () -> Void
    var showSettings: () -> Void
    var togglePanel: () -> Void
    var openUpdate: () -> Void
    var quit: () -> Void
}

/// Что показывать в меню прямо сейчас.
@MainActor
struct MenuSnapshot {
    var recording: RecordingState
    var processing: Bool
    var engineUpdating: Bool
    var engine: EngineState
    var update: Updates.Release?
    var hasLastTranscript: Bool
    var canRedoLast: Bool
    var panelEnabled: Bool
}

@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let actions: MenuActions
    private let snapshot: () -> MenuSnapshot
    private weak var header: NSMenuItem?

    init(actions: MenuActions, snapshot: @escaping () -> MenuSnapshot) {
        self.actions = actions
        self.snapshot = snapshot
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        stateChanged()
    }

    var button: NSStatusBarButton? { item.button }

    /// Состояние сменилось: значок и подсказка. Само меню пересоберётся при открытии.
    func stateChanged() {
        let s = snapshot()
        // Только значок, без таймера: широкие элементы macOS прячет под вырез камеры.
        if s.recording.isRecording {
            item.button?.image = symbol("record.circle.fill", .systemRed)
        } else if s.processing {
            item.button?.image = symbol("waveform.badge.magnifyingglass") ?? symbol("hourglass")
        } else {
            item.button?.image = symbol("waveform")
        }
        tick()
    }

    /// Раз в секунду во время записи: подсказка и строка статуса открытого меню.
    func tick() {
        let s = snapshot()
        let elapsed = s.recording.session?.elapsed() ?? ""
        item.button?.toolTip = s.recording.isRecording ? L("Sozvon: идёт запись %@", elapsed) : "Sozvon"
        header?.title = "Sozvon · " + status(s)
    }

    private func status(_ s: MenuSnapshot) -> String {
        if s.engineUpdating { return L("Обновляю движок…") }
        if s.recording.isRecording { return L("Идёт запись · %@", s.recording.session?.elapsed() ?? "") }
        if !s.engine.isUsable { return L("Нужна настройка") }
        if s.processing { return L("Расшифровка…") }
        return L("Готов к записи")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    private func rebuild() {
        let s = snapshot()
        menu.removeAllItems()
        func add(_ title: String, _ sym: String? = nil, key: String = "", tint: NSColor? = nil, on: Bool? = nil,
                 _ handler: @escaping () -> Void) {
            let i = ActionMenuItem(title, key: key, handler: handler)
            if let sym, var img = NSImage(systemSymbolName: sym, accessibilityDescription: title) {
                if let tint { img = img.withSymbolConfiguration(.init(paletteColors: [tint])) ?? img }
                i.image = img
            }
            if let on { i.state = on ? .on : .off }
            menu.addItem(i)
        }
        // Заголовок со статусом, как у системных меню Пункта управления.
        let h = NSMenuItem.sectionHeader(title: "Sozvon · " + status(s))
        menu.addItem(h)
        header = h
        if let update = s.update {
            add(L("Доступна версия %@…", update.version), "arrow.down.circle.fill", tint: .systemBlue, actions.openUpdate)
            menu.addItem(.separator())
        }
        if s.recording.isRecording {
            // Стоп доступен всегда, даже если движок «пропал» (сменили модель посреди записи).
            add(L("Остановить и расшифровать"), "stop.circle.fill", key: "r", tint: .systemRed, actions.toggleRecording)
            add(L("Проект и собеседники…"), "person.2.badge.plus", actions.editInfo)
        } else if !s.engine.isUsable {
            add(L("Завершить настройку…"), "arrow.down.circle.dotted", actions.showSetup)
        } else if !s.recording.isCapturing && !s.recording.isStarting {
            add(L("Начать запись"), "record.circle", key: "r", tint: .systemRed, actions.toggleRecording)
        }
        menu.addItem(.separator())
        if s.hasLastTranscript { add(L("Последняя расшифровка"), "doc.text.magnifyingglass", actions.openLast) }
        if s.canRedoLast { add(L("Расшифровать заново…"), "arrow.counterclockwise", actions.redoLast) }
        add(L("Звонки…"), "list.bullet.rectangle", key: "l", actions.showCalls)
        add(L("Проекты…"), "folder.badge.person.crop", actions.showProjects)
        menu.addItem(.separator())
        add(L("Плавающая панель"), "pip", on: s.panelEnabled, actions.togglePanel)
        add(L("Открывать при входе"), "power", on: SMAppService.mainApp.status == .enabled) {
            let a = SMAppService.mainApp
            if a.status == .enabled { try? a.unregister() } else { try? a.register() }
        }
        add(L("Настройки…"), "gearshape", key: ",", actions.showSettings)
        menu.addItem(.separator())
        add(L("Выйти из Sozvon"), "rectangle.portrait.and.arrow.right", key: "q", actions.quit)
    }

    private func symbol(_ name: String, _ color: NSColor? = nil) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        var img = NSImage(systemSymbolName: name, accessibilityDescription: "Sozvon")?.withSymbolConfiguration(cfg)
        if let color {
            img = img?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))
            img?.isTemplate = false
        } else {
            img?.isTemplate = true
        }
        return img
    }

    /// Главное меню (видно, пока открыто окно): без «Правки» в полях не работают ⌘C/⌘V/⌘Z.
    static func installMainMenu(settings: @escaping () -> Void, calls: @escaping () -> Void, quit: @escaping () -> Void) {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            item.submenu = m
            main.addItem(item)
        }
        func it(_ t: String, _ a: Selector?, _ k: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            i.keyEquivalentModifierMask = mods
            return i
        }
        sub("Sozvon", [
            it(L("О программе Sozvon"), #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            ActionMenuItem(L("Настройки…"), key: ",", handler: settings),
            ActionMenuItem(L("Звонки…"), key: "l", handler: calls),
            .separator(),
            it(L("Скрыть Sozvon"), #selector(NSApplication.hide(_:)), "h"),
            ActionMenuItem(L("Выйти из Sozvon"), key: "q", handler: quit),
        ])
        sub(L("Правка"), [
            it(L("Отменить"), Selector(("undo:")), "z"),
            it(L("Повторить"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            it(L("Вырезать"), #selector(NSText.cut(_:)), "x"),
            it(L("Копировать"), #selector(NSText.copy(_:)), "c"),
            it(L("Вставить"), #selector(NSText.paste(_:)), "v"),
            it(L("Выбрать все"), #selector(NSText.selectAll(_:)), "a"),
        ])
        sub(L("Окно"), [
            it(L("Свернуть"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            it(L("Закрыть"), #selector(NSWindow.performClose(_:)), "w"),
        ])
        NSApp.mainMenu = main
    }
}
