// The summary and the transcript as one selectable text each (TextKit 1 NSTextView inside the card's scroll view):
// a selection runs across lines, sections and paragraphs, ⌘A selects all of it, ⌘C copies the plain text TextDoc
// makes. Row highlights, the star, task rings, owners and group boxes are drawn around the text.

import AppKit
import SozvonCore
import SwiftUI

extension SZ {
    /// The NSColor behind a design color (dynamic: it follows the appearance it is drawn in).
    static func ns(_ c: Color) -> NSColor { NSColor(c) }
}

/// A read-only text view over a TextDoc that sizes to its text (the card scrolls, not the text view).
class DocTextView: NSTextView {
    private(set) var doc = TextDoc()
    /// Each paragraph's line fragments (spacing included), in view coordinates; nil after a change.
    private var rectsCache: [NSRect]?

    convenience init() {
        let storage = NSTextStorage()
        let lm = NSLayoutManager()
        lm.allowsNonContiguousLayout = false
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        // The container follows the frame by hand (trackFrame): SwiftUI's size probes resize it in between.
        tc.widthTracksTextView = false
        lm.addTextContainer(tc)
        self.init(frame: NSRect(x: 0, y: 0, width: 600, height: 10), textContainer: tc)
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        usesFindBar = false
        isAutomaticLinkDetectionEnabled = false
        linkTextAttributes = [.foregroundColor: SZ.ns(SZ.accent), .cursor: NSCursor.pointingHand]
    }

    func set(_ doc: TextDoc, _ text: NSAttributedString) {
        self.doc = doc
        textStorage?.setAttributedString(text)
        setSelectedRange(NSRange(location: 0, length: 0))
        rectsCache = nil
        heights = [:]
        needsDisplay = true
    }

    /// Heights by width for the current text: SwiftUI asks for several widths, laying a long transcript out is slow.
    private var heights: [CGFloat: CGFloat] = [:]

    /// The height of the text laid out `width` wide. The text stays laid out at the view's own width.
    func fittingHeight(width: CGFloat) -> CGFloat {
        let w = width.rounded()
        if let h = heights[w] { return h }
        guard let tc = textContainer, let lm = layoutManager else { return 0 }
        tc.size = NSSize(width: w, height: CGFloat.greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let h = ceil(lm.usedRect(for: tc).height)
        heights[w] = h
        trackFrame()
        return h
    }

    /// The text container as wide as the view (a size probe may have changed it).
    private func trackFrame() {
        guard let tc = textContainer, frame.width > 1, abs(tc.size.width - frame.width) > 0.5 else { return }
        tc.size = NSSize(width: frame.width, height: CGFloat.greatestFiniteMagnitude)
        rectsCache = nil
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        trackFrame()
    }

    var paragraphRects: [NSRect] {
        if let r = rectsCache { return r }
        guard let lm = layoutManager, let tc = textContainer else { return [] }
        lm.ensureLayout(for: tc)
        let origin = textContainerOrigin
        let r = doc.paragraphs.map { p -> NSRect in
            let chars = p.range.length > 0 ? p.range : NSRange(location: min(p.range.location, max(0, doc.length - 1)), length: doc.length > 0 ? 1 : 0)
            let glyphs = lm.glyphRange(forCharacterRange: chars, actualCharacterRange: nil)
            var u = NSRect.null
            lm.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in u = u.union(rect) }
            return u.isNull ? .zero : u.offsetBy(dx: origin.x, dy: origin.y)
        }
        rectsCache = r
        return r
    }

