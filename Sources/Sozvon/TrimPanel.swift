// Trim a recording at its start and end: the trim panel (the player capsule grown in place, with the call's
// waveform and two handles), the "quiet at the start or end" hint, and the waveform read from the playback mix.
// The cut itself is the engine's (`bin/trim_call.py`, run by ProcessingController.trim).

import AVFoundation
import SozvonCore
import SwiftUI

/// The trim panel's times: "6:12", and "0:00" at the very start.
private func clock(_ t: Double) -> String { Call.clock(Int(t.rounded()), empty: "0:00") }

// MARK: - Waveform

enum WaveformState: Equatable {
    case loading
    case ready([Float])
    /// No track of the call could be decoded.
    case failed
}

/// Waveforms of recently opened calls, in memory only (nothing is written into the call folder). A call's entry
/// is keyed by the mtimes of its audio files, so a trimmed or newly levelled call is read again.
@MainActor
final class WaveformCache {
    static let shared = WaveformCache()
    static let bins = 600
    private static let capacity = 8
    private var store: [String: [Float]] = [:]
    private var order: [String] = []
    private var running: [String: Task<[Float]?, Never>] = [:]

    private static func key(_ dir: URL) -> String {
        let names = [AudioRetention.listen, AudioRetention.cleanMic, "mic.m4a", "system.m4a"]
        let stamps = names.map { n -> String in
            let d = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(n).path))?[.modificationDate] as? Date
            return d.map { String($0.timeIntervalSince1970) } ?? "-"
        }
        return ([dir.standardizedFileURL.path] + stamps).joined(separator: "|")
    }

    /// The call's peaks when they were read already for its current audio files.
    func cached(_ dir: URL) -> [Float]? { store[Self.key(dir)] }

    /// The call's peaks, decoded off the main thread on first need; nil when no track can be read.
    func peaks(_ dir: URL, duration: Double) async -> [Float]? {
        let key = Self.key(dir)
        if let p = store[key] { return p }
        let task = running[key] ?? Task.detached(priority: .userInitiated) {
            await WaveformReader.peaks(dir, duration: duration, bins: Self.bins)
        }
        running[key] = task
        let peaks = await task.value
        running[key] = nil
        if let peaks, store[key] == nil {
            store[key] = peaks
            order.append(key)
            while order.count > Self.capacity { store[order.removeFirst()] = nil }
        }
        return peaks
    }
}

/// Decodes the playback mix (the sources CallPlayer plays, in its order of preference) at a low rate, mono,
/// straight into a Waveform.Envelope on the call's timeline.
enum WaveformReader {
    /// The lowest rate AVAssetReader converts to (8 kHz): plenty for 600 bins, quick even for a long call.
    static let rate = 8000.0

    static func peaks(_ dir: URL, duration: Double, bins: Int) async -> [Float]? {
        guard duration > 0 else { return nil }
        let offsets = TrackOffsets(TrackOffsets.times(of: dir))
        for plan in CallPlayback.plans(in: dir, offsets: offsets) {
            var envelope = Waveform.Envelope(bins: bins, duration: duration)
            var read = false
            for source in plan {
                if await add(dir.appendingPathComponent(source.name), at: max(0, source.offset), to: &envelope) { read = true }
            }
            if read { return envelope.peaks }
        }
        return nil
    }

    /// One track into the envelope; false when it could not be decoded.
    private static func add(_ url: URL, at offset: Double, to envelope: inout Waveform.Envelope) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return false }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: rate,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return false }
        reader.add(output)
        guard reader.startReading() else { return false }
        var position = 0
        var chunk: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            let count = bytes / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            if chunk.count < count { chunk = Array(repeating: 0, count: count) }
            let copied = chunk.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                           destination: $0.baseAddress!)
            }
            guard copied == kCMBlockBufferNoErr else { continue }
            chunk.withUnsafeBufferPointer { all in
                envelope.add(UnsafeBufferPointer(rebasing: all[0..<count]), at: offset + Double(position) / rate, rate: rate)
            }
            position += count
        }
        return reader.status == .completed && position > 0
    }
}

