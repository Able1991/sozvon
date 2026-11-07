// Design tokens and the few drawn pieces left on top of the system controls: dynamic colors, the banner
// and capsule elevation, text styles with fixed line heights, the banner and the pending badge.
//
// Colors are dynamic NSColors keyed on the appearance (aqua or darkAqua), so they follow the window.
// Shadows mirror the CSS box-shadow stacks of the design: an inner 1px top highlight, a 0.5px outline
// outside the shape, and drop shadows drawn outside the shape only. CSS blur B maps to a SwiftUI shadow
// radius of B / 2.

import AppKit
import SwiftUI

// MARK: - Colors

/// Design tokens. Usage: `SZ.accent`, `SZ.label2`.
enum SZ {
    /// A dynamic color: `light` / `dark` as 0xRRGGBBAA.
    static func dynamic(_ light: UInt32, _ dark: UInt32, name: String) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name("sz." + name)) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return rgba(isDark ? dark : light)
        })
    }

    static func rgba(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 24) & 0xff) / 255, green: CGFloat((v >> 16) & 0xff) / 255,
                blue: CGFloat((v >> 8) & 0xff) / 255, alpha: CGFloat(v & 0xff) / 255)
    }

    /// A fixed (non-dynamic) color from 0xRRGGBBAA.
    static func hex(_ v: UInt32) -> Color { Color(nsColor: rgba(v)) }

    //                                          light        dark          CSS variable
    static let windowBg = dynamic(0xf3f3f5ff, 0x141416ff, name: "windowBg")      // --window-bg
    static let bar = dynamic(0xf7f7f8e6, 0x1c1c20e6, name: "bar")                // --bar (bar-bg, player)
    static let label = dynamic(0x000000e0, 0xffffffe6, name: "label")            // --label
    static let label2 = dynamic(0x00000085, 0xffffff99, name: "label2")          // --label2
    static let label3 = dynamic(0x00000047, 0xffffff47, name: "label3")          // --label3
    static let sep = dynamic(0x00000014, 0xffffff12, name: "sep")                // --sep
    /// The capsule's stop button and pill (the Capsule screen redefines --fillc so).
    static let platter = dynamic(0x0000001a, 0xffffff1a, name: "platter")        // --fillc (Capsule)
    static let fillb = dynamic(0x0000000a, 0xffffff0a, name: "fillb")            // --fillb (fill-banner)
    static let edge = dynamic(0xffffffcc, 0xffffff14, name: "edge")              // --edge (edge-highlight)
    static let accent = dynamic(0x0a7affff, 0x3d9bffff, name: "accent")          // --accent
    static let accentRow = dynamic(0x0a7aff1f, 0x3d9bff24, name: "accentRow")    // --accent-row
    static let green = dynamic(0x2db24fff, 0x34d15bff, name: "green")            // --green
    static let orange = dynamic(0xe8780fff, 0xff9f3aff, name: "orange")          // --orange
    static let red = dynamic(0xff383cff, 0xff4a4eff, name: "red")                // --red
    static let coral = dynamic(0xe8555dff, 0xff7a81ff, name: "coral")            // --coral (Calls/Capsule)
    static let yellow = dynamic(0xf5b800ff, 0xffd60aff, name: "yellow")          // --yellow
    static let starRow = dynamic(0xf5b80014, 0xffd60a14, name: "starRow")        // --star-row
    static let textBg = dynamic(0xffffffff, 0x141416ff, name: "textBg")          // --text-bg
    static let chkink = dynamic(0xffffffff, 0x141416ff, name: "chkink")          // --chkink
    /// "Ждёт описания" pill: ink and fill (.pend).
    static let pendInk = dynamic(0xc9640aff, 0xff9f3aff, name: "pendInk")        // .pend color
    static let pendBg = dynamic(0xe8780f24, 0xff9f3a26, name: "pendBg")          // .pend background

    /// Project dot colors (tokens.json project-*), in the app's palette order.
    static let projectBlue = dynamic(0x0a7affd9, 0x3d9bffd9, name: "projectBlue")
    static let projectPurple = dynamic(0xb63adfd9, 0xd26cf5d9, name: "projectPurple")
    static let projectPink = dynamic(0xff2d55d9, 0xff5c7cd9, name: "projectPink")
    static let projectOrange = dynamic(0xe8780fd9, 0xff9f3ad9, name: "projectOrange")
    static let projectTeal = dynamic(0x00a9b8d9, 0x2fd7e4d9, name: "projectTeal")
    static let projectIndigo = dynamic(0x5c55e8d9, 0x8a93ffd9, name: "projectIndigo")
    static let projectGreen = dynamic(0x2db24fd9, 0x34d15bd9, name: "projectGreen")
    static let projectBrown = dynamic(0xa2764fd9, 0xc49670d9, name: "projectBrown")
    static let projectPalette = [projectBlue, projectPurple, projectPink, projectOrange,
                                 projectTeal, projectIndigo, projectGreen, projectBrown]

    // Radii (tokens.json radius-*).
    static let radiusControl: CGFloat = 7   // edit fields, transcript row highlights
    static let radiusBanner: CGFloat = 10   // .banner
}

