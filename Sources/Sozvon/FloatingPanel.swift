// Плавающая панель поверх всех окон, в духе Dynamic Island / Live Activities:
// тёмная стеклянная капсула, живая волна голосов (я белым, собеседники коралловым),
// таймер и стоп. Без записи маленькая капсула «Записать» (можно скрыть в настройках),
// состояния сменяются с анимацией. Перетаскивается, позиция запоминается.

import AppKit
import Combine
import SozvonCore
import SwiftUI

let brandCoral = Color(red: 1.0, green: 0.42, blue: 0.45)

@MainActor
final class PanelModel: ObservableObject {
    enum State { case idle, recording, saved, processing }
    @Published var state: State = .idle
    @Published var elapsed = "0:00"
    /// Сколько секунд системный звук в цифровой тишине (захват мог отвалиться).
    @Published var systemSilent: Int = 0
    /// Сколько секунд с микрофона не приходит пригодный звук.
    @Published var micMissing: Int = 0
    /// История уровней для волны: самый новый справа.
    @Published var history: [Level] = Array(repeating: Level(mic: 0, sys: 0), count: PanelModel.bars)
    static let bars = 22
    /// Курсор над панелью: панель непрозрачная, иначе полупрозрачная.
    @Published var hovering = false
    /// Панель сдвинули между нажатием и отпусканием мыши: это перетаскивание, не клик.
    var wasDragged: () -> Bool = { false }

    /// Выполнить действие кнопки, только если это был клик, а не перетаскивание панели.
    func click(_ action: () -> Void) {
        if !wasDragged() { action() }
    }

    var onRecord: () -> Void = {}
    var onStop: () -> Void = {}
    var onHide: () -> Void = {}

    struct Level: Equatable, Sendable { var mic: Float; var sys: Float }

    /// Сбросить волну и предупреждения (запись закончилась).
    func resetLevels() {
        history = Array(repeating: Level(mic: 0, sys: 0), count: PanelModel.bars)
        systemSilent = 0
        micMissing = 0
    }

    func push(mic: Float, sys: Float) {
        history.removeFirst()
        history.append(Level(mic: mic, sys: sys))
    }

    var micWarning: Bool { micMissing >= 8 }
    var silentWarning: Bool { systemSilent >= 20 || micWarning }
}

/// Живая волна: каждый столбик это 100 мс. Цвет показывает, кто громче.
struct LiveWave: View {
    let history: [PanelModel.Level]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(Array(history.enumerated()), id: \.offset) { i, h in
                let v = CGFloat(max(h.mic, h.sys))
                Capsule()
                    .fill(h.sys > h.mic ? brandCoral : Color.primary.opacity(0.85))
                    .frame(width: 3, height: max(3, 22 * pow(v, 1.4)))
                    .opacity(0.3 + 0.7 * Double(i) / Double(history.count))
            }
        }
        .frame(height: 22)
        .animation(.easeOut(duration: 0.12), value: history)
        .accessibilityHidden(true)
    }
}

struct RecordDot: View {
    @State private var glow = false
    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .shadow(color: .red.opacity(glow ? 0.9 : 0.2), radius: glow ? 6 : 2)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { glow = true }
            }
    }
}

struct StopButton: View {
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(hover ? Color.red : Color.primary.opacity(0.12))
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(hover ? Color.white : Color.primary)
                    .frame(width: 9, height: 9)
            }
            .frame(width: 28, height: 28)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .help(L("Остановить и расшифровать"))
        .accessibilityLabel(L("Остановить и расшифровать"))
    }
}

/// Системный крестик внутри капсулы, появляется при наведении.
struct CloseButton: View {
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 16))
                .foregroundStyle(Color.primary.opacity(hover ? 0.7 : 0.4))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help(L("Скрыть панель (вернуть: меню Sozvon → Плавающая панель)"))
        .accessibilityLabel(L("Скрыть панель"))
    }
}

struct PanelView: View {
    @ObservedObject var m: PanelModel
    @State private var hover = false

    private var silentText: String {
        m.micWarning
            ? L("Тебя не слышно %@", String(format: "%d:%02d", m.micMissing / 60, m.micMissing % 60))
            : L("Их не слышно %@", String(format: "%d:%02d", m.systemSilent / 60, m.systemSilent % 60))
    }