/// The waveform's bars inside or outside the kept range, as one shape (dynamic colors resolve as in any fill).
private struct WaveBars: Shape {
    /// One value per bar, 0...1.
    let values: [CGFloat]
    let barWidth: CGFloat
    let pitch: CGFloat
    /// The kept range as fractions of the width.
    let kept: ClosedRange<CGFloat>
    let inside: Bool

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let mid = rect.midY
        for (i, v) in values.enumerated() {
            let x = CGFloat(i) * pitch
            let center = (x + barWidth / 2) / max(rect.width, 1)
            guard kept.contains(center) == inside else { continue }
            // A gentle curve, so quiet speech still shows next to a loud laugh; silence is a row of dots.
            let h = max(barWidth, rect.height * pow(v, 0.7))
            p.addRoundedRect(in: CGRect(x: x, y: mid - h / 2, width: barWidth, height: h),
                             cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
        }
        return p
    }
}

/// The waveform's rectangle widened by `outset` on the left and right only: the handles' outer grab areas, not the
/// controls above and below.
private struct GrabArea: Shape {
    let outset: CGFloat
    func path(in rect: CGRect) -> Path { Path(rect.insetBy(dx: -outset, dy: 0)) }
}

/// The whole call's waveform with the kept range highlighted, the playhead and the two handles.
struct TrimWave: View {
    let wave: WaveformState
    let duration: Double
    @Binding var state: TrimState
    /// Where the player is (nil: not shown).
    let playhead: Double?
    /// The handle the arrow keys move while the panel has the keyboard: it shows a focus ring (nil: none).
    var keyHandle: TrimHandle?
    /// The waveform was clicked: the player jumps there.
    var onSeek: (Double) -> Void
    /// The waveform was clicked: the panel takes the keyboard back.
    var onTap: () -> Void = {}
    /// A handle was pressed or its drag began (before its first move): the panel gives it the keyboard.
    var onDragBegan: (TrimHandle) -> Void = { _ in }
    /// A handle moved (dragged, or by VoiceOver's adjust): the panel decides where the player goes.
    var onHandleMoved: (TrimHandle) -> Void
    var onDragEnded: (TrimHandle) -> Void

    static let height: CGFloat = 52
    private static let barWidth: CGFloat = 2
    private static let pitch: CGFloat = 3.5
    private static let knob: CGFloat = 16
    /// A handle's grab area on its outer side, from the knob's center.
    private static let outerGrab: CGFloat = 30

    @State private var dragging: TrimHandle?
    /// The handle's time when its drag began: the handle follows the pointer's movement, not its position.
    @State private var dragOrigin: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var span: Double { max(duration, 1) }
    private var start: Double { state.start }
    private var end: Double { state.end }