    /// The paragraph under a point (its whole row, spacing included).
    func paragraph(at point: NSPoint) -> Int? {
        let rects = paragraphRects
        var lo = 0, hi = rects.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if point.y < rects[mid].minY { hi = mid - 1 } else if point.y >= rects[mid].maxY { lo = mid + 1 } else { return mid }
        }
        return nil
    }

    /// The baseline of the first line of a paragraph, in view coordinates.
    func firstBaseline(_ p: Int) -> CGFloat? {
        guard let lm = layoutManager, doc.paragraphs.indices.contains(p), doc.length > 0 else { return nil }
        let g = lm.glyphIndexForCharacter(at: min(doc.paragraphs[p].range.location, doc.length - 1))
        let line = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        return line.minY + lm.location(forGlyphAt: g).y + textContainerOrigin.y
    }

    /// Where a range of characters is drawn, in view coordinates.
    func rect(of range: NSRange) -> NSRect? {
        guard let lm = layoutManager, let tc = textContainer, range.location != NSNotFound, NSMaxRange(range) <= doc.length else { return nil }
        let g = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return lm.boundingRect(forGlyphRange: g, in: tc).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    // MARK: Copy: the plain text of the doc ("[1:12] Anna: …", "• item"), never the tabs it is laid out with.

    var selectionCopyText: String {
        selectedRanges.map { doc.copyText($0.rangeValue) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string else { return false }
        let s = selectionCopyText
        return !s.isEmpty && pboard.setString(s, forType: .string)
    }

    override func copy(_ sender: Any?) {
        let s = selectionCopyText
        guard !s.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    // MARK: Scrolling the card

    /// Scrolls the card's scroll view to show `rect` (view coordinates): centered, or just into view.
    func reveal(_ rect: NSRect, center: Bool, animated: Bool = true) {
        guard let sv = enclosingScrollView else {
            scrollToVisible(rect)
            return
        }
        let clip = sv.contentView
        let r = convert(rect, to: clip)
        let insets = sv.contentInsets
        let visible = NSRect(x: clip.bounds.minX, y: clip.bounds.minY + insets.top, width: clip.bounds.width,
                             height: clip.bounds.height - insets.top - insets.bottom)
        var y = clip.bounds.minY
        if center || r.height > visible.height {
            y = r.midY - insets.top - visible.height / 2
            if r.height > visible.height { y = r.minY - insets.top - 8 }
        } else if r.minY < visible.minY {
            y = r.minY - insets.top - 8
        } else if r.maxY > visible.maxY {
            y = r.maxY - clip.bounds.height + insets.bottom + 8
        } else {
            return
        }
        let target = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: clip.bounds.minX, y: y), size: clip.bounds.size)).origin
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(target)
            }
        } else {
            clip.setBoundsOrigin(target)
        }
        sv.reflectScrolledClipView(clip)
    }

    /// Draws an SF Symbol centered in `rect`, in a color resolved for the appearance being drawn.
    func drawSymbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, in rect: NSRect) {
        var resolved = color
        effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) ?? color }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [resolved]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let s = img.size
        let r = NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height)
        img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    #if SOZVON_PREVIEW
    /// Screenshot check of a selection across paragraphs (--select-demo).
    func selectDemo(_ range: NSRange, reveal: Bool = false) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, NSMaxRange(range) <= self.doc.length else { return }
            self.window?.makeFirstResponder(self)
            self.setSelectedRange(range)
            if reveal, let r = self.rect(of: range) { self.reveal(r, center: true, animated: false) }
        }
    }
    #endif
}

/// Paragraph styles and fonts of the two texts.
enum DocStyle {
    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }

    /// SZTextStyle's line height: the extra over the font's natural line height, split around the line.
    static func extra(_ s: SZTextStyle) -> CGFloat { max(0, s.lineHeight - s.naturalLineHeight) }

    static func paragraph(_ build: (NSMutableParagraphStyle) -> Void) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.tabStops = []
        build(p)
        return p
    }
}

// MARK: - Transcript

/// Lets the card scroll the transcript (to the playing paragraph, to a find match): it scrolls the card's scroll
/// view, since the transcript is one text view in it rather than rows.
@MainActor
final class TranscriptScroller {
    weak var view: TranscriptTextView?

