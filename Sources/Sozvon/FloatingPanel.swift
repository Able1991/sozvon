// A floating panel above all windows, in the spirit of Dynamic Island / Live Activities:
// a glass capsule (Capsule design: `.cap`, 44 high, radius 18), a live waveform of voices (me in blue, the others in coral),
// a timer and a stop button. When not recording, a small "Record" capsule (can be hidden in Settings);
// states change with animation. Draggable, and the position is remembered.
// When a call app takes the microphone, the idle capsule asks "A call is on in Zoom. Record?" (CallPrompt.swift).

import AppKit
import Combine
import SozvonCore
import SwiftUI

@MainActor
final class PanelModel: ObservableObject {
    enum State { case idle, starting, recording, saved, processing }
    @Published var state: State = .idle
    @Published var elapsed = "0:00" {
        // Remember the length while recording: after the stop the session (and its clock) is gone.
        didSet { if state == .recording, elapsed != "0:00" { recordedElapsed = elapsed } }
    }
    /// The last recording's length ("12:37"), for "Recorded · 13 min".
    @Published private(set) var recordedElapsed: String?
    /// A source can't be heard (RecordingController decides when): the capsule shows it instead of the waveform.
    enum Warning: Equatable {
        case mic(seconds: Int)
        case them(seconds: Int)
    }
    @Published var warning: Warning?
    /// Level history for the waveform, newest on the right.
    @Published var history: [Level] = Array(repeating: Level(mic: 0, sys: 0), count: PanelModel.bars)
    static let bars = 22
    /// Pointer over the panel: panel is opaque, otherwise translucent.
    @Published var hovering = false
    /// "Important" marks in this recording, and a short highlight right after a press.
    @Published var marks = 0
    @Published var justMarked = false
    /// "A call is on in Zoom. Record?" while Sozvon is idle; nil: no prompt.
    @Published var callPrompt: String?
    /// The panel moved between mouse down and mouse up: that's a drag, not a click.
    var wasDragged: () -> Bool = { false }

    /// Run the button's action only if it was a click, not a panel drag.
    func click(_ action: () -> Void) {
        if !wasDragged() { action() }
    }

    var onRecord: () -> Void = {}
    var onStop: () -> Void = {}
    var onMark: () -> Void = {}
    var onHide: () -> Void = {}
    var onPromptRecord: () -> Void = {}
    var onPromptDismiss: () -> Void = {}

    /// The call prompt replaces the idle "Record" capsule and the transcription status.
    var showsPrompt: Bool { callPrompt != nil && (state == .idle || state == .processing) }

    struct Level: Equatable, Sendable { var mic: Float; var sys: Float }

    /// Whole minutes of the last recording (at least 1), nil when not known.
    var recordedMinutes: Int? {
        guard let e = recordedElapsed else { return nil }
        let parts = e.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        let seconds = parts.reduce(0) { $0 * 60 + $1 }
        return max(1, Int((Double(seconds) / 60).rounded()))
    }

    /// Reset the waveform and warnings (recording ended).
    func resetLevels() {
        history = Array(repeating: Level(mic: 0, sys: 0), count: PanelModel.bars)
        warning = nil
        justMarked = false
    }

    /// A mark was made (panel, menu or shortcut): count it and light the star for a moment.
    func marked() {
        marks += 1
        justMarked = true
        let n = marks
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            MainActor.assumeIsolated { if self?.marks == n { self?.justMarked = false } }
        }
    }

    func push(mic: Float, sys: Float) {
        history.removeFirst()
        history.append(Level(mic: mic, sys: sys))
    }
}

/// Live waveform: each bar is 100 ms; me in blue up from the middle, them in coral down, at the same time.
struct LiveWave: View {
    let history: [PanelModel.Level]

    var body: some View {
        SZWDuplexWave(bars: history.map { h in
            SZWDuplexWave.Bar(me: CGFloat(h.mic), them: CGFloat(h.sys))
        })
        .animation(.easeOut(duration: 0.12), value: history)
    }
}

/// `.stop`: a 28pt circle in the capsule fill with an inset edge and a 9pt rounded square; red on hover.
struct StopButton: View {
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(hover ? SZ.red : SZW.capsuleFill)
                    .overlay { SZTopHighlight(shape: Circle(), color: SZW.capsuleEdge) }
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hover ? Color.white : SZ.label)
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

