// Small helpers for the Settings window's grouped forms: a status label, an icon button, section footers.
// Everything else there is plain SwiftUI form controls.

import AppKit
import SwiftUI

// MARK: - Status

/// A row's state: a green check (or an orange warning) with secondary text, like System Settings.
struct SZSettingsStatus: View {
    let text: String
    var ok = true

    var body: some View {
        Label {
            Text(text).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Buttons

/// A borderless symbol button inside a row (show password, copy), with a tooltip and a VoiceOver label.
struct SZSmallIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    init(_ symbol: String, label: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 18)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
        .help(label)
    }
}

// MARK: - Footers

/// A section footer paragraph, wrapping to the form's width.
struct SettingsFooter: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A section footer that reports a failure: orange, with a triangle.
struct SettingsWarning: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A caution in a section footer (what a sharing toggle means): secondary text led by a small triangle.
struct SettingsCaution: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Preview switches

#if SOZVON_PREVIEW
/// Screenshot-only states of the Settings window, set by PreviewDriver flags.
@MainActor
enum SettingsPreview {
    /// `--engine-error`: the MCP server does not answer and has a failure line (SettingsEngineError board).
    static var engineError = false
    /// `--tall`: no height cap, so a whole pane fits in one snapshot.
    static var tall = false
}
#endif
