// The transcript in the call card: one selectable text (DocText.swift), a click on a paragraph plays from there,
// the playing paragraph is highlighted; context actions rename a speaker or fix a misheard word (and can teach the
// project).

import AppKit
import SozvonCore
import SwiftUI

/// The transcript body split into rows: paragraphs ("[MM:SS] Name: text") and anything else (headings).
struct TranscriptDoc: Sendable {
    enum Kind: Sendable {
        /// `ordinal`: paragraph number; `occurrence`: how many equal paragraphs come before it (for edits).
        case line(TranscriptLine, ordinal: Int, occurrence: Int)
        case other(String)
    }

    struct Item: Identifiable, Sendable {
        let id: Int
        let kind: Kind
    }

    static let empty = TranscriptDoc("")

    /// Tells one parse from another: the text view rebuilds its text only for a new one.
    let id = UUID()
    let items: [Item]
    /// Paragraph start times, by paragraph number.
    let starts: [TimeInterval]
    let lines: [TranscriptLine]

    init(_ text: String) {
        var items: [Item] = []
        var starts: [TimeInterval] = []
        var lines: [TranscriptLine] = []
        var seen: [TranscriptLine: Int] = [:]
        for raw in text.components(separatedBy: "\n") where !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            if let (line, _) = Transcript.parse(raw) {
                let n = seen[line, default: 0]
                seen[line] = n + 1
                items.append(Item(id: items.count, kind: .line(line, ordinal: starts.count, occurrence: n)))
                starts.append(line.start)
                lines.append(line)
            } else {
                items.append(Item(id: items.count, kind: .other(raw)))
            }
        }
        self.items = items
        self.starts = starts
        self.lines = lines
    }
}

struct TranscriptView: View {
    let doc: TranscriptDoc
    @ObservedObject var playing: PlayingLine
    /// There is audio: a plain click on a paragraph plays from there (a drag still selects).
    let canPlay: Bool
    /// Not being recorded or transcribed: edits are allowed.
    let canEdit: Bool
    /// The user's name: their lines keep the label color (as do generic labels like "Speaker 2").
    var me: String = ""
    var onPlay: (TranscriptLine) -> Void = { _ in }
    var onRename: (FixTarget) -> Void = { _ in }
    /// "Remember voice": the speaker is named right, save their voice print (nil: no audio, not offered).
    var onRememberVoice: ((String) -> Void)? = nil
    /// Speakers whose voice is saved, lowercased: a tooltip on their lines; the others' names are coral.
    var voiced: Set<String> = []
    var onFix: (FixTarget) -> Void = { _ in }
    /// Find in the transcript: what to highlight, and which of it is the current match.
    var found: [TranscriptFind.Match] = []
    var currentFound: TranscriptFind.Match? = nil
    /// Lets the card scroll to the playing paragraph and to find matches.
    var scroller: TranscriptScroller? = nil

    var body: some View {
        TranscriptPane(doc: doc, me: me, voiced: voiced, current: playing.index(in: doc.starts),
                       canPlay: canPlay, canEdit: canEdit, canRemember: onRememberVoice != nil,
                       found: found, currentFound: currentFound, scroller: scroller,
                       onPlay: onPlay, onRename: onRename, onRemember: { onRememberVoice?($0) }, onFix: onFix)
    }
}

/// ⌘F on the Transcript tab: the field, "3 of 12", Previous, Next and Close. Return goes to the next match,
/// Shift-Return to the previous one, Esc closes.
struct TranscriptFindBar: View {
    @Binding var query: String
    let index: Int
    let count: Int
    /// Grows on every ⌘F: the field takes the focus again.
    let focusRequest: Int
    var onStep: (Int) -> Void
    var onClose: () -> Void
    @FocusState private var focused: Bool

    private var status: String {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
        return count == 0 ? L("Ничего не найдено") : L("%@ из %@", String(index + 1), String(count))
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(SZ.label3).accessibilityHidden(true)
            TextField(L("Найти в расшифровке"), text: $query)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { onStep(1) }
                .onExitCommand(perform: onClose)
            Text(status).szFont(SZTextStyle(size: 12, lineHeight: 16, tabular: true)).foregroundStyle(SZ.label2).lineLimit(1)
            Button { onStep(-1) } label: { Image(systemName: "chevron.up") }
                .keyboardShortcut(.return, modifiers: .shift)
                .disabled(count == 0)
                .help(L("Предыдущее совпадение"))
                .accessibilityLabel(L("Предыдущее совпадение"))
            Button { onStep(1) } label: { Image(systemName: "chevron.down") }
                .disabled(count == 0)
                .help(L("Следующее совпадение"))
                .accessibilityLabel(L("Следующее совпадение"))
            Button(action: onClose) { Image(systemName: "xmark") }
                .help(L("Закрыть поиск"))
                .accessibilityLabel(L("Закрыть поиск"))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(SZ.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(SZ.sep).frame(height: 1) }
        .onAppear { focused = true }
        .onChange(of: focusRequest) { _, _ in focused = true }
    }
}

/// A line to fix, for `.sheet(item:)`: the line and which of the equal lines it is.
struct FixTarget: Identifiable, Hashable {
    let line: TranscriptLine
    var occurrence = 0
    var id: FixTarget { self }
}

/// What "Rename speaker" does.
enum RenameAction: Equatable {
    /// Every line of the speaker gets the new name.
    case rename(String)
    /// The name already speaks in the call: both speakers' lines become one.
    case merge(String)
    /// The name already speaks in the call: the two speakers swap (two Alexanders mixed up).
    case swap(String)
    /// Only the clicked line goes to that speaker.
    case line(String)
}

