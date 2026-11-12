// The summary and the transcript as one selectable text each: what the text view shows, what Copy puts on the
// clipboard ("[1:12] Anna: text", "• item", "- [ ] Anna: task"), and which paragraph a character belongs to.
// The Calls window draws the rest (row highlights, the star, task rings, group boxes) around these paragraphs.

import Foundation

public struct TextDoc: Sendable {
    /// How a piece of text looks.
    public enum Role: Equatable, Sendable {
        /// "\t1:12\t": the time column of a transcript paragraph.
        case time
        /// "Anna:"; unconfirmed: a named speaker whose voice isn't saved yet (coral).
        case speaker(unconfirmed: Bool)
        /// The words of a transcript paragraph.
        case words
        /// "## Расшифровка" in the transcript.
        case heading
        /// Any other line of the transcript.
        case aside
        /// A summary section title.
        case title
        /// A summary line, a bullet's or a task's text.
        case text
        /// "### Detail" inside a summary section.
        case subheading
        /// "•\t" before a bullet.
        case bullet
        /// "\t": where a task's ring is drawn.
        case ring
        /// A done task's text (struck through, secondary).
        case doneText
        /// Between paragraphs.
        case newline
    }

    /// What a paragraph is: the view styles and decorates it by this.
    public enum Kind: Equatable, Sendable {
        /// A transcript paragraph: its number, how many equal ones come before it (for edits), a star mark.
        case line(ordinal: Int, occurrence: Int, starred: Bool)
        case heading
        case aside
        /// A summary section's title.
        case title(block: Int)
        /// A line of a summary section.
        case text(block: Int, line: SummaryLine)
    }

    public enum SummaryLine: Equatable, Sendable {
        case paragraph
        case subheading
        /// One item of a bullet list: the first and last items are where the list's spacing goes.
        case bullet(first: Bool, last: Bool)
        case task(owner: String, done: Bool)
    }

    public struct Segment: Sendable {
        public var role: Role
        public var text: String
        /// What Copy writes when the selection touches this segment, whole; nil: the selected part of `text`.
        public var copy: String?
    }

    public struct Paragraph: Sendable {
        public var kind: Kind
        /// Without the newline after it (UTF-16, as NSString and the text view count).
        public var range: NSRange
        /// A transcript paragraph: where the words of `TranscriptLine.text` start.
        public var textStart: Int?
    }