    var body: some View {
        HStack(spacing: 12) {
            switch m.state {
            case .recording:
                RecordDot().padding(.leading, 4)
                Text(m.elapsed)
                    .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                if m.silentWarning {
                    Label(silentText, systemImage: m.micWarning ? "mic.slash.fill" : "speaker.slash.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.orange)
                        .transition(.blurReplace)
                } else {
                    LiveWave(history: m.history)
                        .transition(.blurReplace)
                }
                StopButton(action: { m.click(m.onStop) })
            case .saved:
                // Между остановкой и решением «расшифровать или нет»: спокойное подтверждение.
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.green)
                    .font(.system(size: 17))
                    .padding(.leading, 2)
                    .transition(.opacity)
                Text(L("Записано"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.trailing, 6)
                    .transition(.opacity)
            case .processing:
                ProgressView().controlSize(.small).padding(.leading, 4)
                Text(L("Расшифровка…"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.trailing, 6)
            case .idle:
                Button(action: { m.click(m.onRecord) }) {
                    HStack(spacing: 8) {
                        Circle().strokeBorder(Color.primary.opacity(0.85), lineWidth: 1.5)
                            .overlay(Circle().fill(Color.red).padding(3.5))
                            .frame(width: 16, height: 16)
                        Text(L("Записать"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Начать запись звонка"))
            }
            if hover && m.state != .recording {
                CloseButton(action: { m.click(m.onHide) })
                    .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .trailing)),
                                            removal: .opacity))
            }
        }
        // Симметрично; во время записи справа круглая кнопка стоп, ей хватает меньшего отступа.
        .padding(.leading, 12)
        .padding(.trailing, m.state == .recording ? 8 : 12)
        .frame(height: 44)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.15)) { hover = h }
            m.hovering = h
        }
        .contextMenu {
            Button(L("Скрыть панель")) { m.onHide() }
        }
        .animation(.easeInOut(duration: 0.25), value: m.state)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: m.silentWarning)
        .fixedSize()
        // Прижато к левому краю окна: пока окно меняет ширину, текст стоит на месте.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

@MainActor
final class FloatingPanel {
    static let defaultsKey = "floatingPanel"
    static let idleKey = "floatingPanelWhenIdle"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
    /// Показывать капсулу «Записать» и без записи.
    static var showWhenIdle: Bool {
        get { UserDefaults.standard.object(forKey: idleKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: idleKey) }
    }

    let model = PanelModel()
    private var panel: NSPanel?
    private var host: NSHostingView<PanelView>?
    private var visible = false
    private var hoverSub: AnyCancellable?
    private var downOrigin: NSPoint?
    private var mouseMonitor: Any?
    /// Прозрачность, когда курсор не над панелью.
    static let restingAlpha: CGFloat = 0.82

    private var targetAlpha: CGFloat { model.hovering ? 1 : FloatingPanel.restingAlpha }

    /// Скругление капсулы: мягкий прямоугольник, не полный круг по краям.
    static let cornerRadius: CGFloat = 15
    private var setRadius: (CGFloat) -> Void = { _ in }

