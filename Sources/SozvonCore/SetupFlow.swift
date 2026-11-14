// Where the setup assistant opens and what it counts as a finished install.

import Foundation

public enum SetupFlow {
    /// Raw value of SetupModel.Step.model (welcome, assistant, account, model, install, permissions, projects).
    public static let modelStep = 3

    /// The setup assistant goes past the download only with a fully ready engine. `.needsUpdate` is usable for an
    /// app that was set up before (the update runs in the background), but after a stopped first install it is
    /// a venv without the model.
    public static func installed(_ engine: EngineState) -> Bool { engine == .ready }

    /// The step to open on: the one it was closed on, except past the download without a ready engine, then the
    /// model choice (the download can't be skipped; what was downloaded stays and the download continues).
    public static func resume(saved: Int?, engine: EngineState) -> Int {
        guard let saved else { return 0 }
        return saved > modelStep && !installed(engine) ? modelStep : saved
    }
}
