// Shared window pieces: macOS permissions and a wrapping flow layout.

import AppKit
import AVFoundation
import SozvonCore
import SwiftUI

/// macOS permissions for the microphone and screen recording with audio.
@MainActor
enum Permissions {
    static var mic: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var screen: Bool { CGPreflightScreenCaptureAccess() }

    /// Request microphone access; if already denied, open System Settings.
    static func requestMic() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        } else {
            openPane("Privacy_Microphone")
        }
    }

    /// The first time only the system prompt (it has its own "Open System Settings" button): the call returns
    /// false right away while the prompt is up, and opening the pane too put two windows on screen at once.
    /// Asked before (macOS shows the prompt once): straight to the pane.
    static func requestScreen() {
        let key = "screenCaptureAsked"
        if !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            _ = CGRequestScreenCaptureAccess()
            return
        }
        if !CGRequestScreenCaptureAccess() { openPane("Privacy_ScreenCapture") }
    }

    static func openPane(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    /// Relaunch Sozvon (after granting screen recording or changing the interface language).
    /// The path and pid are passed as arguments, not spliced into the command text (quotes in the path broke it).
    /// The new copy opens once the old one has exited (we wait up to
    /// a minute), otherwise the single-instance lock would stop it.
    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", #"i=0; while kill -0 "$1" 2>/dev/null && [ $i -lt 300 ]; do sleep 0.2; i=$((i+1)); done; sleep 0.5; open "$0""#,
                       Bundle.main.bundlePath, String(getpid())]
        try? p.run()
        NSApp.terminate(nil)
    }
}

/// Wrapping flow layout.
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
