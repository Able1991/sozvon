// Pieces only the Calls window uses: summary and notes blocks, action item rings and the player controls.

import AppKit
import SozvonCore
import SwiftUI

// MARK: - Call card

/// A summary or notes section: a heading (with optional trailing controls) above a system group box.
struct SZBlock<Trailing: View, Content: View>: View {
    var title: String
    var spacing: CGFloat = 10
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    init(_ title: String, spacing: CGFloat = 10, @ViewBuilder trailing: () -> Trailing,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.spacing = spacing
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        // A section heading above a system group box (as System Settings groups its rows).
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    trailing
                }
                .padding(.horizontal, 4)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: spacing) { content }
                    .padding(.vertical, 6).padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

extension SZBlock where Trailing == EmptyView {
    init(_ title: String, spacing: CGFloat = 10, @ViewBuilder content: () -> Content) {
        self.init(title, spacing: spacing, trailing: { EmptyView() }, content: content)
    }
}

/// The 14pt ring of an action item (filled check when done).
struct SZTaskRing: View {
    var done = false
    var body: some View {
        Group {
            if done {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(SZ.label3)
            } else {
                Image(systemName: "circle").font(.system(size: 14, weight: .light)).foregroundStyle(SZ.label3)
            }
        }
        .frame(width: 14, height: 14)
    }
}

// MARK: - Player

/// Play/pause: the system prominent round button.
struct SZPlayButton: View {
    let playing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .controlSize(.large)
    }
}

/// The system slider. Dragging reports `editing`; arrow keys move it.
struct SZScrubber: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
            .controlSize(.small)
            .frame(maxWidth: .infinity)
    }
}

/// The playback speed as a system pop-up menu.
struct SZRateMenu: View {
    @Binding var rate: Float
    let rates: [Float]

    var body: some View {
        Picker(L("Скорость"), selection: $rate) {
            ForEach(rates, id: \.self) { r in Text(verbatim: "\(r.formatted())×").tag(r) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .help(L("Скорость"))
    }
}