    /// Содержимое на подложке заведомо шире окна, прижато к левому краю.
    /// Окно при изменении ширины лишь открывает больше или меньше подложки, как шторка:
    /// содержимому не бывает тесно, и оно никогда не сдвигается.
    static func stage(_ host: NSView) -> NSView {
        // Начальный размер подложки как у окна (200×44), иначе автоподгонка высоты считает от нуля.
        let stage = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 44))
        stage.autoresizingMask = [.width, .height]
        host.translatesAutoresizingMaskIntoConstraints = true
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 44)
        host.autoresizingMask = [.height, .maxXMargin]
        stage.addSubview(host)
        return stage
    }

    private func make() {
        let host = NSHostingView(rootView: PanelView(m: model))
        // Размер окна задаём сами в fit(): иначе hosting view навязывает окну свои ограничения
        // и оно подпрыгивает к размеру содержимого раньше анимации.
        host.sizingOptions = [.intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = false
        let root: NSView
        if #available(macOS 26.0, *) {
            // Liquid Glass macOS 26: системное жидкое стекло с лёгким тёмным тоном,
            // чтобы белый текст читался на любом фоне.
            let glass = NSGlassEffectView()
            glass.style = .regular
            // Без тона: стекло само подстраивается под светлую и тёмную тему и фон под ним.
            glass.cornerRadius = FloatingPanel.cornerRadius
            glass.contentView = FloatingPanel.stage(host)
            setRadius = { glass.cornerRadius = $0 }
            root = glass
        } else {
            // macOS 15: тёмное матовое стекло HUD.
            let fx = NSVisualEffectView()
            fx.material = .hudWindow
            fx.blendingMode = .behindWindow
            fx.state = .active
            fx.wantsLayer = true
            fx.layer?.cornerCurve = .continuous
            fx.layer?.masksToBounds = true
            fx.layer?.borderWidth = 0.5
            fx.layer?.borderColor = NSColor.separatorColor.cgColor
            let tint = NSView()
            tint.wantsLayer = true
            tint.layer?.backgroundColor = NSColor.clear.cgColor
            tint.translatesAutoresizingMaskIntoConstraints = false
            fx.addSubview(tint)
            let stage = FloatingPanel.stage(host)
            stage.frame = fx.bounds
            fx.addSubview(stage)
            NSLayoutConstraint.activate([
                tint.leadingAnchor.constraint(equalTo: fx.leadingAnchor), tint.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
                tint.topAnchor.constraint(equalTo: fx.topAnchor), tint.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
            ])
            fx.layer?.cornerRadius = FloatingPanel.cornerRadius
            setRadius = { fx.layer?.cornerRadius = $0 }
            root = fx
        }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.contentView = root
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.alphaValue = 0
        if !p.setFrameUsingName("SozvonPanel2"), let screen = NSScreen.main {
            // По умолчанию: сверху по центру, под строкой меню, как Dynamic Island.
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - 110, y: f.maxY - 60))
        }
        p.setFrameAutosaveName("SozvonPanel2")
        panel = p
        self.host = host
        // Запоминаем положение панели при нажатии мыши: если к отпусканию она сдвинулась,
        // кнопки не срабатывают (перетаскивали, а не нажимали).
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            MainActor.assumeIsolated {
                if let self, e.window === self.panel { self.downOrigin = self.panel?.frame.origin }
            }
            return e
        }
        model.wasDragged = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let a = self.downOrigin, let b = self.panel?.frame.origin else { return false }
                return abs(a.x - b.x) > 2 || abs(a.y - b.y) > 2
            }
        }
        hoverSub = model.$hovering.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.visible, let panel = self.panel else { return }
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.2
                        panel.animator().alphaValue = self.targetAlpha
                    }
                    // Крестик: окно вытягивается вправо, левый край и текст на месте.
                    self.fit(keepLeft: true)
                }
            }
        }
    }

    func show() {
        if panel == nil { make() }
        guard let panel else { return }
        fit()
        guard !visible else { return }
        visible = true
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = targetAlpha
        }
    }

    func hide() {
        guard let panel, visible else { return }
        visible = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if self?.visible == false { self?.panel?.orderOut(nil) }
            }
        })
    }

    /// Показать или спрятать по настройкам и текущему состоянию.
    func sync() {
        let active = model.state != .idle
        if FloatingPanel.enabled && (active || FloatingPanel.showWhenIdle) { show() } else { hide() }
    }

    /// Подогнать размер под содержимое, сохраняя центр по горизонтали.
    func fit(keepLeft: Bool = true) {
        guard let panel, let host else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        guard size.width > 0 else { return }
        setRadius(FloatingPanel.cornerRadius)
        guard panel.frame.size != size else { return }
        let f = panel.frame
        var x = keepLeft ? f.minX : f.midX - size.width / 2
        // Не вылезать за край экрана.
        if let vf = (panel.screen ?? NSScreen.main)?.visibleFrame {
            x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
        }
        let rect = NSRect(x: x, y: f.maxY - size.height, width: size.width, height: size.height)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = visible ? 0.25 : 0
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(rect, display: true)
        }
    }
}