    /// Shows paragraph number `line` (just into view, as playback follows the text).
    func reveal(line: Int) {
        guard let v = view, let p = v.doc.paragraph(forLine: line), v.paragraphRects.indices.contains(p) else { return }
        v.reveal(v.paragraphRects[p], center: false)
    }

    /// Centers a find match.
    func reveal(_ match: TranscriptFind.Match) {
        guard let v = view, let r = TranscriptText.range(of: match, lines: v.lines, in: v.doc), let rect = v.rect(of: r) else { return }
        v.reveal(rect, center: true)
    }
}

/// The transcript text: a plain click on a paragraph plays from its start (after the double-click interval, so a
/// double or triple click only selects), a drag selects; the context menu acts on the paragraph under the pointer.
final class TranscriptTextView: DocTextView {
    /// The paragraphs the text was built from, by number.
    var lines: [TranscriptLine] = []
    var canPlay = false
    var canEdit = false
    var canRemember = false
    var onPlay: (Int) -> Void = { _ in }
    /// Paragraph number and which of the equal paragraphs it is.
    var onRename: (Int, Int) -> Void = { _, _ in }
    var onFix: (Int, Int) -> Void = { _, _ in }
    var onRemember: (String) -> Void = { _ in }
    /// The playing paragraph (paragraph index in the doc).
    var current: Int? {
        didSet { if current != oldValue { markCurrent(old: oldValue) } }
    }
    private var pendingPlay: DispatchWorkItem?
    private var starTips: [NSView.ToolTipTag] = []

    static let rowPad: CGFloat = 6
    static let rowGap: CGFloat = 6
    static let timeWidth: CGFloat = 44
    static let starSpace: CGFloat = 20

    /// The text of a transcript: time column, speaker names, words; headings and stray lines.
    static func attributed(_ d: TextDoc) -> NSAttributedString {
        let out = NSMutableAttributedString(string: d.string)
        let s = SZTextStyle.transcript
        let extra = DocStyle.extra(s)
        let pad = rowPad, textX = pad + timeWidth + 10
        let line = { (starred: Bool) in DocStyle.paragraph { p in
            p.firstLineHeadIndent = pad
            p.headIndent = textX
            p.tailIndent = -(pad + (starred ? starSpace : 0))
            p.tabStops = [NSTextTab(textAlignment: .right, location: pad + timeWidth), NSTextTab(textAlignment: .left, location: textX)]
            p.lineSpacing = extra
            // lineSpacing already puts the line height's extra under every line.
            p.paragraphSpacingBefore = pad + extra / 2
            p.paragraphSpacing = pad - extra / 2 + rowGap
        } }
        let plain = line(false), starredStyle = line(true)
        let heading = DocStyle.paragraph { p in
            p.firstLineHeadIndent = 4
            p.headIndent = 4
            p.paragraphSpacing = 4 + rowGap
        }
        let aside = DocStyle.paragraph { p in
            p.lineSpacing = extra
            p.paragraphSpacing = rowGap
        }
        for p in d.paragraphs {
            let r = NSRange(location: p.range.location, length: min(p.range.length + 1, d.length - p.range.location))
            switch p.kind {
            case .line(_, _, let starred): out.addAttribute(.paragraphStyle, value: starred ? starredStyle : plain, range: r)
            case .heading: out.addAttribute(.paragraphStyle, value: heading, range: r)
            default: out.addAttribute(.paragraphStyle, value: aside, range: r)
            }
        }
        for (i, seg) in d.segments.enumerated() {
            let r = NSRange(location: d.starts[i], length: seg.text.utf16.count)
            let (font, color): (NSFont, Color) = switch seg.role {
            case .time: (.monospacedDigitSystemFont(ofSize: 12, weight: .regular), SZ.label3)
            case .speaker(let unconfirmed): (DocStyle.font(s.size, .semibold), unconfirmed ? SZ.coral : SZ.label)
            case .heading: (DocStyle.font(15, .semibold), SZ.label)
            case .aside: (DocStyle.font(s.size), SZ.label2)
            default: (DocStyle.font(s.size), SZ.label)
            }
            out.addAttributes([.font: font, .foregroundColor: SZ.ns(color)], range: r)
        }
        return out
    }

