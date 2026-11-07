// Importing a recording into the Calls window: a dropped or chosen audio/video file becomes a new call
// folder with the audio as system.m4a (AAC, AVAssetExportSession; no ffmpeg in the app), then the usual
// "What was the call about?" prompt queues it for transcription.

import AppKit
import AVFoundation
import SozvonCore
import UniformTypeIdentifiers

enum AudioImport {
    enum Failure: LocalizedError {
        case noAudio, unsupported, failed(String)

        var errorDescription: String? {
            switch self {
            case .noAudio: return L("В файле нет звуковой дорожки")
            case .unsupported: return L("Этот формат macOS прочитать не может. Сконвертируй файл в m4a, mp3 или wav.")
            case .failed(let m): return m
            }
        }
    }

    /// Convert `src` to AAC in `dst` (an .m4a). Runs off the main thread; `progress` gets 0...1. -> duration in seconds.
    static func convert(_ src: URL, to dst: URL, progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> Double {
        let asset = AVURLAsset(url: src)
        let audio: [AVAssetTrack]
        do {
            audio = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw Failure.unsupported
        }
        guard !audio.isEmpty else { throw Failure.noAudio }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw Failure.unsupported
        }
        // Into a hidden file next to the target, renamed when complete: the engine never sees half a track.
        let tmp = dst.deletingLastPathComponent().appendingPathComponent(CallImport.tempPrefix + "\(UUID().uuidString).m4a")
        let states = session.states(updateInterval: 0.25)
        let watcher = Task {
            for await state in states {
                if case .exporting(let p) = state { await progress(p.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        do {
            try await session.export(to: tmp, as: .m4a)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            if Task.isCancelled { throw CancellationError() }
            throw Failure.failed(error.localizedDescription)
        }
        do {
            try FileManager.default.moveItem(at: tmp, to: dst)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw Failure.failed(error.localizedDescription)
        }
        let seconds = (try? await AVURLAsset(url: dst).load(.duration).seconds) ?? 0
        return seconds.isFinite ? seconds : 0
    }

    static var contentTypes: [UTType] {
        CallImport.extensions.sorted().compactMap { UTType(filenameExtension: $0) }
    }

    /// When the recording was made, as written in the file: the common creation date, else QuickTime's.
    /// nil when there is none or it is implausible (CallImport.plausible); then the file's own dates are used.
    static func recordedDate(_ src: URL) async -> Date? {
        let asset = AVURLAsset(url: src)
        var items: [AVMetadataItem] = []
        if let d = try? await asset.load(.creationDate) { items.append(d) }
        if let all = try? await asset.load(.metadata) {
            items += AVMetadataItem.metadataItems(from: all, filteredByIdentifier: .commonIdentifierCreationDate)
            items += AVMetadataItem.metadataItems(from: all, filteredByIdentifier: .quickTimeMetadataCreationDate)
        }
        for item in items {
            if let d = CallImport.plausible(try? await item.load(.dateValue)) { return d }
            if let s = try? await item.load(.stringValue), let d = CallImport.plausible(CallImport.parseDate(s)) { return d }
        }
        return nil
    }

    /// The Trash, never a plain delete: what a crash during an import left behind (CallImport.leftovers).
    @MainActor
    static func cleanLeftovers() {
        let root = Paths.calls
        Task { @MainActor in
            let urls = await Task.detached(priority: .utility) { CallImport.leftovers(in: root) }.value
            guard !urls.isEmpty else { return }
            do { _ = try await NSWorkspace.shared.recycle(urls) } catch {
                NSLog("Sozvon: import leftovers not moved to the Trash: %@", error.localizedDescription)
            }
        }
    }
}

/// What is being imported right now (the sidebar shows it under the list).
struct ImportProgress: Equatable {
    var name: String
    var fraction: Double
    var dir: URL
}

extension CallsModel {
    /// "Import Recording…": the open panel.
    func chooseImport() {
        let panel = NSOpenPanel()
        panel.title = L("Импортировать запись")
        panel.prompt = L("Импортировать")
        panel.allowedContentTypes = AudioImport.contentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    /// Files dropped on the list. -> whether the drop is taken (a format macOS can't read gets an explanation).
    func dropFiles(_ urls: [URL]) -> Bool {
        let files = urls.filter(\.isFileURL)
        let unreadable = files.filter(CallImport.isUnreadable)
        guard files.contains(where: CallImport.isSupported) || !unreadable.isEmpty, importing == nil else { return false }
        importFiles(files)
        return true
    }

    /// Dropped or chosen files, one after another. Only the last imported call gets the "What was the call about?"
    /// prompt (one prompt at a time); the others wait in the list with "Transcribe…".
    func importFiles(_ urls: [URL]) {
        let files = urls.filter(CallImport.isSupported)
        let unreadable = urls.filter(CallImport.isUnreadable)
        if !unreadable.isEmpty {
            let a = NSAlert()
            a.messageText = L("Этот формат не поддерживается: сконвертируй в m4a, mp3 или wav")
            a.informativeText = unreadable.map(\.lastPathComponent).joined(separator: "\n")
            a.runModal()
        }
        guard !files.isEmpty else { if unreadable.isEmpty { NSSound.beep() }; return }
        guard importing == nil else { NSSound.beep(); return }
        Task { @MainActor in
            var last: URL?
            for f in files {
                if let dir = await importRecording(f) { last = dir }
            }
            if let last { onImported(last) }
        }
    }

    private func importRecording(_ src: URL) async -> URL? {
        let recorded = await AudioImport.recordedDate(src)
        let date = CallImport.date(of: src, recorded: recorded)
        let dir: URL
        do {
            dir = try CallImport.createFolder(for: src, recorded: recorded)
        } catch {
            importFailed(src, error)
            return nil
        }
        importing = ImportProgress(name: src.lastPathComponent, fraction: 0, dir: dir)
        defer { importing = nil }
        reload()
        do {
            let seconds = try await AudioImport.convert(src, to: dir.appendingPathComponent("system.m4a")) { [weak self] p in
                self?.importing?.fraction = p
            }
            guard CallImport.finish(dir, recordedAt: date, seconds: seconds) else { throw AudioImport.Failure.failed("call.json") }
        } catch {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("system.m4a"))
            CallFolder.discardIfUnused(dir)
            reload()
            importFailed(src, error)
            return nil
        }
        reload()
        selection = dir.path
        return dir
    }

    private func importFailed(_ src: URL, _ error: Error) {
        let a = NSAlert()
        a.messageText = L("Не получилось импортировать «%@»", src.lastPathComponent)
        a.informativeText = error.localizedDescription
        a.runModal()
    }
}
