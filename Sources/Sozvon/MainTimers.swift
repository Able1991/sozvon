// The Timer and asyncAfter callbacks of the app run on the main thread, but Swift does not know it:
// these two helpers say it once instead of a MainActor.assumeIsolated at every call site.

import AppKit

/// Runs `body` on the main actor after `seconds`.
func mainAfter(_ seconds: Double, _ body: @escaping @MainActor @Sendable () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { body() } }
}

extension Timer {
    /// A repeating timer on the main run loop in `.common` mode (it keeps firing while a menu or an alert is open).
    /// The caller keeps it to invalidate it later.
    @MainActor
    static func repeatingOnMain(every seconds: Double, _ body: @escaping @MainActor @Sendable () -> Void) -> Timer {
        let t = Timer(timeInterval: seconds, repeats: true) { _ in MainActor.assumeIsolated { body() } }
        RunLoop.main.add(t, forMode: .common)
        return t
    }
}