    /// Voiced speakers' paragraphs say so on hover, as their rows did.
    static func addTips(_ out: NSMutableAttributedString, _ d: TextDoc, lines: [TranscriptLine], voiced: Set<String>) {
        for p in d.paragraphs {
            guard case .line(let n, _, _) = p.kind, lines.indices.contains(n), voiced.contains(lines[n].speaker.lowercased()) else { continue }
            out.addAttribute(.toolTip, value: L("Голос «%@» сохранён: Sozvon узнаёт этого человека в следующих звонках", lines[n].speaker),
                             range: p.range)
        }
    }

    override func set(_ doc: TextDoc, _ text: NSAttributedString) {
        super.set(doc, text)
        let c = current
        current = nil
        current = c
        updateStarTips()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if changed { updateStarTips() }
    }

    /// "Marked as important" on hover over a star, as on the star of a row.
    private func updateStarTips() {
        for tag in starTips { removeToolTip(tag) }
        starTips = []
        for (i, p) in doc.paragraphs.enumerated() {
            guard case .line(_, _, true) = p.kind, let base = firstBaseline(i) else { continue }
            let star = NSRect(x: bounds.width - Self.rowPad - 10, y: base - 10, width: 10, height: 10)
            starTips.append(addToolTip(star, owner: L("Отмечено как важное во время записи") as NSString, userData: nil))
        }
    }