    public struct InlineStyle: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let bold = InlineStyle(rawValue: 1)
        public static let italic = InlineStyle(rawValue: 2)
        public static let code = InlineStyle(rawValue: 4)
        public static let strikethrough = InlineStyle(rawValue: 8)
    }

    /// Markdown inside a summary line: emphasis and links.
    public struct Inline: Equatable, Sendable {
        public var range: NSRange
        public var style: InlineStyle
        public var link: URL?
    }

    public private(set) var segments: [Segment] = []
    /// Where each segment starts.
    public private(set) var starts: [Int] = []
    public private(set) var paragraphs: [Paragraph] = []
    public private(set) var inlines: [Inline] = []
    public private(set) var string = ""
    public private(set) var length = 0
    /// Transcript paragraph number -> paragraph index.
    private var lineParagraphs: [Int: Int] = [:]

    public init() {}

    /// Starts a paragraph; segments appended after it belong to it.
    mutating func begin(_ kind: Kind, newlineCopy: String = "\n") {
        if !paragraphs.isEmpty { add(.newline, "\n", copy: newlineCopy) }
        if case .line(let n, _, _) = kind { lineParagraphs[n] = paragraphs.count }
        paragraphs.append(Paragraph(kind: kind, range: NSRange(location: length, length: 0)))
    }

    mutating func add(_ role: Role, _ text: String, copy: String? = nil) {
        guard !text.isEmpty else { return }
        let n = text.utf16.count
        segments.append(Segment(role: role, text: text, copy: copy))
        starts.append(length)
        string += text
        length += n
        if role != .newline, !paragraphs.isEmpty {
            paragraphs[paragraphs.count - 1].range.length = length - paragraphs[paragraphs.count - 1].range.location
        }
    }

    /// Text with markdown emphasis and web links (SummaryLink); markdown that doesn't parse stays as written.
    mutating func addMarkdown(_ role: Role, _ s: String) {
        guard let a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            add(role, s)
            return
        }
        var at = length
        for run in a.runs {
            let piece = String(a[run.range].characters)
            let n = piece.utf16.count
            var style: InlineStyle = []
            // Attributes by type, not by key path (key paths to these aren't Sendable).
            let link = SummaryLink.safe(run.attributes[AttributeScopes.FoundationAttributes.LinkAttribute.self], text: piece)
            if let i = run.attributes[AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self] {
                if i.contains(.stronglyEmphasized) { style.insert(.bold) }
                if i.contains(.emphasized) { style.insert(.italic) }
                if i.contains(.code) { style.insert(.code) }
                if i.contains(.strikethrough) { style.insert(.strikethrough) }
            }
            if !style.isEmpty || link != nil {
                inlines.append(Inline(range: NSRange(location: at, length: n), style: style, link: link))
            }
            at += n
        }
        add(role, String(a.characters))
    }

    mutating func setTextStart(_ at: Int) { paragraphs[paragraphs.count - 1].textStart = at }

    /// The segment holding a character (binary search).
    private func segment(at loc: Int) -> Int? {
        guard loc >= 0, loc < length else { return nil }
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= loc { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// The segment holding a character, and where it is.
    public func segment(containing loc: Int) -> (segment: Segment, range: NSRange)? {
        guard let i = segment(at: loc) else { return nil }
        return (segments[i], NSRange(location: starts[i], length: segments[i].text.utf16.count))
    }

    /// The plain text Copy writes for a selection.
    public func copyText(_ r: NSRange) -> String {
        guard r.location != NSNotFound, r.length > 0, let first = segment(at: r.location) else { return "" }
        let end = min(NSMaxRange(r), length)
        var out = ""
        var i = first
        while i < segments.count, starts[i] < end {
            let s = segments[i]
            if let c = s.copy {
                out += c
            } else {
                let from = max(r.location, starts[i]) - starts[i]
                let to = min(end, starts[i] + s.text.utf16.count) - starts[i]
                out += (s.text as NSString).substring(with: NSRange(location: from, length: to - from))
            }
            i += 1
        }
        return out
    }

    /// The paragraph a character belongs to (a newline goes with the paragraph before it).
    public func paragraph(at loc: Int) -> Int? {
        guard loc >= 0, loc < length, !paragraphs.isEmpty else { return nil }
        var lo = 0, hi = paragraphs.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if paragraphs[mid].range.location <= loc { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// The paragraph showing transcript paragraph number `line`.
    public func paragraph(forLine line: Int) -> Int? { lineParagraphs[line] }
}

/// The transcript as one text: "\t1:12\tAnna: text" per paragraph, headings, stray lines.
public enum TranscriptText {
    public enum Entry: Sendable {
        case line(TranscriptLine)
        case other(String)
    }

    /// The engine's end-of-paragraph mark for a line starred during the recording (render.py).
    public static let star = " \u{2B50}"

    /// `voiced`: lowercased names with a saved voice; other named speakers (not `me`, not generic) are unconfirmed.
    public static func build(_ entries: [Entry], me: String, voiced: Set<String>) -> TextDoc {
        var d = TextDoc()
        var ordinal = 0
        var seen: [TranscriptLine: Int] = [:]
        for e in entries {
            switch e {
            case .line(let l):
                let starred = l.text.hasSuffix(star)
                let text = starred ? String(l.text.dropLast(star.count)) : l.text
                let occurrence = seen[l, default: 0]
                seen[l] = occurrence + 1
                d.begin(.line(ordinal: ordinal, occurrence: occurrence, starred: starred))
                ordinal += 1
                let clock = Call.clock(Int(l.start), empty: "0:00")
                d.add(.time, "\t\(clock)\t", copy: "[\(clock)] ")
                let unconfirmed = !Voices.isGenericLabel(l.speaker, me: me) && !voiced.contains(l.speaker.lowercased())
                d.add(.speaker(unconfirmed: unconfirmed), l.speaker + ":")
                d.setTextStart(d.length + 1)
                if !text.isEmpty { d.add(.words, " " + text) }
            case .other(let raw):
                let t = raw.trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t == "---" { continue }
                if t.hasPrefix("#") {
                    d.begin(.heading)
                    d.add(.heading, t.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))
                } else {
                    d.begin(.aside)
                    d.add(.aside, raw)
                }
            }
        }
        return d
    }

    /// Where a find match is in the text (`lines`: the transcript paragraphs the matches were found in).
    public static func range(of m: TranscriptFind.Match, lines: [TranscriptLine], in d: TextDoc) -> NSRange? {
        guard lines.indices.contains(m.line), let p = d.paragraph(forLine: m.line),
              let start = d.paragraphs[p].textStart else { return nil }
        let t = lines[m.line].text
        let from = t.utf16.distance(from: t.startIndex, to: m.range.lowerBound)
        let n = t.utf16.distance(from: m.range.lowerBound, to: m.range.upperBound)
        let r = NSRange(location: start + from, length: n)
        return NSMaxRange(r) <= NSMaxRange(d.paragraphs[p].range) ? r : nil
    }
}

/// The summary as one text: section titles, lines, bullets ("•\t") and tasks ("\t" where the ring goes).
public enum SummaryText {
    public static func build(_ blocks: [SummaryBlock]) -> TextDoc {
        var d = TextDoc()
        for (b, block) in blocks.enumerated() {
            // A blank line between sections in the copied text.
            let gap = "\n\n"
            var firstInBlock = true
            func begin(_ kind: TextDoc.Kind) {
                d.begin(kind, newlineCopy: firstInBlock ? gap : "\n")
                firstInBlock = false
            }
            if !block.title.isEmpty {
                begin(.title(block: b))
                d.add(.title, block.title)
            }
            for piece in SummaryBlocks.pieces(block.lines) {
                switch piece {
                case .paragraph(let s):
                    begin(.text(block: b, line: .paragraph))
                    d.addMarkdown(.text, s)
                case .heading(let s):
                    begin(.text(block: b, line: .subheading))
                    d.addMarkdown(.subheading, s)
                case .bullets(let items):
                    for (i, item) in items.enumerated() {
                        begin(.text(block: b, line: .bullet(first: i == 0, last: i == items.count - 1)))
                        d.add(.bullet, "•\t", copy: "• ")
                        d.addMarkdown(.text, item)
                    }
                case .task(let item):
                    begin(.text(block: b, line: .task(owner: item.owner, done: item.done)))
                    d.add(.ring, "\t", copy: (item.done ? "- [x] " : "- [ ] ") + (item.owner.isEmpty ? "" : item.owner + ": "))
                    d.addMarkdown(item.done ? .doneText : .text, item.task)
                }
            }
        }
        return d
    }

    /// A section from its title to its last line; NSNotFound for a block that isn't there.
    public static func range(ofBlock b: Int, in d: TextDoc) -> NSRange {
        let ps = d.paragraphs.filter {
            switch $0.kind {
            case .title(let x), .text(let x, _): return x == b
            default: return false
            }
        }
        guard let f = ps.first, let l = ps.last else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: f.range.location, length: NSMaxRange(l.range) - f.range.location)
    }
}

/// The transcript: a plain click on a paragraph plays from there; a drag, a double or triple click, or a click with
/// Shift or Command selects text instead.
public enum ClickToPlay {
    /// How far (points) the pointer may move between mouse down and up and still be a click.
    public static let slop = 4.0

    public static func plays(clickCount: Int, modified: Bool, moved: Double, selectionLength: Int) -> Bool {
        clickCount == 1 && !modified && moved < slop && selectionLength == 0
    }
}

/// Which links of a summary stay clickable. A summary is written by an assistant from what people said on the call
/// (and may come from the server), so its links are not the user's own: one click must never mount a network
/// share, open a local file or start another app through its URL scheme.
public enum SummaryLink {
    /// The link to keep for this piece of text, or nil to show the text plain. Only http and https; and when the
    /// text itself reads as an address, the link has to lead to that same host.
    public static func safe(_ url: URL?, text: String) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if let shown = shownHost(text), bare(shown) != bare(host) { return nil }
        return url
    }

    private static func bare(_ host: String) -> String { host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }

    /// The host a visible text names when it reads as a web address ("https://zoom.us/j/1", "zoom.us/j/1").
    static func shownHost(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty, !t.contains(" ") else { return nil }
        if let r = t.range(of: "://") { t = String(t[r.upperBound...]) }
        let host = String(t.prefix { $0 != "/" && $0 != "?" && $0 != "#" && $0 != ":" })
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter),
              labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }) else { return nil }
        return host
    }
}
