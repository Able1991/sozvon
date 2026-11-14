// Projects: profiles/<slug>.json in the data folder (contract, section 4: "schema": 1).

import Foundation

public struct Project: Identifiable, Hashable, Sendable {
    public static let schema = 1

    public var slug: String
    public var title: String
    public var context: String
    public var people: [String]
    public var terms: [String]
    /// Languages of the project's calls (profile `languages`, "ru,en"); [] = the settings' ones.
    public var languages: [SpeechLanguage] = []
    public var id: String { slug }

    public init(slug: String, title: String, context: String = "", people: [String] = [], terms: [String] = []) {
        self.slug = slug
        self.title = title
        self.context = context
        self.people = people
        self.terms = terms
    }

    /// Short name for the folder name and the list: "Acme / Holding" -> "Acme".
    public var shortTitle: String { title.components(separatedBy: " / ").first ?? title }

    public static func all(in dir: URL = Paths.profiles) -> [Project] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap(load)
            .sorted { $0.title.lowercased() < $1.title.lowercased() }
    }

    /// Short project names by slug.
    public static func titles(_ list: [Project]) -> [String: String] {
        Dictionary(list.map { ($0.slug, $0.shortTitle) }, uniquingKeysWith: { a, _ in a })
    }

    public static func load(_ url: URL) -> Project? {
        let slug = url.deletingPathExtension().lastPathComponent
        guard isValidSlug(slug), let d = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        var p = Project(slug: slug, title: o["title"] as? String ?? slug, context: o["context"] as? String ?? "",
                        people: o["people"] as? [String] ?? [], terms: o["terms"] as? [String] ?? [])
        p.languages = SpeechLanguage.parse(o["languages"] as? String ?? "")
        return p
    }

    /// Why a title can't be saved in the project editor.
    public enum TitleProblem: Equatable, Sendable {
        case empty
        /// Another project already has this name (case and surrounding spaces ignored).
        case duplicate
    }

    /// Checks the title typed for the project `slug` ("" for a new one) against the other projects.
    public static func titleProblem(_ title: String, slug: String, among projects: [Project]) -> TitleProblem? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .empty }
        let key = t.lowercased()
        let taken = projects.contains {
            $0.slug != slug && $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key
        }
        return taken ? .duplicate : nil
    }

    /// Project name per the contract: only `[a-z0-9_-]{1,64}`.
    public static func isValidSlug(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && s.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "_" || $0 == "-" }
    }

    public static func slugify(_ s: String) -> String {
        // l10n-ignore-start
        let map: [Character: String] = ["а":"a","б":"b","в":"v","г":"g","д":"d","е":"e","ё":"e","ж":"zh","з":"z","и":"i","й":"y",
            "к":"k","л":"l","м":"m","н":"n","о":"o","п":"p","р":"r","с":"s","т":"t","у":"u","ф":"f","х":"h","ц":"c",
            "ч":"ch","ш":"sh","щ":"sch","ъ":"","ы":"y","ь":"","э":"e","ю":"yu","я":"ya"]
        // l10n-ignore-end
        let out = s.lowercased().map { c -> String in
            if let m = map[c] { return m }
            if c.isASCII && (c.isLetter || c.isNumber) { return String(c) }
            return "-"
        }.joined()
        let slug = out.split(separator: "-").joined(separator: "-")
        return slug.isEmpty ? "project" : String(slug.prefix(40))
    }

    /// A free file name for a new project: "acme", "acme-2", …
    public static func uniqueSlug(for title: String, in dir: URL = Paths.profiles) -> String {
        let base = slugify(title)
        var slug = base
        var n = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(slug).json").path) {
            slug = "\(base)-\(n)"
            n += 1
        }
        return slug
    }

    /// Save without losing other fields (replacements and so on). Atomically: windows watch the projects
    /// folder, and a file replacement shows up to them as a folder change.
    public func save(in dir: URL = Paths.profiles) throws {
        let url = dir.appendingPathComponent("\(slug).json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Read, edit and write under the same lock the engine takes (MCP edits projects too).
        try FileLock.with(url) {
            var o: [String: Any] = [:]
            if let d = try? Data(contentsOf: url), let old = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { o = old }
            o["schema"] = Project.schema
            o["title"] = title
            o["context"] = context
            o["people"] = people
            o["terms"] = terms
            o["languages"] = languages.isEmpty ? nil : SpeechLanguage.serialize(languages)
            if o["replacements"] == nil { o["replacements"] = [Any]() }
            let d = try JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys])
            try d.write(to: url, options: .atomic)
        }
    }

    /// Remove the project file (people, terms, replacements). Calls keep their transcripts.
    /// By default the file goes to the Trash, so it can be restored; `remove` is replaceable for tests.
    public static func delete(_ slug: String, in dir: URL = Paths.profiles,
                              remove: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws {
        guard isValidSlug(slug) else { throw CocoaError(.fileNoSuchFile) }
        let url = dir.appendingPathComponent("\(slug).json")
        try FileLock.with(url) { try remove(url) }
    }
}

/// "Anna, Ivan\nOleg" -> ["Anna", "Ivan", "Oleg"].
public func splitList(_ s: String) -> [String] {
    s.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

/// A short people summary for tight spots: "Anna, Oleg +4". If only one name would be hidden, show everyone.
public func shortPeople(_ names: [String], max: Int = 2) -> String {
    guard names.count > max + 1 else { return names.joined(separator: ", ") }
    return names.prefix(max).joined(separator: ", ") + " +\(names.count - max)"
}

/// Project people for suggestions: from the project's past calls (most frequent first) and from the profile.
/// Never suggests yourself (`me`); "Anna Petrova" from the profile doesn't duplicate "Anna" from calls.
public func knownPeople(_ slug: String, calls: [Call], projects: [Project], me: String, limit: Int = 12) -> [String] {
    guard !slug.isEmpty else { return [] }
    var count: [String: Int] = [:]
    for c in calls where c.info.profile == slug {
        for n in splitList(c.people) { count[n, default: 0] += 1 }
    }
    let fromProfile = projects.first { $0.slug == slug }?.people ?? []
    for p in fromProfile where count[p] == nil {
        let first = p.split(separator: " ").first.map(String.init) ?? p
        if count.keys.contains(where: { $0 == first || $0.hasPrefix(first + " ") }) { continue }
        count[p] = 0
    }
    let me = me.lowercased()
    return count.filter { $0.key.lowercased() != me }
        .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        .prefix(limit).map(\.key)
}
