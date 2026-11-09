// <call>/.work: wavs and echo cancellation temp files of an engine run (contract section 4).
// The engine removes them when it ends or gets SIGTERM; only a hard kill or a crash leaves them behind.

import Foundation

public enum WorkFiles {
    public static let folder = ".work"

    /// At launch: removes `.work` from every call folder except `keeping` (the restored queue: its run clears
    /// the folder itself) and calls found `processing` (an engine started after launch, before the sweep got there).
    public static func sweep(in root: URL, keeping: Set<URL>) {
        let fm = FileManager.default
        let kept = Set(keeping.map { $0.standardizedFileURL.path })
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for dir in dirs where dir.hasDirectoryPath && !kept.contains(dir.standardizedFileURL.path) {
            let work = dir.appendingPathComponent(folder)
            guard fm.fileExists(atPath: work.path) else { continue }
            if CallFile.read(dir)["status"] as? String == CallStatus.processing.rawValue { continue }
            try? fm.removeItem(at: work)
        }
    }
}