/// `.mark`: "Important" during a recording, marks this moment for the transcript and the summary.
/// The star turns yellow once something is marked and pops for a moment on each press.
struct MarkButton: View {
    let count: Int
    let lit: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "star.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(count > 0 || lit ? AnyShapeStyle(SZ.yellow)
                                     : AnyShapeStyle(SZ.label.opacity(hover ? 0.95 : 0.7)))
                    .scaleEffect(lit ? 1.25 : 1)
                if count > 0 {
                    Text(verbatim: "\(count)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(SZ.label2)
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 28)
            .background(Capsule().fill(hover ? SZW.capsuleFill : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .animation(.spring(response: 0.3, dampingFraction: 0.5), value: lit)
        .animation(.easeOut(duration: 0.2), value: count)
        .help(L("Отметить важный момент (⌃⌥I): он будет выделен в расшифровке и разобран в итогах"))
        .accessibilityLabel(L("Отметить важный момент"))
        .accessibilityValue(count > 0 ? "\(count)" : "")
    }
}

/// Close button inside the capsule, shown on hover when idle.
struct CloseButton: View {
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 16))
                .foregroundStyle(SZ.label.opacity(hover ? 0.7 : 0.4))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help(L("Скрыть панель (вернуть: меню Sozvon → Плавающая панель)"))
        .accessibilityLabel(L("Скрыть панель"))
    }
}

/// "A call is on in Zoom. Record?" with "Record" and "Not now". Recording starts only on the press.
struct CallPromptView: View {
    let text: String
    let record: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "phone.fill")
                .font(.system(size: 13))
                .foregroundStyle(SZ.green)
                .padding(.leading, 4)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SZ.label)
                .lineLimit(1)
                .padding(.trailing, 6)
            Button(action: record) {
                HStack(spacing: 6) {
                    SZWRecordDot(glow: false)
                    Text(L("Записать")).font(.system(size: 12, weight: .semibold)).foregroundStyle(SZ.label)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(SZW.capsuleFill))
                .overlay { SZTopHighlight(shape: Capsule(), color: SZW.capsuleEdge) }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(L("Начать запись звонка"))
            Button(action: dismiss) {
                Text(L("Не сейчас")).font(.system(size: 12, weight: .medium)).foregroundStyle(SZ.label2)
                    .padding(.trailing, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Не предлагать, пока этот звонок не закончится"))
        }
    }
}

struct PanelView: View {
    @ObservedObject var m: PanelModel
    @State private var hover = false

    private func warningText(_ w: PanelModel.Warning) -> String {
        switch w {
        case .mic(let s): return L("Тебя не слышно %@", Call.clock(s, empty: "0:00"))
        case .them(let s): return L("Их не слышно %@", Call.clock(s, empty: "0:00"))
        }
    }

    private func warningSymbol(_ w: PanelModel.Warning) -> String {
        if case .mic = w { return "mic.slash.fill" }
        return "speaker.slash.fill"
    }

    /// "Recorded · 22 min": the length of the recording that just ended, when known.
    private var savedText: String {
        guard let minutes = m.recordedMinutes else { return L("Записано") }
        return L("Записано · %@ мин", minutes)
    }