    /// The playing paragraph's time turns accent (its row is drawn in drawBackground).
    private func markCurrent(old: Int?) {
        guard let lm = layoutManager else { return }
        for (p, on) in [(old, false), (current, true)] {
            guard let p, doc.paragraphs.indices.contains(p), let t = doc.segment(containing: doc.paragraphs[p].range.location),
                  t.segment.role == .time else { continue }
            if on {
                lm.addTemporaryAttribute(.foregroundColor, value: SZ.ns(SZ.accent), forCharacterRange: t.range)
            } else {
                lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: t.range)
            }
        }
        needsDisplay = true
    }

    /// Find: every match tinted, the current one in accent with white text.
    func highlight(_ found: [TranscriptFind.Match], current: TranscriptFind.Match?) {
        guard let lm = layoutManager else { return }
        let all = NSRange(location: 0, length: doc.length)
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
        for m in found {
            guard let r = TranscriptText.range(of: m, lines: lines, in: doc) else { continue }
            let isCurrent = m == current
            lm.addTemporaryAttribute(.backgroundColor, value: isCurrent ? SZ.ns(SZ.accent) : SZ.ns(SZ.yellow).withAlphaComponent(0.45),
                                     forCharacterRange: r)
            if isCurrent { lm.addTemporaryAttribute(.foregroundColor, value: NSColor.white, forCharacterRange: r) }
        }
        let c = self.current
        self.current = nil
        self.current = c
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let rects = paragraphRects
        for (i, p) in doc.paragraphs.enumerated() {
            guard case .line(_, _, let starred) = p.kind, rects.indices.contains(i) else { continue }
            let row = NSRect(x: 0, y: rects[i].minY, width: bounds.width, height: rects[i].height - Self.rowGap)
            guard row.intersects(rect) else { continue }
            let shape = NSBezierPath(roundedRect: row, xRadius: SZ.radiusControl, yRadius: SZ.radiusControl)
            if i == current {
                SZ.ns(SZ.accentRow).setFill()
                shape.fill()
                NSGraphicsContext.saveGraphicsState()
                shape.addClip()
                SZ.ns(SZ.accent).setFill()
                NSRect(x: row.minX, y: row.minY, width: 2, height: row.height).fill()
                NSGraphicsContext.restoreGraphicsState()
            } else if starred {
                SZ.ns(SZ.starRow).setFill()
                shape.fill()
            }
        }
    }

    /// The stars, above the selection highlight.
    override func draw(_ dirty: NSRect) {
        super.draw(dirty)
        let rects = paragraphRects
        for (i, p) in doc.paragraphs.enumerated() {
            guard case .line(_, _, true) = p.kind, rects.indices.contains(i), rects[i].intersects(dirty),
                  let base = firstBaseline(i) else { continue }
            drawSymbol("star.fill", size: 10, color: SZ.ns(SZ.yellow),
                       in: NSRect(x: bounds.width - Self.rowPad - 10, y: base - 10, width: 10, height: 10))
        }
    }

    // MARK: Click to play

    override func mouseDown(with e: NSEvent) {
        pendingPlay?.cancel()
        pendingPlay = nil
        let down = convert(e.locationInWindow, from: nil)
        super.mouseDown(with: e)  // tracks the selection until the mouse goes up
        guard canPlay, let window else { return }
        let up = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let modified = !e.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty
        guard ClickToPlay.plays(clickCount: e.clickCount, modified: modified, moved: Double(hypot(up.x - down.x, up.y - down.y)),
                                selectionLength: selectedRange().length),
              let p = paragraph(at: down), case .line(let n, _, _) = doc.paragraphs[p].kind else { return }
        // Wait out the double-click interval: a second click selects a word instead.
        let work = DispatchWorkItem { [weak self] in self?.onPlay(n) }
        pendingPlay = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }

    // MARK: Context menu

    override func menu(for e: NSEvent) -> NSMenu? {
        let at = convert(e.locationInWindow, from: nil)
        guard let p = paragraph(at: at), case .line(let n, let occurrence, _) = doc.paragraphs[p].kind,
              lines.indices.contains(n) else { return super.menu(for: e) }
        let l = lines[n]
        let menu = NSMenu()
        menu.autoenablesItems = false
        if canPlay { menu.addItem(ActionMenuItem(L("Слушать отсюда")) { [weak self] in self?.onPlay(n) }) }
        // Inside a selection: the selection; elsewhere: this paragraph.
        let char = characterIndexForInsertion(at: at)
        let inSelection = selectedRanges.contains { let r = $0.rangeValue; return r.length > 0 && NSLocationInRange(char, r) }
        let text = inSelection ? selectionCopyText : doc.copyText(doc.paragraphs[p].range)
        menu.addItem(ActionMenuItem(L("Копировать")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        })
        menu.addItem(.separator())
        let rename = ActionMenuItem(L("Переименовать говорящего…")) { [weak self] in self?.onRename(n, occurrence) }
        rename.isEnabled = canEdit
        menu.addItem(rename)
        if canRemember, case .speaker(true)? = doc.segment(containing: (doc.paragraphs[p].textStart ?? 1) - 2)?.segment.role {
            let remember = ActionMenuItem(L("Запомнить голос «%@»", l.speaker)) { [weak self] in self?.onRemember(l.speaker) }
            remember.isEnabled = canEdit
            menu.addItem(remember)
        }
        let fix = ActionMenuItem(L("Исправить слово…")) { [weak self] in self?.onFix(n, occurrence) }
        fix.isEnabled = canEdit
        menu.addItem(fix)
        return menu
    }
}

/// The transcript text in the card.
struct TranscriptPane: NSViewRepresentable {
    let doc: TranscriptDoc
    let me: String
    let voiced: Set<String>
    /// The playing paragraph's number.
    let current: Int?
    let canPlay: Bool
    let canEdit: Bool
    let canRemember: Bool
    let found: [TranscriptFind.Match]
    let currentFound: TranscriptFind.Match?
    let scroller: TranscriptScroller?
    var onPlay: (TranscriptLine) -> Void
    var onRename: (FixTarget) -> Void
    var onRemember: (String) -> Void
    var onFix: (FixTarget) -> Void

