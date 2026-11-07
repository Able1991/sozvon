// Building blocks of the setup assistant, made of system controls only: the page (symbol, large title,
// body, content), the bottom bar, grouped rows in a GroupBox, radio choices, language checkboxes, the
// install log disclosure and the project search status. Layout follows Apple's own onboarding windows.

import AppKit
import SozvonCore
import SwiftUI

// MARK: - Page

/// The header image of a step.
enum SetupIcon {
    /// The app icon (welcome).
    case app
    /// A large SF Symbol in hierarchical rendering, in the accent color.
    case symbol(String)
    /// A multicolor or palette symbol that brings its own colors (checkmark.circle.fill, warning).
    case status(String, tint: Color)
}

/// One step: icon, large title, secondary body, then the step's content. Top aligned so the header stays
/// in the same place while the user clicks through; scrolls when a step is taller than the window.
struct SetupPage<Content: View>: View {
    let icon: SetupIcon
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                iconView
                    .padding(.bottom, 18)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 28, weight: .bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 460)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                VStack(spacing: 16) { content }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 30)
            }
            .padding(.horizontal, 44)
            .padding(.top, 52)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder private var iconView: some View {
        switch icon {
        case .app:
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 104, height: 104)
                .padding(.bottom, -6)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 60, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .frame(height: 72)
                .symbolEffect(.bounce, options: .nonRepeating, value: name)
        case .status(let name, let tint):
            Image(systemName: name)
                .font(.system(size: 60, weight: .regular))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, tint)
                .frame(height: 72)
                .symbolEffect(.bounce, options: .nonRepeating, value: name)
        }
    }
}

/// The bottom bar: leading and trailing button groups over the window background. On macOS 26 the page
/// scrolls under it with the system scroll edge effect.
struct SetupBottomBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            leading
            Spacer(minLength: 12)
            trailing
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 20)
    }
}

extension View {
    /// Pins the bottom bar under the page; macOS 26 blends the page into it with the scroll edge effect.
    @ViewBuilder func setupBottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(macOS 26, *) {
            safeAreaBar(edge: .bottom, spacing: 0, content: bar)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) { bar().background(.bar) }
        }
    }
}

// MARK: - Welcome features

/// A feature line of the welcome page, as in Apple's "What's New" sheets: a tinted hierarchical symbol,
/// a headline and a secondary line.
struct SetupFeature: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Grouped rows

/// Rows in a system GroupBox, separated by inset dividers, like a grouped form section.
struct SetupGroup<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.headline).padding(.leading, 4)
            }
            GroupBox {
                VStack(spacing: 0) {
                    Group(subviews: content) { rows in
                        ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                            if i > 0 { Divider().padding(.horizontal, 2) }
                            row.padding(.vertical, 9).padding(.horizontal, 6)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A row: optional symbol, title with a secondary line, trailing control.
struct SetupRow<Trailing: View>: View {
    var symbol: String?
    let title: String
    var detail: String?
    var detailSymbol: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if let detailSymbol {
                            Image(systemName: detailSymbol).symbolRenderingMode(.multicolor)
                        }
                        Text(detail)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .accessibilityElement(children: .contain)
    }
}

/// "Done" / "Allowed": a green check, with the word or (`iconOnly`) just spoken by VoiceOver.
struct SetupCheck: View {
    let text: String
    var iconOnly = false
    var body: some View {
        Label {
            Text(text).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
        .labelStyle(SetupCheckLabelStyle(iconOnly: iconOnly))
        .font(iconOnly ? .title3 : nil)
        .fixedSize()
        .accessibilityLabel(text)
    }
}

private struct SetupCheckLabelStyle: LabelStyle {
    let iconOnly: Bool
    func makeBody(configuration: Configuration) -> some View {
        if iconOnly { configuration.icon } else { Label(configuration) }
    }
}

// MARK: - Choices

/// One option of a radio group: a title with a secondary note on the same line, a description below.
struct SetupChoiceLabel: View {
    let title: String
    var note: String?
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).fontWeight(.semibold)
                if let note { Text(note).font(.callout).foregroundStyle(.secondary) }
            }
            Text(text).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 4)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A native radio group in a GroupBox; options listed in `items`, unavailable ones disabled.
struct SetupRadioGroup<Value: Hashable & Identifiable, Label: View>: View {
    @Binding var selection: Value
    let items: [Value]
    var isEnabled: (Value) -> Bool = { _ in true }
    let accessibilityLabel: String
    @ViewBuilder var label: (Value) -> Label

    var body: some View {
        GroupBox {
            Picker(accessibilityLabel, selection: $selection) {
                ForEach(items) { item in
                    label(item)
                        .tag(item)
                        .disabled(!isEnabled(item))
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
        }
    }
}

// MARK: - Languages

/// The call languages as checkboxes. The last one is "detect automatically", on when nothing is picked;
/// the same selection rules as everywhere (`SpeechLanguage.toggling`).
struct SetupLanguages: View {
    @Binding var selection: [SpeechLanguage]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
                  alignment: .leading, spacing: 8) {
            ForEach(SpeechLanguage.real) { lang in
                Toggle(lang.title, isOn: Binding(
                    get: { selection.contains(lang) },
                    set: { on in
                        if on != selection.contains(lang) { selection = SpeechLanguage.toggling(lang, in: selection) }
                    }))
            }
            Toggle(SpeechLanguage.auto.title, isOn: Binding(
                get: { selection.isEmpty },
                set: { on in if on { selection = SpeechLanguage.toggling(.auto, in: selection) } }))
        }
        .toggleStyle(.checkbox)
    }
}

// MARK: - Install

/// The installer output behind a disclosure: monospaced, selectable, following the last line.
struct SetupLogView: View {
    let lines: [String]
    /// Opens the log when it turns true (a failed install), and on appear if it already is.
    var expanded = false
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                            Text(verbatim: l).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .id(i)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .frame(height: 150)
                .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.separator) }
                .padding(.top, 6)
                .onChange(of: lines.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
                .onAppear { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
            }
            .accessibilityLabel(L("Лог установки"))
        } label: {
            Text(L("Подробности")).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { if expanded { isExpanded = true } }
        .onChange(of: expanded) { _, v in if v { isExpanded = true } }
    }
}

/// A linear indeterminate progress bar with the current phase under it.
struct SetupProgress: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView().progressViewStyle(.linear)
            Text(text).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Projects

/// What the project search found (or why it stopped).
struct SetupDiscoverResult: View {
    let text: String
    let outcome: ProjectDiscovery.Outcome

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 10) {
                ProjectDiscoveryIcon(outcome: outcome)
                    .accessibilityHidden(true)
                Text(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(6)
        }
    }
}
