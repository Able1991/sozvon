// Extra design-kit pieces for the floating capsule and the small windows: capsule drawing, and the native
// form sheet, suggestion buttons and color dots of CallInfo, Projects and the transcript sheets.

import AppKit
import SozvonCore
import SwiftUI

// MARK: - Colors and helpers

enum SZW {
    /// The capsule's own fill for its stop button and pill (Capsule screen: --fillc #0000001a / #ffffff1a).
    static let capsuleFill = SZ.platter
    /// The capsule's inset edge (Capsule screen: --edge #ffffffcc / #ffffff1a).
    static let capsuleEdge = SZ.dynamic(0xffffffcc, 0xffffff1a, name: "capsuleEdge")
    /// Capsule glass tint (--glass), used on the macOS 26 glass and in the fallback.
    static let glass = SZ.rgbaDynamic(0xfbfbfccc, 0x2b2b30cc, name: "capsuleGlass")

    /// Project dot color from the project's (short) name, in the design palette.
    static func projectColor(_ name: String) -> Color {
        let h = name.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
        return SZ.projectPalette[abs(h) % SZ.projectPalette.count]
    }

    /// "3 проекта", "10 человек"; "3 projects", "10 people". Plural forms are chosen here, not by a strings key.
    static func count(_ n: Int, ru forms: (String, String, String), en: (String, String)) -> String {
        if Engine.uiLanguage == "en" { return "\(n) " + (n == 1 ? en.0 : en.1) }
        let tens = n % 100, ones = n % 10
        let word = (11...14).contains(tens) ? forms.2 : ones == 1 ? forms.0 : (2...4).contains(ones) ? forms.1 : forms.2
        return "\(n) \(word)"
    }
}

extension SZ {
    /// A dynamic NSColor (for AppKit layers): `light` / `dark` as 0xRRGGBBAA.
    static func rgbaDynamic(_ light: UInt32, _ dark: UInt32, name: String) -> NSColor {
        NSColor(name: NSColor.Name("szw." + name)) { appearance in
            rgba(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        }
    }
}

// MARK: - Capsule pieces

/// `.wave`: 3pt bars, 2.5 gap, 22 high; me in the accent color, them in coral.
struct SZWWave: View {
    struct Bar: Equatable { var value: CGFloat; var them: Bool }
    let bars: [Bar]
    var height: CGFloat = 22

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, b in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(b.them ? SZ.coral : Color.accentColor)
                    .frame(width: 3, height: max(3, height * b.value))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Both sides toward each other: my voice in blue runs from the left to the middle, theirs in coral from the
/// right to the middle; the newest bars meet in the middle.
struct SZWDuplexWave: View {
    struct Bar: Equatable { var me: CGFloat; var them: CGFloat }
    /// Oldest first.
    let bars: [Bar]
    var height: CGFloat = 22

    var body: some View {
        let half = max(bars.count / 2, 1)
        let recent = Array(bars.suffix(half))
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(Array(recent.enumerated()), id: \.offset) { _, b in bar(b.me, SZ.accent) }
            Rectangle().fill(SZ.label3).frame(width: 1, height: height * 0.5).padding(.horizontal, 1.5)
            ForEach(Array(recent.reversed().enumerated()), id: \.offset) { _, b in bar(b.them, SZ.coral) }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private func bar(_ v: CGFloat, _ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 1.5).fill(color)
            .frame(width: 3, height: max(3, height * min(max(v, 0), 1)))
    }
}

/// `.dot`: the 8pt red recording dot with a soft glow (0 0 8px), breathing.
struct SZWRecordDot: View {
    var glow = true
    @State private var bright = false

    var body: some View {
        Circle().fill(SZ.red)
            .frame(width: 8, height: 8)
            .shadow(color: glow ? SZ.red.opacity(bright ? 0.9 : 0.35) : .clear, radius: 4)
            .onAppear {
                guard glow else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { bright = true }
            }
            .accessibilityHidden(true)
    }
}

/// `.ring`: the idle "Record" mark, SF record.circle at 16pt: a label ring around a red dot.
struct SZWRecordRing: View {
    var body: some View {
        Image(systemName: "record.circle")
            .symbolRenderingMode(.palette)
            .foregroundStyle(SZ.red, SZ.label)
            .font(.system(size: 16, weight: .medium))
            .accessibilityHidden(true)
    }
}

/// `.spin`: a 14pt ring (2pt fill track) with a label2 arc, turning.
struct SZWSpinner: View {
    @State private var turn = false

    var body: some View {
        ZStack {
            Circle().stroke(SZW.capsuleFill, lineWidth: 2)
            Circle().trim(from: 0, to: 0.25)
                .stroke(SZ.label2, style: StrokeStyle(lineWidth: 2, lineCap: .butt))
                .rotationEffect(.degrees(turn ? 360 - 45 : -45))
        }
        .frame(width: 12, height: 12)
        .padding(1)
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turn = true }
        }
        .accessibilityHidden(true)
    }
}