    final class Coordinator {
        /// What the text was built from.
        var built: (id: UUID, me: String, voiced: Set<String>)?
        var found: [TranscriptFind.Match] = []
        var currentFound: TranscriptFind.Match?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TranscriptTextView {
        let v = TranscriptTextView()
        v.setAccessibilityLabel(L("Расшифровка"))
        return v
    }

    func updateNSView(_ v: TranscriptTextView, context: Context) {
        let c = context.coordinator
        scroller?.view = v
        let lines = doc.lines
        if c.built?.id != doc.id || c.built?.me != me || c.built?.voiced != voiced {
            let entries: [TranscriptText.Entry] = doc.items.map {
                switch $0.kind {
                case .line(let l, _, _): .line(l)
                case .other(let s): .other(s)
                }
            }
            let d = TranscriptText.build(entries, me: me, voiced: voiced)
            let text = NSMutableAttributedString(attributedString: TranscriptTextView.attributed(d))
            TranscriptTextView.addTips(text, d, lines: lines, voiced: voiced)
            v.lines = lines
            v.set(d, text)
            c.built = (doc.id, me, voiced)
            c.found = []
            c.currentFound = nil
            #if SOZVON_PREVIEW
            if CommandLine.arguments.contains("--select-demo"), d.paragraphs.count > 4 {
                let from = d.paragraphs[2].range.location + 20, to = NSMaxRange(d.paragraphs[4].range) - 10
                v.selectDemo(NSRange(location: from, length: max(0, to - from)))
            }
            #endif
        }
        v.canPlay = canPlay
        v.canEdit = canEdit
        v.canRemember = canRemember
        v.onPlay = { n in if lines.indices.contains(n) { onPlay(lines[n]) } }
        v.onRename = { n, o in if lines.indices.contains(n) { onRename(FixTarget(line: lines[n], occurrence: o)) } }
        v.onFix = { n, o in if lines.indices.contains(n) { onFix(FixTarget(line: lines[n], occurrence: o)) } }
        v.onRemember = onRemember
        if c.found != found || c.currentFound != currentFound {
            c.found = found
            c.currentFound = currentFound
            v.highlight(found, current: currentFound)
        }
        v.current = current.flatMap { v.doc.paragraph(forLine: $0) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TranscriptTextView, context: Context) -> CGSize? {
        let w = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 600
        return CGSize(width: w, height: nsView.fittingHeight(width: w))
    }
}

// MARK: - Summary

/// The summary: one text across all its sections, each section's lines in a group box under its title, with a
/// Copy button for the section.
final class SummaryDocView: NSView {
    let text = SummaryTextView()
    private var boxes: [Int: NSBox] = [:]
    private var buttons: [Int: NSView] = [:]
    private var owners: [Int: String] = [:]

    static let pad: CGFloat = 12
    static let padV: CGFloat = 10
    static let buttonSpace: CGFloat = 110

