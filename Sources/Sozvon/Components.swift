// Общие кусочки окон: шапки, карточки выбора, разрешения, подсказки собеседников, выбор языков.

import AppKit
import AVFoundation
import SozvonCore
import SwiftUI

// MARK: - Общие кусочки

struct Header: View {
    let symbol: String
    let title: String
    let subtitle: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(spacing: 10) {
            Group {
                if symbol == "app" {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 44, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(tint)
                        .symbolEffect(.bounce, options: .nonRepeating, value: symbol)
                }
            }
            .frame(height: symbol == "app" ? 96 : 52)
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 32)
    }
}

struct ChoiceCard: View {
    let symbol: String
    let title: String
    let subtitle: String
    let selected: Bool
    var badge: String? = nil
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).font(.headline)
                        if let badge {
                            Text(badge).font(.caption2.weight(.medium))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }
}

struct StatusRow: View {
    let ok: Bool
    let title: String
    let detail: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(ok ? .green : .orange)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !ok { Button(buttonTitle, action: action) }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
    }
}

/// Разрешения macOS на микрофон и запись экрана со звуком.
@MainActor
enum Permissions {
    static var mic: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var screen: Bool { CGPreflightScreenCaptureAccess() }

    /// Спросить доступ к микрофону; если уже отказано, открыть настройки.
    static func requestMic() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        } else {
            openPane("Privacy_Microphone")
        }
    }

    static func requestScreen() {
        if !CGRequestScreenCaptureAccess() { openPane("Privacy_ScreenCapture") }
    }

    static func openPane(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    /// Перезапустить Sozvon (после выдачи записи экрана, смены языка интерфейса).
    /// Путь и pid передаются аргументами, а не вклеиваются в текст команды (кавычки в пути ломали её).
    /// Новая копия открывается, когда старая вышла (ждём до минуты): иначе её остановил бы замок одной копии.
    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", #"i=0; while kill -0 "$1" 2>/dev/null && [ $i -lt 300 ]; do sleep 0.2; i=$((i+1)); done; sleep 0.5; open "$0""#,
                       Bundle.main.bundlePath, String(getpid())]
        try? p.run()
        NSApp.terminate(nil)
    }
}


/// Прогресс поиска проектов: текущий шаг, сколько прошло, кнопка «Остановить».
struct DiscoverProgress: View {
    @ObservedObject var m: SetupModel

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.discoverStatus.isEmpty ? L("Ищу проекты…") : m.discoverStatus)
                    .font(.callout)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let t = Int(ctx.date.timeIntervalSince(m.discoverStarted))
                    Text(L("%@ · обычно 2-5 минут", String(format: "%d:%02d", t / 60, t % 60)))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button(L("Остановить")) { m.stopDiscover() }
                .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
    }
}

/// Кнопки-имена: нажатие добавляет человека в «Собеседники» или убирает.
struct PeopleChips: View {
    let people: [String]
    @Binding var names: String

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(people, id: \.self) { p in
                let on = splitList(names).contains(p)
                Button {
                    var list = splitList(names)
                    if on { list.removeAll { $0 == p } } else { list.append(p) }
                    names = list.joined(separator: ", ")
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: on ? "checkmark" : "plus").font(.system(size: 9, weight: .bold))
                        Text(p).font(.callout)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .foregroundStyle(on ? Color.white : Color.primary)
                    .background(Capsule().fill(on ? Color.accentColor : Color.secondary.opacity(0.15)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.easeOut(duration: 0.15), value: names)
    }
}

/// Раскладка с переносом строк.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing
            row = max(row, s.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: min(maxX, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}

// MARK: - Выбор нескольких языков

/// Меню с галочками: можно отметить несколько языков или «Определять сам».
struct LanguagesPicker: View {
    let title: String
    @Binding var selection: [SpeechLanguage]

    var body: some View {
        LabeledContent(title) {
            Menu {
                ForEach(SpeechLanguage.real) { lang in
                    Toggle(lang.title, isOn: Binding(
                        get: { selection.contains(lang) },
                        set: { on in
                            if on { selection.append(lang) } else { selection.removeAll { $0 == lang } }
                            selection = SpeechLanguage.real.filter { selection.contains($0) }
                        }))
                }
                Divider()
                Toggle(L("Определять сам"), isOn: Binding(
                    get: { selection.isEmpty },
                    set: { on in if on { selection = [] } }))
            } label: {
                Text(SpeechLanguage.summary(selection))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}