/// "Rename speaker": pick a participant or type a name; for the whole transcript or only the clicked line.
/// A name that already speaks in the call asks whether to swap the two speakers or merge them.
struct RenameSpeakerSheet: View {
    let target: FixTarget
    let lines: [TranscriptLine]
    /// Participants of the call and its project, and other speakers of this transcript (without this one).
    let suggestions: [String]
    var onApply: (RenameAction) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var everywhere = true
    @State private var swap = true

    /// `name`: the name typed at first (the line's speaker by default).
    init(target: FixTarget, lines: [TranscriptLine], suggestions: [String], name: String? = nil,
         onApply: @escaping (RenameAction) -> Void) {
        self.target = target
        self.lines = lines
        self.suggestions = suggestions
        self.onApply = onApply
        _name = State(initialValue: name ?? target.line.speaker)
    }

    private var old: String { target.line.speaker }
    private var clean: String? { Transcript.cleanSpeaker(name).flatMap { $0 == old ? nil : $0 } }
    private var count: Int { lines.filter { $0.speaker == old }.count }
    /// The new name already speaks in this call.
    private var taken: Bool { clean.map { n in lines.contains { $0.speaker == n } } ?? false }

    private var action: RenameAction? {
        guard let n = clean else { return nil }
        if !everywhere { return .line(n) }
        if taken { return swap ? .swap(n) : .merge(n) }
        return .rename(n)
    }

    private var buttonTitle: String {
        switch action {
        case .line: return L("Изменить реплику")
        case .swap: return L("Поменять местами")
        case .merge: return L("Объединить")
        default: return L("Переименовать")
        }
    }

    var body: some View {
        SZWFormSheet(L("Кто это говорит?"), width: 500, columns: true) {
            LabeledContent(L("Реплика") + ":") {
                Text("«" + target.line.text + "»")
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(L("Реплика «%@»: %@", old, target.line.text))
            }
            TextField(L("Имя") + ":", text: $name, prompt: Text(L("Имя")))
                .onSubmit(apply)
            if !suggestions.isEmpty {
                LabeledContent(L("Похоже, это:")) {
                    FlowLayout(spacing: 6) {
                        ForEach(suggestions, id: \.self) { s in
                            SZWSuggestion(title: s, on: s == name) { name = s }
                        }
                    }
                    .frame(width: 330, alignment: .leading)
                }
            }
            Toggle(isOn: $everywhere) {
                Text(L("Во всей расшифровке (реплик «%@»: %@)", old, count))
            }
            .toggleStyle(.checkbox)
            .help(L("Сними галочку, чтобы отдать другому человеку только эту реплику"))
            if everywhere && taken, let n = clean {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("«%@» уже есть в звонке", n)).foregroundStyle(.secondary)
                    Picker(L("«%@» уже есть в звонке", n), selection: $swap) {
                        Text(L("Поменять местами: реплики «%@» станут «%@», и наоборот", old, n))
                            .fixedSize(horizontal: false, vertical: true).tag(true)
                        Text(L("Объединить: все реплики станут «%@»", n))
                            .fixedSize(horizontal: false, vertical: true).tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
            }
        } actions: {
            Button(L("Отмена"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            Button(buttonTitle, action: apply)
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(action == nil)
        }
    }

    private func apply() {
        guard let action else { return }
        dismiss()
        onApply(action)
    }
}

/// "Fix a word": select the misheard word or phrase in the line, type the right spelling.
struct FixWordSheet: View {
    let line: TranscriptLine
    var onFix: (_ wrong: String, _ right: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var wrong = ""
    @State private var right = ""

    private var valid: Bool {
        let r = right.trimmingCharacters(in: .whitespacesAndNewlines)
        return !wrong.isEmpty && Transcript.containsWord(line.text, wrong) && !r.isEmpty && r != wrong
    }

    var body: some View {
        SZWFormSheet(L("Исправить слово"), subtitle: L("Выдели слово или фразу в реплике и напиши, как правильно."),
                     width: 500, columns: true) {
            LabeledContent(L("Реплика") + ":") {
                SelectableText(text: line.text, selection: $wrong)
                    .frame(height: 64)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                    .accessibilityLabel(L("Реплика"))
            }
            TextField(L("Было") + ":", text: $wrong, prompt: Text(L("Выдели в реплике")))
            TextField(L("Правильно") + ":", text: $right, prompt: Text(L("Как пишется"))).onSubmit(apply)
            if !wrong.isEmpty && !Transcript.containsWord(line.text, wrong) {
                SettingsWarning(L("Выдели слово целиком: часть слова не исправляется")).font(.caption)
            }
        } actions: {
            Button(L("Отмена"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            Button(L("Исправить"), action: apply)
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!valid)
        }
    }

    private func apply() {
        guard valid else { return }
        dismiss()
        onFix(wrong, right.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Read-only text whose selection is reported (SwiftUI Text doesn't expose it).
struct SelectableText: NSViewRepresentable {
    let text: String
    @Binding var selection: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: NSFont.systemFontSize)
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.string = text
        tv.delegate = context.coordinator
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.selection = $selection
        if let tv = scroll.documentView as? NSTextView, tv.string != text { tv.string = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var selection: Binding<String>
        init(selection: Binding<String>) { self.selection = selection }

        func textViewDidChangeSelection(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            let r = tv.selectedRange()
            guard r.length > 0, let range = Range(r, in: tv.string) else { return }
            let picked = String(tv.string[range]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if !picked.isEmpty { selection.wrappedValue = picked }
        }
    }
}