    override var isFlipped: Bool { true }

    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: 600, height: 10))
        addSubview(text)
        text.setAccessibilityLabel(L("Саммари"))
    }

    func set(_ markdown: String) {
        let d = SummaryText.build(SummaryBlocks.split(markdown))
        text.set(d, Self.attributed(d))
        boxes.values.forEach { $0.removeFromSuperview() }
        buttons.values.forEach { $0.removeFromSuperview() }
        boxes = [:]
        buttons = [:]
        for p in d.paragraphs {
            switch p.kind {
            case .title(let b):
                let title = (d.string as NSString).substring(with: p.range)
                let button = NSHostingView(rootView: SummaryCopyButton(title: title) { [weak self] in self?.copy(block: b) })
                button.frame.size = button.fittingSize
                addSubview(button)
                buttons[b] = button
            case .text(let b, _) where boxes[b] == nil:
                let box = NSBox()
                box.boxType = .primary
                box.titlePosition = .noTitle
                addSubview(box, positioned: .below, relativeTo: text)
                boxes[b] = box
            default: break
            }
        }
        #if SOZVON_PREVIEW
        // From the middle of the next to last section's last line into the last section, which is scrolled to.
        if CommandLine.arguments.contains("--select-demo"), let last = d.paragraphs.lastIndex(where: { if case .title = $0.kind { true } else { false } }),
           last >= 2, last + 2 < d.paragraphs.count {
            let from = d.paragraphs[last - 1].range.location + 12, to = NSMaxRange(d.paragraphs[last + 2].range) - 6
            text.selectDemo(NSRange(location: from, length: max(0, to - from)), reveal: true)
        }
        #endif
        needsLayout = true
    }

    private func copy(block b: Int) {
        let s = text.doc.copyText(SummaryText.range(ofBlock: b, in: text.doc))
        guard !s.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    func fittingHeight(width: CGFloat) -> CGFloat { text.fittingHeight(width: width) }

    override func layout() {
        super.layout()
        text.frame = bounds
        let rects = text.paragraphRects
        var spans: [Int: NSRect] = [:]
        for (i, p) in text.doc.paragraphs.enumerated() where rects.indices.contains(i) {
            switch p.kind {
            case .text(let b, _): spans[b] = (spans[b] ?? .null).union(rects[i])
            case .title(let b):
                if let button = buttons[b], let base = text.firstBaseline(i) {
                    let s = button.fittingSize
                    button.frame = NSRect(x: bounds.width - s.width, y: (base - 5.5 - s.height / 2).rounded(), width: s.width, height: s.height)
                }
            default: break
            }
        }
        for (b, box) in boxes {
            guard let r = spans[b] else { continue }
            box.frame = NSRect(x: 0, y: r.minY, width: bounds.width, height: r.height)
        }
    }

    /// The summary's text: titles, lines, bullets and tasks, with markdown emphasis and links.
    static func attributed(_ d: TextDoc) -> NSAttributedString {
        let out = NSMutableAttributedString(string: d.string)
        let s = SZTextStyle.bodyRelaxed
        let extra = DocStyle.extra(s)
        let ps = d.paragraphs
        func block(_ i: Int) -> Int? {
            guard ps.indices.contains(i) else { return nil }
            switch ps[i].kind {
            case .text(let b, _): return b
            default: return nil
            }
        }
        for (i, p) in ps.enumerated() {
            let r = NSRange(location: p.range.location, length: min(p.range.length + 1, d.length - p.range.location))
            let style: NSParagraphStyle
            switch p.kind {
            case .title:
                style = DocStyle.paragraph { st in
                    st.firstLineHeadIndent = 4
                    st.headIndent = 4
                    st.tailIndent = -buttonSpace
                    st.paragraphSpacingBefore = i == 0 ? 0 : 24
                    st.paragraphSpacing = 8
                }
            case .text(let b, let line):
                let first = block(i - 1) != b, last = block(i + 1) != b
                // After a section's last line, the next section's title brings the 24 between sections.
                var after: CGFloat = 10
                if case .bullet(_, false) = line { after = 4 }
                if last { after = padV }
                var owner: CGFloat = 0
                if case .task(let o, _) = line, !o.isEmpty {
                    owner = ceil((o as NSString).size(withAttributes: [.font: DocStyle.font(12)]).width) + 8
                }
                style = DocStyle.paragraph { st in
                    switch line {
                    case .bullet:
                        st.firstLineHeadIndent = pad + 5
                        st.headIndent = pad + 18
                        st.tabStops = [NSTextTab(textAlignment: .left, location: pad + 18)]
                    case .task:
                        st.firstLineHeadIndent = pad
                        st.headIndent = pad + 24
                        st.tabStops = [NSTextTab(textAlignment: .left, location: pad + 24)]
                    default:
                        st.firstLineHeadIndent = pad
                        st.headIndent = pad
                    }
                    st.tailIndent = -(pad + owner)
                    st.lineSpacing = extra
                    // lineSpacing already puts the line height's extra under every line.
                    st.paragraphSpacingBefore = (first ? padV : 0) + extra / 2
                    st.paragraphSpacing = after - extra / 2
                }
            default:
                style = NSParagraphStyle.default
            }
            out.addAttribute(.paragraphStyle, value: style, range: r)
        }
        for (i, seg) in d.segments.enumerated() {
            let r = NSRange(location: d.starts[i], length: seg.text.utf16.count)
            var attrs: [NSAttributedString.Key: Any]
            switch seg.role {
            case .title: attrs = [.font: DocStyle.font(15, .semibold), .foregroundColor: SZ.ns(SZ.label)]
            case .subheading: attrs = [.font: DocStyle.font(s.size, .semibold), .foregroundColor: SZ.ns(SZ.label)]
            case .bullet: attrs = [.font: DocStyle.font(s.size), .foregroundColor: SZ.ns(SZ.label3)]
            case .doneText:
                attrs = [.font: DocStyle.font(s.size), .foregroundColor: SZ.ns(SZ.label2),
                         .strikethroughStyle: NSUnderlineStyle.single.rawValue]
            default: attrs = [.font: DocStyle.font(s.size), .foregroundColor: SZ.ns(SZ.label)]
            }
            out.addAttributes(attrs, range: r)
        }
        for inline in d.inlines {
            out.enumerateAttribute(.font, in: inline.range) { value, r, _ in
                guard let f = value as? NSFont else { return }
                var font = f
                if inline.style.contains(.code) { font = .monospacedSystemFont(ofSize: f.pointSize, weight: .regular) }
                if inline.style.contains(.bold) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                if inline.style.contains(.italic) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                out.addAttribute(.font, value: font, range: r)
            }
            if inline.style.contains(.strikethrough) {
                out.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: inline.range)
            }
            if let url = inline.link { out.addAttribute(.link, value: url, range: inline.range) }
        }
        return out
    }
}