    var body: some View {
        GeometryReader { g in
            let w = max(g.size.width, 1)
            let x0 = CGFloat(start / span) * w, x1 = CGFloat(end / span) * w
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(SZ.accentRow)
                    .frame(width: max(0, x1 - x0), height: Self.height)
                    .offset(x: x0)
                content(width: w, kept: (x0 / w)...(max(x0, x1) / w))
                if let t = playhead, t > 0, t < duration {
                    Capsule().fill(SZ.label.opacity(0.85))
                        .frame(width: 1.5, height: Self.height - 8)
                        .offset(x: CGFloat(t / span) * w - 0.75, y: 4)
                        .allowsHitTesting(false)
                }
                handle(.start, x: x0, width: w)
                handle(.end, x: x1, width: w)
            }
            .frame(width: w, height: Self.height, alignment: .topLeading)
            // A content shape also bounds where the children can be hit: it reaches past both ends by the handles'
            // outer grab area, or a handle at 0:00 or at the call's end could only be grabbed by its inner half.
            .contentShape(GrabArea(outset: Self.outerGrab))
            .gesture(SpatialTapGesture().onEnded { v in
                onTap()
                onSeek(min(max(0, Double(v.location.x / w) * span), duration))
            })
        }
        .frame(height: Self.height)
    }

    @ViewBuilder private func content(width w: CGFloat, kept: ClosedRange<CGFloat>) -> some View {
        switch wave {
        case .ready(let peaks):
            let values = Self.bars(peaks, count: Int((w + Self.pitch - Self.barWidth) / Self.pitch))
            ZStack {
                WaveBars(values: values, barWidth: Self.barWidth, pitch: Self.pitch, kept: kept, inside: false)
                    .fill(SZ.label2).opacity(0.35)
                WaveBars(values: values, barWidth: Self.barWidth, pitch: Self.pitch, kept: kept, inside: true)
                    .fill(SZ.accent)
            }
            .padding(.vertical, 6)
            .frame(width: w, height: Self.height)
            .accessibilityHidden(true)
        case .loading:
            // A calm row of dots where the waveform will be.
            let values = Array(repeating: CGFloat(0), count: Int((w + Self.pitch - Self.barWidth) / Self.pitch))
            WaveBars(values: values, barWidth: Self.barWidth, pitch: Self.pitch, kept: 0...1, inside: true)
                .fill(SZ.label3)
                .frame(width: w, height: Self.height)
                .accessibilityLabel(L("Строю волну…"))
        case .failed:
            HStack(spacing: 6) {
                Image(systemName: "waveform.slash").accessibilityHidden(true)
                Text(L("Волну не получилось построить: звук не читается."))
                    .lineLimit(2).multilineTextAlignment(.center)
            }
            .szFont(.caption).foregroundStyle(SZ.label2)
            .padding(.horizontal, 24)
            .frame(width: w, height: Self.height)
        }
    }

    /// The loudest peak of each group, `count` bars in all.
    private static func bars(_ peaks: [Float], count: Int) -> [CGFloat] {
        guard count > 0, !peaks.isEmpty else { return [] }
        return (0..<count).map { i in
            let a = i * peaks.count / count
            let b = max(a + 1, (i + 1) * peaks.count / count)
            return CGFloat(peaks[a..<min(b, peaks.count)].max() ?? 0)
        }
    }

    // MARK: Handles

    private func move(_ h: TrimHandle, by seconds: Double) {
        state.set(h, to: state.value(h) + seconds, duration: duration)
        onHandleMoved(h)
    }

    private func handle(_ h: TrimHandle, x: CGFloat, width w: CGFloat) -> some View {
        let focused = keyHandle == h
        let active = dragging == h
        // 44 pt to grab, mostly on the outer side: two handles close together are still both reachable.
        let outer = Self.outerGrab, inner: CGFloat = 14
        let left = h == .start ? outer : inner
        return ZStack {
            Capsule().fill(SZ.accent).frame(width: 2, height: Self.height)
            Circle()
                .fill(Color.white)
                .frame(width: Self.knob, height: Self.knob)
                .shadow(color: .black.opacity(0.28), radius: 1.5, y: 0.5)
                .overlay { Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5) }
                .overlay { Capsule().fill(SZ.accent).frame(width: 1.5, height: 7) }
                .overlay {
                    if focused { Circle().stroke(SZ.accent.opacity(0.5), lineWidth: 3).padding(-2.5) }
                }
                .scaleEffect(active && !reduceMotion ? 1.12 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: active)
        }
        .frame(width: Self.knob, height: Self.height)
        .padding(.leading, left - Self.knob / 2)
        .padding(.trailing, outer + inner - left - Self.knob / 2)
        .contentShape(Rectangle())
        .offset(x: x - left)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if dragging != h {
                        dragging = h
                        dragOrigin = state.value(h)
                        onDragBegan(h)
                    }
                    state.set(h, to: dragOrigin + Double(v.translation.width / w) * span, duration: duration)
                    onHandleMoved(h)
                }
                .onEnded { _ in
                    dragging = nil
                    onDragEnded(h)
                }
        )
        .pointerStyle(.columnResize)
        // The keys come through the panel's TrimKeyView (see TrimKeyboard), not SwiftUI focus: a SwiftUI view only
        // takes focus on a click when the system's Keyboard navigation setting is on.
        .accessibilityElement()
        .accessibilityLabel(h == .start ? L("Начало, %@", clock(start)) : L("Конец, %@", clock(end)))
        .accessibilityHint(L("Стрелки двигают на секунду, с Shift на десять секунд"))
        .accessibilityAdjustableAction { d in
            switch d {
            case .increment: move(h, by: 10)
            case .decrement: move(h, by: -10)
            @unknown default: break
            }
        }
    }
}

