// Call notes in call.json (docs/CONTRACT.md, section 4), the lists of calls deleted and restored in Sozvon
// that sync carries to the own server (`<data>/server-deleted.json`, `<data>/server-restore.json`),
// and which password Connect Cloudflare sets on the server.

import Foundation

/// A note on a call: added by an assistant over MCP or in the Calls window. Append-only.
public struct CallNote: Equatable, Sendable, Identifiable {
    public let id: String
    /// ISO 8601 UTC, "2026-11-05T10:01:02Z".
    public let at: String
    public let text: String
    /// "claude-code", "codex", "claude", "chatgpt", "app", ...
    public let source: String

    public init(id: String, at: String, text: String, source: String) {
        self.id = id
        self.at = at
        self.text = text
        self.source = source
    }

    /// A valid note from call.json, as the engine's notes.clean: nil for anything else.
    public init?(_ value: Any) {
        guard let d = value as? [String: Any],
              let id = d["id"] as? String, CallNotes.validID(id),
              let at = d["at"] as? String, !at.trimmingCharacters(in: .whitespaces).isEmpty, at.count <= 40,
              let text = d["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.unicodeScalars.count <= CallNotes.maxText else { return nil }
        var source = d["source"] as? String ?? ""
        if source.isEmpty || source.count > 40 { source = "assistant" }
        self.init(id: id, at: at, text: text, source: source)
    }

    public var dictionary: [String: String] { ["id": id, "at": at, "text": text, "source": source] }

    public var date: Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: at) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: at)
    }
}

public enum CallNotes {
    public static let maxText = 4000
    public static let maxNotes = 200
    public static let deletedKey = "notes_deleted"

    public enum Failure: Error, Equatable {
        case empty, tooLong, tooMany, corrupt
    }

    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
    }

    /// Valid notes of a call.json object, each id once, oldest first.
    public static func list(_ call: [String: Any]) -> [CallNote] {
        var seen = Set<String>()
        let notes = ((call["notes"] as? [Any]) ?? []).compactMap(CallNote.init).filter { seen.insert($0.id).inserted }
        return notes.enumerated().sorted { a, b in a.element.at != b.element.at ? a.element.at < b.element.at : a.offset < b.offset }
            .map(\.element)
    }

    /// Ids of notes deleted in the app (tombstones the sync carries to the server).
    public static func deleted(_ call: [String: Any]) -> [String] {
        var seen = Set<String>()
        return ((call[deletedKey] as? [Any]) ?? []).compactMap { $0 as? String }.filter { validID($0) && seen.insert($0).inserted }
    }

    public static func read(_ dir: URL) -> [CallNote] { list(CallFile.read(dir)) }

    static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// Append a note under the call.json lock. A broken call.json is left alone (`.corrupt`).
    @discardableResult
    public static func add(_ text: String, to dir: URL, source: String = "app", now: Date = Date()) throws -> CallNote {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw Failure.empty }
        guard body.unicodeScalars.count <= maxText else { throw Failure.tooLong }
        let note = CallNote(id: UUID().uuidString.lowercased(), at: timestamp(now), text: body, source: source)
        do {
            try CallFile.edit(dir) { c in
                let have = list(c)
                guard have.count < maxNotes else { throw Failure.tooMany }
                c["notes"] = (have + [note]).map(\.dictionary)
                return true
            }
        } catch CallFileError.corrupt {
            throw Failure.corrupt
        }
        return note
    }

    /// Delete a note: it leaves call.json and its id goes to `notes_deleted`, so sync deletes it on the
    /// server too and no copy brings it back. -> whether the note was there.
    @discardableResult
    public static func delete(_ id: String, in dir: URL) throws -> Bool {
        do {
            return try CallFile.edit(dir) { c in
                let have = list(c)
                guard have.contains(where: { $0.id == id }) else { return false }
                c["notes"] = have.filter { $0.id != id }.map(\.dictionary)
                var gone = deleted(c)
                if !gone.contains(id) { gone.append(id) }
                c[deletedKey] = gone
                return true
            }
        } catch CallFileError.corrupt {
            throw Failure.corrupt
        }
    }
}