/// The summary's text, with task rings and owners drawn beside it.
final class SummaryTextView: DocTextView {
    /// Above the text and its selection highlight, which would cover them if drawn in the background.
    override func draw(_ dirty: NSRect) {
        super.draw(dirty)
        let v = self
        let rects = paragraphRects
        for (i, p) in doc.paragraphs.enumerated() {
            guard case .text(_, .task(let owner, let done)) = p.kind, rects.indices.contains(i), rects[i].intersects(dirty),
                  let base = firstBaseline(i) else { continue }
            let pad = SummaryDocView.pad
            v.drawSymbol(done ? "checkmark.circle.fill" : "circle", size: 14, weight: done ? .regular : .light,
                         color: SZ.ns(SZ.label3), in: NSRect(x: pad, y: base - 11.5, width: 14, height: 14))
            if !owner.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [.font: DocStyle.font(12), .foregroundColor: SZ.ns(SZ.label2)]
                let size = (owner as NSString).size(withAttributes: attrs)
                let f = DocStyle.font(12)
                (owner as NSString).draw(at: NSPoint(x: v.bounds.width - pad - size.width, y: base - f.ascender), withAttributes: attrs)
            }
        }
    }
}

/// "Copy" in a summary section's header, styled like the Notes header's Add.
struct SummaryCopyButton: View {
    let title: String
    let action: () -> Void
    @State private var copied = false

    var body: some View {
        Button {
            action()
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11, weight: .semibold))
                    .frame(width: 13)
                Text(L("Скопировать"))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(SZ.accent)
            .padding(.horizontal, 4)
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Скопировать раздел «%@»", title))
        .accessibilityLabel(L("Скопировать раздел «%@»", title))
    }
}

/// The summary in the card.
struct SummaryPane: NSViewRepresentable {
    let markdown: String

    final class Coordinator { var built: String? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SummaryDocView { SummaryDocView() }

    func updateNSView(_ v: SummaryDocView, context: Context) {
        guard context.coordinator.built != markdown else { return }
        context.coordinator.built = markdown
        v.set(markdown)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SummaryDocView, context: Context) -> CGSize? {
        let w = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 600
        return CGSize(width: w, height: nsView.fittingHeight(width: w))
    }
}