// MARK: - Panel

/// Trim mode: the player capsule grown in place over the transcript. The waveform with the handles, the times and
/// what remains, play and "Listen to the end", Cancel and Trim; then the confirmation and the engine's progress.
struct TrimPanel: View {
    @ObservedObject var player: CallPlayer
    let duration: Double
    @Binding var state: TrimState
    let wave: WaveformState
    /// The call has a transcript (and a summary) that the trim makes again: the confirmation says so.
    let redoesText: Bool
    /// Why the call can't be trimmed right now (it started transcribing meanwhile), or nil.
    var unavailable: String?
    var onCancel: () -> Void
    var onTrim: () -> Void

    /// The player capsule's corner: the panel keeps it while it is taller.
    static let radius: CGFloat = 26
    /// "Listen to the end" plays this much before the end handle.
    static let endPreview = 5.0

    /// The player was playing when the current handle drag began: the moved handle is heard on release.
    @State private var playedBeforeDrag = false
    /// The handle the arrow keys move: the start when the panel opens, then the one last pressed.
    @State private var keyHandle = TrimHandle.start
    @StateObject private var keyboard = TrimKeyboard()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TrimWave(wave: wave, duration: duration, state: $state,
                     playhead: player.ready ? player.time : nil,
                     keyHandle: keyboard.hasKeys && state.phase == .editing ? keyHandle : nil,
                     onSeek: { player.seek($0) },
                     onTap: { keyboard.take() },
                     onDragBegan: { h in
                         keyHandle = h
                         keyboard.take()
                         playedBeforeDrag = player.isPlaying
                     },
                     onHandleMoved: handleMoved,
                     onDragEnded: dragEnded)
                .disabled(state.phase != .editing)
                .opacity(state.phase == .working ? 0.6 : 1)
            footer
        }
        // Takes the keyboard when the panel opens: the arrows and Escape work right away, whatever had it before
        // (the card's selectable text, the calls list).
        .background(TrimKeyCatcher(keyboard: keyboard, onKey: key))
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .modifier(PlayerGlass(shape: RoundedRectangle(cornerRadius: Self.radius, style: .circular)))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        // Escape when a control of the panel has SwiftUI focus (Keyboard navigation on) instead of TrimKeyView.
        .onExitCommand { _ = key(.escape, shift: false) }
        // Playback stops at the end handle whenever the panel is open, paused or not: a transcript line clicked in
        // trim mode plays to the current end too.
        .onAppear { player.pauseAt(state.end) }
        .onChange(of: state.end) { _, end in player.pauseAt(end) }
        .onChange(of: state.phase) { _, phase in
            if phase == .editing { player.pauseAt(state.end) }  // a failed trim reloads the player without it
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Обрезка записи"))
    }

    /// "Отмена" and Escape: the confirmation goes back to editing, editing closes the panel.
    private func cancel() {
        switch state.cancel() {
        case .close: onCancel()
        case .backToEditing: keyboard.take()
        case .none: break
        }
    }

    /// A key TrimKeyView caught; false lets it go on to the window.
    private func key(_ k: TrimKey, shift: Bool) -> Bool {
        switch state.key(k, shift: shift, handle: keyHandle, duration: duration) {
        case .moved(let h):
            handleMoved(h)
            return true
        case .cancel(.close):
            onCancel()
            return true
        case .cancel:
            keyboard.take()
            return true
        case .ignored:
            return false
        }
    }

    /// The player follows a moved handle: to the start itself, or to the end's last seconds (seeking onto the end
    /// would reach the stop point and pause the playback).
    private func handleMoved(_ h: TrimHandle) {
        switch h {
        case .start: player.seek(state.start)
        case .end: player.seek(max(state.start, state.end - Self.endPreview))
        }
    }

    /// When it was playing as the drag began, the moved handle is heard: the start plays on from there, the end
    /// plays its last seconds.
    private func dragEnded(_ h: TrimHandle) {
        guard playedBeforeDrag || player.isPlaying else { return }
        playedBeforeDrag = false
        switch h {
        case .start: player.playRange(from: state.start, to: state.end)
        case .end: listenToEnd()
        }
    }

    private func togglePlay() {
        if player.isPlaying {
            player.pause()
        } else {
            let t = player.time
            player.playRange(from: t >= state.start && t < state.end - 0.5 ? t : state.start, to: state.end)
        }
    }

    private func listenToEnd() {
        player.playRange(from: max(state.start, state.end - Self.endPreview), to: state.end)
    }

    @ViewBuilder private var footer: some View {
        switch state.phase {
        case .editing: editing
        case .confirming: confirming
        case .working:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("Обрезаю…")).foregroundStyle(SZ.label2)
                Spacer(minLength: 0)
            }
            .szFont(.caption)
            .frame(minHeight: 30)
        }
    }

    // MARK: Editing

    private var playControls: some View {
        HStack(spacing: 10) {
            SZPlayButton(playing: player.isPlaying, action: togglePlay)
                .disabled(player.failed)
                .help(player.isPlaying ? L("Пауза") : L("Слушать с начала обрезки"))
                .accessibilityLabel(player.isPlaying ? L("Пауза") : L("Слушать с начала обрезки"))
            Button(action: listenToEnd) {
                Label(L("Прослушать конец"), systemImage: "forward.end")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .disabled(player.failed)
            .help(L("Последние 5 секунд перед концом"))
            .fixedSize()
        }
    }

    private var times: some View {
        let kept = max(0, Int(state.end.rounded()) - Int(state.start.rounded()))
        return HStack(spacing: 6) {
            Text(verbatim: "\(clock(state.start)) → \(clock(state.end))").foregroundStyle(SZ.label)
            Text(L("останется %@", Call.clock(kept, empty: "0:00"))).foregroundStyle(SZ.label2)
        }
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(L("Отмена"), action: cancel)
            Button(L("Обрезать…")) {
                player.pause()
                state.phase = .confirming
            }
            .buttonStyle(.borderedProminent)
            .disabled(unavailable != nil)
            .help(unavailable ?? "")
        }
        .fixedSize()
    }

    /// One row when it fits; on a narrow card the times or the buttons go to a line of their own.
    private var editing: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                playControls
                times
                Spacer(minLength: 8)
                actions
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    playControls
                    Spacer(minLength: 8)
                    times
                }
                HStack {
                    Spacer(minLength: 0)
                    actions
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                playControls
                times
                HStack {
                    Spacer(minLength: 0)
                    actions
                }
            }
        }
    }

    // MARK: Confirmation

    private var confirming: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(SZ.orange)
                    .accessibilityHidden(true)
                Text(redoesText
                     ? L("Отрезанный звук удалится, вернуть его нельзя. Расшифровка и саммари будут сделаны заново.")
                     : L("Отрезанный звук удалится, вернуть его нельзя."))
                    .foregroundStyle(SZ.label)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .szFont(.caption)
            // The times stay in view while there is room for them next to the buttons.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    times
                    Spacer(minLength: 8)
                    confirmButtons
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    confirmButtons
                }
            }
        }
    }

    private var confirmButtons: some View {
        HStack(spacing: 8) {
            Button(L("Отмена"), action: cancel)
            Button(L("Обрезать и расшифровать"), role: .destructive, action: onTrim)
                .buttonStyle(.borderedProminent)
                .tint(SZ.red)
                .disabled(unavailable != nil)
                .help(unavailable ?? "")
        }
        .fixedSize()
    }
}

