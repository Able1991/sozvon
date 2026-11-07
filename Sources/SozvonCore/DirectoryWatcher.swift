// Watching a folder through file system events (instead of timer polling).

import Foundation

/// Reports on the main thread that entries in the folder appeared, disappeared or were renamed.
/// Changes inside subfolders don't arrive here: whoever makes them reports them.
@MainActor
public final class DirectoryWatcher {
    public let url: URL
    private let debounce: TimeInterval
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    public init(_ url: URL, debounce: TimeInterval = 0.3, onChange: @escaping @MainActor () -> Void) {
        self.url = url
        self.debounce = debounce
        self.onChange = onChange
    }

    public var isRunning: Bool { source != nil }

    public func start() {
        guard source == nil else { return }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                          eventMask: [.write, .delete, .rename, .link, .attrib, .extend],
                                                          queue: .main)
        s.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.fired() }
        }
        s.setCancelHandler { close(fd) }
        source = s
        s.resume()
    }

    public func stop() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
    }

    private func fired() {
        // The folder was deleted or renamed: watch the same path again.
        if let s = source, !s.data.isDisjoint(with: [.delete, .rename]) {
            stop()
            start()
        }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.onChange() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
