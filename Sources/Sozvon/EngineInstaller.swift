// The sole owner of setup.sh: the background engine update after an app update
// and installs from the setup assistant ("Install", "Reinstall…", "Download Model…") never run at the same time.

import Combine
import SozvonCore

@MainActor
final class EngineInstaller: ObservableObject {
    static let shared = EngineInstaller()

    enum Owner: Equatable {
        /// Background environment update (ProcessingController).
        case background
        /// Setup assistant.
        case setup
    }

    /// Who is currently running setup.sh; nil means no install is running.
    @Published private(set) var owner: Owner?
    var isRunning: Bool { owner != nil }

    /// Install started and finished (the transcription queue waits, then resumes).
    var willStart: () -> Void = {}
    var didFinish: (Owner, Bool) -> Void = { _, _ in }

    private var process: RunningProcess?

    /// Run setup.sh. Already running: returns false, no second run is started.
    @discardableResult
    func run(_ owner: Owner, onLine: ProcessRunner.LineHandler? = nil,
             done: @escaping @MainActor (Bool) -> Void = { _ in }) -> Bool {
        guard self.owner == nil else { return false }
        self.owner = owner
        willStart()
        process = Engine.setup(onLine: onLine) { [weak self] ok in
            guard let self else { return }
            self.owner = nil
            self.process = nil
            done(ok)
            self.didFinish(owner, ok)
        }
        return true
    }

    /// Stop the install with all its child processes, if it was started by `owner`.
    func cancel(_ owner: Owner) {
        guard self.owner == owner else { return }
        process?.terminate()
    }
}