// MARK: - Keyboard

/// The trim panel's keyboard. Its TrimKeyView, an AppKit view behind the panel, becomes the window's first
/// responder when the panel opens, when a handle is pressed and when the waveform is clicked, so ←/→, ⇧←/⇧→ and
/// Escape reach the panel whatever the system's Keyboard navigation setting is. SwiftUI focus can't do this: a
/// click focuses a SwiftUI view only with that setting on, and the card's selectable text (an NSTextView, the
/// window's first key view) kept the keys. A text field or the card's text clicked later takes the keys as usual.
@MainActor
final class TrimKeyboard: ObservableObject {
    /// TrimKeyView is the first responder: the handle that the keys move shows its ring.
    @Published fileprivate(set) var hasKeys = false
    fileprivate weak var view: TrimKeyView?

    func take() {
        guard let v = view, let w = v.window, w.firstResponder !== v else { return }
        w.makeFirstResponder(v)
    }

    fileprivate func set(_ has: Bool) {
        // Responder changes can come in the middle of a SwiftUI update.
        DispatchQueue.main.async { [weak self] in
            if self?.hasKeys != has { self?.hasKeys = has }
        }
    }
}

final class TrimKeyView: NSView {
    fileprivate weak var keyboard: TrimKeyboard?
    var onKey: (TrimKey, Bool) -> Bool = { _, _ in false }