// MARK: - Elevation

/// A CSS box-shadow stack. Specs differ per appearance (both colors and geometry), so they are resolved
/// from the color scheme.
struct SZShadowSpec {
    struct Drop {
        var color: Color
        var radius: CGFloat
        var y: CGFloat
    }

    /// `inset 0 1px 0 <highlight>`: a 1px line inside the top edge.
    var highlight: Color?
    /// `0 0 0 .5px <outline>`: a hairline just outside the shape.
    var outline: Color?
    /// Drop shadows, drawn outside the shape only.
    var drops: [Drop] = []
}

/// The elevation styles still drawn by hand.
enum SZShadow {
    case banner     // .banner: inset edge + outline edges
    case capsule    // floating capsule (.cap)

    func spec(dark: Bool) -> SZShadowSpec {
        typealias D = SZShadowSpec.Drop
        let h = SZ.hex
        switch (self, dark) {
        case (.banner, _):
            return .init(highlight: SZ.edge, outline: dark ? h(0x0000008c) : h(0x00000026))
        case (.capsule, true):
            return .init(highlight: h(0xffffff1a), outline: h(0x000000cc),
                         drops: [D(color: h(0x00000080), radius: 20, y: 16), D(color: h(0x00000066), radius: 4, y: 2)])
        case (.capsule, false):
            return .init(highlight: h(0xffffffcc), outline: h(0x0000001f),
                         drops: [D(color: h(0x00000033), radius: 20, y: 16), D(color: h(0x0000001a), radius: 4, y: 2)])
        }
    }
}

/// Draws a CSS-like surface behind the content: drop shadows outside the shape, the fill, the top
/// highlight and the hairline outline.
struct SZSurface<S: InsettableShape, F: ShapeStyle>: ViewModifier {
    let shape: S
    let fill: F
    let shadow: SZShadow
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let spec = shadow.spec(dark: scheme == .dark)
        content
            .background {
                ZStack {
                    ForEach(spec.drops.indices, id: \.self) { i in
                        let d = spec.drops[i]
                        shape.fill(Color.black).shadow(color: d.color, radius: d.radius, x: 0, y: d.y)
                    }
                }
                // Only outside the shape, as CSS draws box shadows: a translucent fill must not show them.
                .mask {
                    Rectangle().padding(-80)
                        .overlay { shape.fill(Color.black).blendMode(.destinationOut) }
                        .compositingGroup()
                }
                .allowsHitTesting(false)
            }
            .background { shape.fill(fill) }
            .overlay {
                if let c = spec.highlight { SZTopHighlight(shape: shape, color: c) }
            }
            .overlay {
                if let c = spec.outline {
                    shape.inset(by: -0.5).strokeBorder(c, lineWidth: 0.5).allowsHitTesting(false)
                }
            }
    }
}

/// `inset 0 1px 0 <color>`: the shape minus itself shifted 1px down, i.e. a 1px line along the top edge
/// that follows the corner curves.
struct SZTopHighlight<S: Shape>: View {
    let shape: S
    let color: Color

    var body: some View {
        shape.fill(color)
            .overlay { shape.fill(Color.black).offset(y: 1).blendMode(.destinationOut) }
            .compositingGroup()
            .clipShape(shape)
            .allowsHitTesting(false)
    }
}