/// A green filled circle with a check (capsule "saved", a saved voice in the call card).
struct SZWCheckDot: View {
    var size: CGFloat = 14
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .symbolRenderingMode(.palette)
            .foregroundStyle(SZ.chkink, SZ.green)
            .font(.system(size: size, weight: .semibold))
    }
}

// MARK: - Color dot

/// A project's color dot. In lists it is a plain circle; in menus (NSMenu draws images, not views) it is a
/// non-template image so the color survives.
enum SZWDot {
    static func view(_ color: Color, size: CGFloat = 8) -> some View {
        Circle().fill(color).frame(width: size, height: size).accessibilityHidden(true)
    }

    static func image(_ color: Color, size: CGFloat = 8) -> Image {
        let ns = NSColor(color)
        let img = NSImage(size: NSSize(width: size + 4, height: size + 4), flipped: false) { r in
            ns.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 2, dy: 2)).fill()
            return true
        }
        img.isTemplate = false
        return Image(nsImage: img)
    }
}

// MARK: - Suggestions

/// A suggested name as a small capsule bordered button; `on` (already picked) shows a checkmark.
struct SZWSuggestion: View {
    let title: String
    var on = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if on {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(on ? .accentColor : nil)
        .fixedSize()
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

/// A native sheet: an optional heading, a grouped `Form` and the buttons at the bottom trailing edge, like the
/// sheets of System Settings. `leading` holds a quieter button on the left (macOS puts alternate actions there).
struct SZWFormSheet<Content: View, Actions: View, Leading: View>: View {
    let title: String
    var subtitle: String?
    var width: CGFloat
    var maxHeight: CGFloat?
    /// A data entry sheet (fields to type into): the classic Mac columns, labels right-aligned on the left,
    /// every field starting at the same line. Settings-like choices stay grouped.
    var columns = false
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions
    @ViewBuilder var leading: Leading

    init(_ title: String, subtitle: String? = nil, width: CGFloat = 460, maxHeight: CGFloat? = nil, columns: Bool = false,
         @ViewBuilder content: () -> Content,
         @ViewBuilder actions: () -> Actions, @ViewBuilder leading: () -> Leading = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.width = width
        self.maxHeight = maxHeight
        self.columns = columns
        self.content = content()
        self.actions = actions()
        self.leading = leading()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !title.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // Lined up with the text inside the form's sections.
                .padding(.horizontal, columns ? 20 : 30)
                .padding(.top, 20)
            }
            if columns {
                Form { content }
                    .formStyle(.columns)
                    // Exactly the sheet's width: a long hint or a wide control must wrap, not widen the form.
                    .frame(width: width - 40)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Form {
                    content
                }
                .formStyle(.grouped)
                .scrollBounceBehavior(.basedOnSize)
                // The sheet is as tall as its form (a form alone has no height of its own); `maxHeight` caps a long
                // one, which then scrolls.
                .modifier(SZWFormHeight(maxHeight: maxHeight))
            }
            HStack(spacing: 8) {
                leading
                Spacer(minLength: 8)
                actions
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 20)
        }
        .frame(width: width)
    }
}

private struct SZWFormHeight: ViewModifier {
    let maxHeight: CGFloat?
    /// The form's measured content height, for a capped form.
    @State private var height: CGFloat?

    func body(content: Content) -> some View {
        if let maxHeight {
            content
                // Only the content size: the insets follow the window (title bar), which would loop the sizing.
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentSize.height.rounded() }) { _, h in
                    if h > 0, abs(h - (height ?? 0)) > 1 { height = h }
                }
                .frame(height: min(height ?? maxHeight, maxHeight))
        } else {
            content.fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Languages popup

/// A system menu button with checkmarked languages: pick several, or "Detect automatically" (an empty list).
struct SZWLanguagesPopup: View {
    let title: String
    @Binding var selection: [SpeechLanguage]

    private func binding(_ lang: SpeechLanguage) -> Binding<Bool> {
        Binding(get: { lang == .auto ? selection.isEmpty : selection.contains(lang) },
                set: { _ in selection = SpeechLanguage.toggling(lang, in: selection) })
    }

    /// "Русский + English", the same summary as in Settings.
    private var summary: String { SpeechLanguage.summary(selection) }

    var body: some View {
        Menu(summary) {
            ForEach(SpeechLanguage.real) { lang in
                Toggle(lang.title, isOn: binding(lang))
            }
            Divider()
            Toggle(SpeechLanguage.auto.title, isOn: binding(.auto))
        }
        .menuStyle(.button)
        .fixedSize()
        .accessibilityLabel(title)
        .accessibilityValue(summary)
    }
}