    var body: some View {
        HStack(spacing: 12) {
            if m.showsPrompt, let text = m.callPrompt {
                CallPromptView(text: text, record: { m.click(m.onPromptRecord) }, dismiss: { m.click(m.onPromptDismiss) })
                    .transition(.blurReplace)
            } else {
                content
            }
            if hover && m.state != .recording && !m.showsPrompt {
                CloseButton(action: { m.click(m.onHide) })
                    .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .trailing)),
                                            removal: .opacity))
            }
        }
        // `.cap` padding 0 12; while recording (`.cap.rec`) the round stop button sits 8 from the edge.
        .padding(.leading, 12)
        .padding(.trailing, m.state == .recording ? 8 : 12)
        .frame(height: 44)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.15)) { hover = h }
            m.hovering = h
        }
        // The whole capsule is one control: a pointing hand anywhere on it. The panel never becomes key, so
        // cursor rects don't apply (the app below kept its I-beam): set it on every move instead. On the way
        // out the app below sets its own again.
        .onContinuousHover { phase in
            if case .active = phase { NSCursor.pointingHand.set() }
        }
        .contextMenu {
            Button(L("Скрыть панель")) { m.onHide() }
        }
        // isMovableByWindowBackground stops working while the waveform redraws ten times a second
        // (during a recording the capsule could not be dragged): an explicit window drag works always,
        // and the buttons still get their clicks. Simultaneous: a drag that starts on "Record" or a button moves
        // the capsule too, and m.click drops the press that ends it.
        .contentShape(Rectangle())
        .simultaneousGesture(WindowDragGesture())
        .animation(.easeInOut(duration: 0.25), value: m.state)
        .animation(.easeInOut(duration: 0.25), value: m.callPrompt)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: m.warning == nil)
        .fixedSize()
        // Pinned to the window's left edge: the text stays put while the window changes width.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder private var content: some View {
        switch m.state {
        case .recording:
            SZWRecordDot().padding(.leading, 4)
            Text(m.elapsed)
                .szFont(.timer)
                .foregroundStyle(SZ.label)
                .contentTransition(.numericText())
                .accessibilityLabel(L("Идёт запись %@", m.elapsed))
            if let w = m.warning {
                HStack(spacing: 5) {
                    Image(systemName: warningSymbol(w))
                        .font(.system(size: 12, weight: .medium))
                    Text(warningText(w)).font(.system(size: 12, weight: .medium).monospacedDigit())
                }
                .foregroundStyle(SZ.orange)
                .accessibilityElement(children: .combine)
                .transition(.blurReplace)
            } else {
                LiveWave(history: m.history)
                    .transition(.blurReplace)
            }
            MarkButton(count: m.marks, lit: m.justMarked, action: { m.click(m.onMark) })
            StopButton(action: { m.click(m.onStop) })
        case .saved:
            // Between stopping and the "transcribe or not" decision: a calm confirmation.
            SZWCheckDot(size: 14)
                .accessibilityHidden(true)
                .padding(.leading, 4)
                .transition(.opacity)
            Text(savedText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SZ.label)
                .padding(.trailing, 6)
                .transition(.opacity)
        case .starting:
            // Between the click and the first audio (permissions, ScreenCaptureKit): not "Record" any more,
            // so a second click isn't silently ignored.
            SZWSpinner().padding(.leading, 4)
            Text(L("Запуск…"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SZ.label)
                .padding(.trailing, 6)
        case .processing:
            SZWSpinner().padding(.leading, 4)
            Text(L("Расшифровка…"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SZ.label)
                .padding(.trailing, 6)
        case .idle:
            // A tap, not a Button: a button keeps the mouse to itself, so a drag that starts on "Record"
            // would not move the capsule. The window drag takes over as soon as the mouse moves.
            HStack(spacing: 8) {
                SZWRecordRing()
                Text(L("Записать"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SZ.label)
            }
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .onTapGesture { m.click(m.onRecord) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("Записать"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { m.onRecord() }  // no mouse involved: not a drag
            .help(L("Начать запись звонка"))
        }
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
    /// Where the mouse went down, in screen coordinates.
    private var downMouse: NSPoint?
    /// A resize waits for the end of a drag.
    private var fitPending = false
    private var mouseMonitor: Any?
    /// Opacity when the pointer isn't over the panel.
    static let restingAlpha: CGFloat = 0.86  // .cap.rest

    private var targetAlpha: CGFloat { model.hovering ? 1 : FloatingPanel.restingAlpha }

    /// Capsule corner radius: a soft rectangle, not fully rounded ends (`.cap` border-radius 18).
    static let cornerRadius: CGFloat = 18
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
            // Tinted with the design's --glass, so the capsule reads the same over any wallpaper;
            // the color is dynamic, so it follows light and dark mode.
            glass.tintColor = SZW.glass
            glass.cornerRadius = FloatingPanel.cornerRadius
            glass.contentView = FloatingPanel.stage(host)
            setRadius = { glass.cornerRadius = $0 }
            root = glass
        } else {
            // macOS 15: frosted glass with the design's --glass tint on top.
            let fx = NSVisualEffectView()
            fx.material = .popover
            fx.blendingMode = .behindWindow
            fx.state = .active
            fx.wantsLayer = true
            fx.layer?.cornerCurve = .continuous
            fx.layer?.masksToBounds = true
            fx.layer?.borderWidth = 0.5
            fx.layer?.borderColor = NSColor.separatorColor.cgColor
            let tint = GlassTintView()
            tint.wantsLayer = true
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
        // The SwiftUI WindowDragGesture moves it; a second, AppKit drag on top of it made the capsule jerk.
        p.isMovableByWindowBackground = false
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
        // Remember the panel position and the mouse on mouse down: if either moved by mouse up, the buttons
        // don't fire (it was a drag, not a press). The mouse is checked on screen: the capsule moves along with
        // it, so inside the capsule a drag looks like a click, and the window frame may lag behind the drag.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            MainActor.assumeIsolated {
                if let self, e.window === self.panel {
                    self.downOrigin = self.panel?.frame.origin
                    self.downMouse = NSEvent.mouseLocation
                }
            }
            return e
        }
        model.wasDragged = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return false }
                func moved(_ a: NSPoint?, _ b: NSPoint?) -> Bool {
                    guard let a, let b else { return false }
                    return abs(a.x - b.x) > 3 || abs(a.y - b.y) > 3
                }
                return moved(self.downOrigin, self.panel?.frame.origin) || moved(self.downMouse, NSEvent.mouseLocation)
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
        let active = model.state != .idle || model.callPrompt != nil
        if FloatingPanel.enabled && (active || FloatingPanel.showWhenIdle) { show() } else { hide() }
    }

    /// Fit the size to the content, keeping the horizontal center.
    func fit(keepLeft: Bool = true) {
        guard let panel, let host else { return }
        // Being dragged: a resize now would animate the window back to where the drag started. Try again
        // once the button is up.
        if NSEvent.pressedMouseButtons & 1 != 0, panel.frame.insetBy(dx: -40, dy: -40).contains(NSEvent.mouseLocation) {
            guard !fitPending else { return }
            fitPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                MainActor.assumeIsolated {
                    self?.fitPending = false
                    self?.fit(keepLeft: keepLeft)
                }
            }
            return
        }
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

/// The fallback capsule's tint layer: the dynamic --glass color, re-resolved when the appearance changes.
private final class GlassTintView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = SZW.glass.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