    override var acceptsFirstResponder: Bool { true }
    // Clicks go to the panel's controls under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // On the next turn: the panel is in the window's view tree by then.
        DispatchQueue.main.async { [weak self] in self?.keyboard?.take() }
    }

    override func becomeFirstResponder() -> Bool {
        keyboard?.set(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        keyboard?.set(false)
        return true
    }

    /// ←, →, with or without Shift, and Escape; any other modifier leaves the key to the menus and the window.
    static func key(code: UInt16, modifiers: NSEvent.ModifierFlags) -> (TrimKey, shift: Bool)? {
        let mods = modifiers.intersection([.command, .option, .control, .shift])
        guard mods.subtracting(.shift).isEmpty else { return nil }
        switch code {
        case 123: return (.left, mods.contains(.shift))
        case 124: return (.right, mods.contains(.shift))
        case 53: return (.escape, false)
        default: return nil
        }
    }

    override func keyDown(with e: NSEvent) {
        if let (k, shift) = Self.key(code: e.keyCode, modifiers: e.modifierFlags), onKey(k, shift) { return }
        super.keyDown(with: e)
    }

    override func cancelOperation(_ sender: Any?) {
        if !onKey(.escape, false) { super.cancelOperation(sender) }
    }
}

struct TrimKeyCatcher: NSViewRepresentable {
    let keyboard: TrimKeyboard
    let onKey: (TrimKey, Bool) -> Bool

    func makeNSView(context: Context) -> TrimKeyView {
        let v = TrimKeyView(frame: .zero)
        v.keyboard = keyboard
        keyboard.view = v
        v.onKey = onKey
        return v
    }

    func updateNSView(_ v: TrimKeyView, context: Context) {
        v.onKey = onKey
    }
}

// MARK: - Hint

/// "Первые 6 минут тишина.", "Последние 4 минуты тишина.", "В начале 6 минут и в конце 4 минуты тишина."
func trimHintText(_ h: TrimHint) -> String {
    // l10n-ignore-start: plural forms are chosen in SZW.count
    func minutes(_ n: Int) -> String { SZW.count(n, ru: ("минута", "минуты", "минут"), en: ("minute", "minutes")) }
    // l10n-ignore-end
    let head = h.headMinutes, tail = h.tailMinutes
    if head > 0 && tail > 0 { return L("В начале %@ и в конце %@ тишина.", minutes(head), minutes(tail)) }
    if head > 0 {
        if head == 1 { return L("Первая минута тишина.") }
        return SZW.ruForm(head) == 0 ? L("Первая %@ тишина.", minutes(head)) : L("Первые %@ тишина.", minutes(head))
    }
    if tail == 1 { return L("Последняя минута тишина.") }
    return SZW.ruForm(tail) == 0 ? L("Последняя %@ тишина.", minutes(tail)) : L("Последние %@ тишина.", minutes(tail))
}

/// The card's quiet notice when the engine measured a silent start or end: "Обрезать" opens trim mode on the
/// speech edges, "×" never offers it for this call again.
struct TrimHintBanner: View {
    let hint: TrimHint
    var onTrim: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        SZBanner(trimHintText(hint), L("Обрезать?")) {
            Button(L("Обрезать"), action: onTrim)
                .controlSize(.small)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SZ.label2)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Больше не предлагать для этого звонка"))
            .accessibilityLabel(L("Больше не предлагать для этого звонка"))
        }
    }
}