/// Calls the user moved to the Trash in Sozvon: `<data>/server-deleted.json`,
/// `{"schema": 1, "calls": [{"id": "...", "at": "..."}]}`. The next sync deletes them on the own server
/// and drops them from the list; nothing else is ever deleted there. Written under `server-deleted.json.lock`,
/// which the engine takes too.
public enum ServerTombstones {
    public static var file: URL { Paths.data.appendingPathComponent("server-deleted.json") }

    public static func ids(file: URL = file) -> [String] {
        entries(file).compactMap { $0["id"] as? String }
    }

    /// Throws when the list can't be written: the caller tells the user, the call would stay on the server.
    public static func add(_ id: String, at date: Date = Date(), file: URL = file) throws {
        try change(file) { list in
            guard !list.contains(where: { $0["id"] as? String == id }) else { return false }
            list.append(["id": id, "at": CallNotes.timestamp(date)])
            return true
        }
    }

    /// Undo of "Move to Trash" in Sozvon: don't delete the call on the server, and if sync already did,
    /// bring it back there (`ServerRestores`).
    public static func restored(_ id: String, at date: Date = Date(), file: URL = file,
                                restoreFile: URL = ServerRestores.file) throws {
        try remove(id, file: file)
        try add(id, at: date, file: restoreFile)
    }

    /// The call is back (restored from the Trash): don't delete it on the server.
    public static func remove(_ id: String, file: URL = file) throws {
        try change(file) { list in
            let before = list.count
            list.removeAll { $0["id"] as? String == id }
            return list.count != before
        }
    }

    private static func entries(_ file: URL) -> [[String: Any]] {
        guard let d = try? Data(contentsOf: file),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
        return (o["calls"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    }

    private static func change(_ file: URL, _ body: (inout [[String: Any]]) -> Bool) throws {
        try FileLock.with(file) {
            var list = entries(file)
            guard body(&list) else { return }
            let o: [String: Any] = ["schema": 1, "calls": list]
            let data = try JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: file, options: .atomic)
        }
    }
}

/// Calls the user put back in Sozvon (undo of "Move to Trash"): `<data>/server-restore.json`, same format
/// and locking as `server-deleted.json`. Sync sends each with `"restore": true`, which clears the server's
/// tombstone for it, and drops it from the list. A call put back from the Finder Trash is not listed:
/// once deleted on the server it stays on this Mac only.
public enum ServerRestores {
    public static var file: URL { Paths.data.appendingPathComponent("server-restore.json") }

    public static func ids(file: URL = file) -> [String] { ServerTombstones.ids(file: file) }
}

// MARK: - Server password across Macs

/// Which password Connect Cloudflare sets on the server. Besides `.env`, Connect keeps a copy in the server's
/// own KV namespace (`sozvon:password`, CloudflareAPI.storedPasswordKey), readable only with the user's
/// Cloudflare sign-in: a new Mac connecting to the same account reuses it instead of rotating it
/// (rotating signs every connector out). The Worker never reads or serves that key.
public enum ServerPasswords {
    public enum Choice: Equatable, Sendable {
        /// The password already saved in Settings for this server.
        case saved
        /// The copy kept in the server's Cloudflare account, and the server accepted it: connectors stay signed in.
        case stored
        /// A new one. `signInAgain`: it replaces the password of a server that already existed,
        /// so the connectors need to sign in again.
        case new(signInAgain: Bool)
    }

    /// The password Connect Cloudflare sets on `server`. `replacesServer`: the Worker already exists.
    /// `stored` reads the copy from the account (only asked when it matters); `accepts` asks the running
    /// server whether a password is right (GET /api/calls).
    public static func choose(server: URL, savedURL: String, savedPassword: String, replacesServer: Bool,
                              stored: @Sendable () async -> String?, accepts: @Sendable (URL, String) async -> Bool,
                              generate: @Sendable () -> String = { ServerPassword.generate() }) async -> (password: String, choice: Choice) {
        let saved = savedPassword.trimmingCharacters(in: .whitespaces)
        if OwnServer.normalize(savedURL) == server && !saved.isEmpty { return (saved, .saved) }
        guard replacesServer else { return (generate(), .new(signInAgain: false)) }
        if let copy = await stored()?.trimmingCharacters(in: .whitespacesAndNewlines), !copy.isEmpty,
           await accepts(server, copy) {
            return (copy, .stored)
        }
        return (generate(), .new(signInAgain: true))
    }
}