extension View {
    /// A surface with a fill and an elevation, rounded by `radius` (999 or more: a capsule).
    func szSurface<F: ShapeStyle>(_ fill: F, radius: CGFloat, shadow: SZShadow) -> some View {
        modifier(SZSurface(shape: RoundedRectangle(cornerRadius: radius, style: .circular), fill: fill, shadow: shadow))
    }
}

// MARK: - Typography

/// A CSS text style: size, weight, line height, tracking. Single lines get the CSS line box height
/// (half-leading above and below), several lines the CSS line spacing.
struct SZTextStyle: Sendable {
    var size: CGFloat
    var weight: Font.Weight = .regular
    var lineHeight: CGFloat
    var tracking: CGFloat = 0
    var design: Font.Design = .default
    /// font-variant-numeric: tabular-nums
    var tabular = false

    static let bodyRelaxed = SZTextStyle(size: 13, lineHeight: 19)                             // .block p/li, .note 13/19
    static let bodySemibold = SZTextStyle(size: 13, weight: .semibold, lineHeight: 16)         // row titles, .card .ttl
    static let transcript = SZTextStyle(size: 13, lineHeight: 18)                              // .trow 13/18
    static let caption = SZTextStyle(size: 12, lineHeight: 16)                                 // 12/16: .sub, .meta, .quote
    static let small = SZTextStyle(size: 11, lineHeight: 14)                                   // 11/14: row subtitles
    static let badge = SZTextStyle(size: 10, weight: .medium, lineHeight: 13)                  // .badge
    static let h1Bold = SZTextStyle(size: 22, weight: .bold, lineHeight: 28, tracking: -0.4)   // call title (Calls h1)
    static let h2 = SZTextStyle(size: 17, weight: .semibold, lineHeight: 22, tracking: -0.2)   // .block h2, .sheet h3
    static let timer = SZTextStyle(size: 15, weight: .semibold, lineHeight: 18, design: .rounded, tabular: true) // capsule .timer

    var font: Font {
        let f = Font.system(size: size, weight: weight, design: design)
        return tabular ? f.monospacedDigit() : f
    }

    /// The natural line height AppKit gives this font.
    var naturalLineHeight: CGFloat {
        let f = NSFont.systemFont(ofSize: size, weight: weight.nsWeight)
        return ceil(f.ascender - f.descender + f.leading)
    }
}

extension Font.Weight {
    var nsWeight: NSFont.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}

private struct SZTextModifier: ViewModifier {
    let style: SZTextStyle

    func body(content: Content) -> some View {
        let extra = max(0, style.lineHeight - style.naturalLineHeight)
        content
            .font(style.font)
            .tracking(style.tracking)
            .lineSpacing(extra)
            .padding(.vertical, extra / 2)
    }
}

extension View {
    /// Apply a design text style: `Text("…").szFont(.caption)`.
    func szFont(_ style: SZTextStyle) -> some View { modifier(SZTextModifier(style: style)) }
}

// MARK: - Banner, badge

/// `.banner`: bold lead + secondary text, trailing buttons. 12/16, padding 10 14, radius 10, fillb.
struct SZBanner<Actions: View>: View {
    let lead: String
    let text: String
    @ViewBuilder var actions: Actions

    init(_ lead: String, _ text: String, @ViewBuilder actions: () -> Actions) {
        self.lead = lead
        self.text = text
        self.actions = actions()
    }

    private var message: Text {
        let a = Text(verbatim: lead).fontWeight(.semibold).foregroundStyle(SZ.label)
        let b = Text(verbatim: text).foregroundStyle(SZ.label2)
        return Text("\(a) \(b)")
    }

    var body: some View {
        HStack(spacing: 10) {
            message.szFont(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            actions
        }
        .padding(.vertical, 10).padding(.horizontal, 14)
        .szSurface(SZ.fillb, radius: SZ.radiusBanner, shadow: .banner)
    }
}

/// `.pend`: the orange "waiting for a description" pill, 10/13 medium, padding 1 5.
struct SZBadge: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).szFont(.badge)
            .foregroundStyle(SZ.pendInk)
            .padding(.horizontal, 5)
            .background(Capsule().fill(SZ.pendBg))
            .fixedSize()
    }
}
