// A floating panel above all windows, in the spirit of Dynamic Island / Live Activities:
// a dark glass capsule, a live waveform of voices (me in white, the others in coral),
// a timer and a stop button. When not recording, a small "Record" capsule (can be hidden in Settings);
// states change with animation. Draggable, and the position is remembered.

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
    /// How many seconds system audio has been digital silence (capture may have dropped).
    @Published var systemSilent: Int = 0
    /// How many seconds without usable audio from the microphone.
    @Published var micMissing: Int = 0
    /// Level history for the waveform, newest on the right.
    @Published var history: [Level] = Array(repeating: Level(mic: 0, sys: 0), count: PanelModel.bars)
    static let bars = 22
    /// Pointer over the panel: panel is opaque, otherwise translucent.
    @Published var hovering = false
    /// The panel moved between mouse down and mouse up: that's a drag, not a click.
    var wasDragged: () -> Bool = { false }

    /// Run the button's action only if it was a click, not a panel drag.
    func click(_ action: () -> Void) {
        if !wasDragged() { action() }
    }

    var onRecord: () -> Void = {}
    var onStop: () -> Void = {}
    var onHide: () -> Void = {}

    struct Level: Equatable, Sendable { var mic: Float; var sys: Float }

    /// Reset the waveform and warnings (recording ended).
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

/// Live waveform: each bar is 100 ms. The color shows who is louder.
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

/// System close button inside the capsule, shown on hover.
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
                // Between stopping and the "transcribe or not" decision: a calm confirmation.
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
        // Symmetric; while recording, the round stop button on the right needs less padding.
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
        // Pinned to the window's left edge: the text stays put while the window changes width.
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
    /// Show the "Record" capsule even when not recording.
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
    /// Opacity when the pointer isn't over the panel.
    static let restingAlpha: CGFloat = 0.82

    private var targetAlpha: CGFloat { model.hovering ? 1 : FloatingPanel.restingAlpha }

    /// Capsule corner radius: a soft rectangle, not fully rounded ends.
    static let cornerRadius: CGFloat = 15
    private var setRadius: (CGFloat) -> Void = { _ in }

    /// Content sits on a backing view that is always wider than the window, pinned to the left edge.
    /// Resizing the window only reveals more or less of the backing, like a curtain:
    /// the content is never cramped and never shifts.
    static func stage(_ host: NSView) -> NSView {
        // Initial backing size matches the window (200×44), otherwise height auto-fit starts from zero.
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
        // We size the window ourselves in fit(): otherwise the hosting view imposes its constraints
        // and the window jumps to the content size before the animation.
        host.sizingOptions = [.intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = false
        let root: NSView
        if #available(macOS 26.0, *) {
            // macOS 26 Liquid Glass: system glass with a light dark tint,
            // so white text reads on any background.
            let glass = NSGlassEffectView()
            glass.style = .regular
            // No tint: the glass adapts to light and dark mode and to what's behind it.
            glass.cornerRadius = FloatingPanel.cornerRadius
            glass.contentView = FloatingPanel.stage(host)
            setRadius = { glass.cornerRadius = $0 }
            root = glass
        } else {
            // macOS 15: dark frosted HUD glass.
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
            // Default: top center, below the menu bar, like Dynamic Island.
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - 110, y: f.maxY - 60))
        }
        p.setFrameAutosaveName("SozvonPanel2")
        panel = p
        self.host = host
        // Remember the panel position on mouse down: if it moved by mouse up,
        // the buttons don't fire (it was a drag, not a press).
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
                    // Close button: the window grows to the right, the left edge and text stay in place.
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

    /// Show or hide based on settings and the current state.
    func sync() {
        let active = model.state != .idle
        if FloatingPanel.enabled && (active || FloatingPanel.showWhenIdle) { show() } else { hide() }
    }

    /// Fit the size to the content, keeping the horizontal center.
    func fit(keepLeft: Bool = true) {
        guard let panel, let host else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        guard size.width > 0 else { return }
        setRadius(FloatingPanel.cornerRadius)
        guard panel.frame.size != size else { return }
        let f = panel.frame
        var x = keepLeft ? f.minX : f.midX - size.width / 2
        // Don't go past the screen edge.
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
