// Cursor has no `mcp add` command: MCP servers live in ~/.cursor/mcp.json, which is JSONC in practice
// (people keep // comments in it). So the Sozvon entry is edited as text: everything else in the file,
// comments, other servers and formatting, stays byte for byte. Anything we can't parse safely gives nil,
// and the app offers the Copy button instead of touching the file.

import Foundation

public enum CursorMCPConfig {
    // MARK: Public API

    /// Whether `mcpServers.<name>` points at `url` (and, when `token` is given, sends `Bearer <token>`).
    /// Commented-out entries don't count.
    public static func hasServer(_ text: String, name: String, url: String, token: String? = nil) -> Bool {
        guard let doc = Document(text), let entry = doc.entries(name).last?.value,
              case .object = entry.kind else { return false }
        guard doc.string(entry.member("url")?.value) == url else { return false }
        guard let token else { return true }
        let headers = entry.member("headers")?.value
        return doc.string(headers?.member("Authorization")?.value) == "Bearer \(token)"
    }

    /// Whether there is any `mcpServers.<name>` entry, whatever it points at.
    public static func hasEntry(_ text: String, name: String) -> Bool {
        Document(text).map { !$0.entries(name).isEmpty } ?? false
    }

    /// Adds or updates `"<name>": {"url": …, "headers": {"Authorization": "Bearer …"}}` in `mcpServers`.
    /// An existing entry is replaced in place (duplicates are removed); a new one becomes the first member.
    /// Empty text gives a new file; a top-level object without `mcpServers` gets one.
    /// nil: the text isn't JSON(C) we can edit safely.
    public static func upsert(_ text: String, name: String, url: String, token: String) -> String? {
        let value = Value.object([("url", .string(url)),
                                  ("headers", .object([("Authorization", .string("Bearer \(token)"))]))])
        var bytes = Array(text.utf8)
        guard var doc = Document(bytes: bytes) else { return nil }
        guard let root = doc.root else {
            // Nothing but whitespace or comments: the new document goes after them.
            let fresh = render(.object([("mcpServers", .object([(name, value)]))]), indent: "", unit: "  ") + "\n"
            let sep = bytes.isEmpty || bytes.last == UInt8(ascii: "\n") ? "" : "\n"
            return text + sep + fresh
        }
        guard case .object = root.kind else { return nil }
        let servers = root.members.filter { $0.key == "mcpServers" }
        guard servers.count <= 1 else { return nil }
        guard let serversNode = servers.first?.value else {
            return String(decoding: insertFirst(("mcpServers", .object([(name, value)])), into: root, bytes), as: UTF8.self)
        }
        guard case .object = serversNode.kind else { return nil }
        // Duplicates: drop all but the first, then replace the first in place.
        while doc.entries(name).count > 1 {
            guard let last = doc.entries(name).last, let objectNode = doc.servers,
                  let out = removeMember(last, from: objectNode, bytes) else { return nil }
            bytes = out
            guard let d = Document(bytes: bytes) else { return nil }
            doc = d
        }
        guard let objectNode = doc.servers else { return nil }
        if let existing = doc.entries(name).first {
            let (indent, unit, multiline) = layout(of: existing, in: objectNode, bytes)
            let rendered = multiline ? render(value, indent: indent, unit: unit) : renderInline(value)
            bytes.replaceSubrange(existing.value.start..<existing.value.end, with: Array(rendered.utf8))
            return String(decoding: bytes, as: UTF8.self)
        }
        return String(decoding: insertFirst((name, value), into: objectNode, bytes), as: UTF8.self)
    }

    /// Removes every `mcpServers.<name>` entry. No entry: the text comes back unchanged. nil: can't parse.
    public static func remove(_ text: String, name: String) -> String? {
        var bytes = Array(text.utf8)
        guard var doc = Document(bytes: bytes) else { return nil }
        while let last = doc.entries(name).last {
            guard let objectNode = doc.servers, let out = removeMember(last, from: objectNode, bytes) else { return nil }
            bytes = out
            guard let d = Document(bytes: bytes) else { return nil }
            doc = d
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The block to paste by hand (the Copy button), with a hint where it goes.
    public static func snippet(name: String, url: String, token: String) -> String {
        let value = Value.object([("url", .string(url)),
                                  ("headers", .object([("Authorization", .string("Bearer \(token)"))]))])
        return "// Add to \"mcpServers\" in ~/.cursor/mcp.json (Cursor and Cursor CLI both read it):\n"
            + quote(name) + ": " + render(value, indent: "", unit: "  ")
    }

    // MARK: Rendering

    enum Value {
        case string(String)
        case object([(String, Value)])
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    /// Pretty value; `indent` is the indentation of the line the value starts on.
    static func render(_ v: Value, indent: String, unit: String) -> String {
        switch v {
        case .string(let s): return quote(s)
        case .object(let members):
            if members.isEmpty { return "{}" }
            let inner = indent + unit
            let body = members.map { inner + quote($0.0) + ": " + render($0.1, indent: inner, unit: unit) }
            return "{\n" + body.joined(separator: ",\n") + "\n" + indent + "}"
        }
    }

    static func renderInline(_ v: Value) -> String {
        switch v {
        case .string(let s): return quote(s)
        case .object(let members):
            return "{" + members.map { quote($0.0) + ": " + renderInline($0.1) }.joined(separator: ", ") + "}"
        }
    }

    // MARK: Editing

    /// Whitespace between the start of the line and `pos`, if only spaces or tabs come before it on that line.
    static func linePrefix(_ pos: Int, _ b: [UInt8]) -> String? {
        var i = pos
        while i > 0, b[i - 1] == 0x20 || b[i - 1] == 0x09 { i -= 1 }
        guard i == 0 || b[i - 1] == 0x0A else { return nil }
        return String(decoding: b[i..<pos], as: UTF8.self)
    }

    /// Indentation of a member's line, the indentation unit, and whether the object is laid out one member per line.
    static func layout(of member: Member, in object: Node, _ b: [UInt8]) -> (String, String, Bool) {
        guard let indent = linePrefix(member.keyStart, b) else { return ("", "  ", false) }
        let outer = lineIndent(object.start, b)
        let unit = indent.hasPrefix(outer) && indent.count > outer.count ? String(indent.dropFirst(outer.count)) : "  "
        return (indent, unit, true)
    }

    /// Leading whitespace of the line containing `pos`.
    static func lineIndent(_ pos: Int, _ b: [UInt8]) -> String {
        var start = pos
        while start > 0, b[start - 1] != 0x0A { start -= 1 }
        var end = start
        while end < b.count, b[end] == 0x20 || b[end] == 0x09 { end += 1 }
        return String(decoding: b[start..<end], as: UTF8.self)
    }

    /// Inserts `member` right after the object's `{`.
    static func insertFirst(_ member: (String, Value), into object: Node, _ b: [UInt8]) -> [UInt8] {
        var out = b
        let at = object.start + 1
        let text: String
        if let first = object.members.first {
            let (indent, unit, multiline) = layout(of: first, in: object, b)
            text = multiline
                ? "\n" + indent + quote(member.0) + ": " + render(member.1, indent: indent, unit: unit) + ","
                : quote(member.0) + ": " + renderInline(member.1) + ", "
        } else {
            let outer = lineIndent(object.start, b)
            let indent = outer + "  "
            text = "\n" + indent + quote(member.0) + ": " + render(member.1, indent: indent, unit: "  ") + "\n" + outer
        }
        out.insert(contentsOf: Array(text.utf8), at: at)
        return out
    }

    /// Removes one member with its comma, and its whole line when nothing else is on it.
    static func removeMember(_ m: Member, from object: Node, _ b: [UInt8]) -> [UInt8]? {
        guard let idx = object.members.firstIndex(where: { $0.keyStart == m.keyStart }) else { return nil }
        var out = b
        var start = m.keyStart
        var end = m.value.end
        var prevComma: Int?
        if let comma = m.comma {
            end = comma + 1
        } else if idx > 0 {
            // Last member without a trailing comma: the previous member's comma goes instead.
            prevComma = object.members[idx - 1].comma
        }
        // Whole-line removal when the member owns its lines.
        var lineEnd = end
        while lineEnd < b.count, b[lineEnd] == 0x20 || b[lineEnd] == 0x09 { lineEnd += 1 }
        if linePrefix(start, b) != nil, lineEnd < b.count, b[lineEnd] == 0x0A {
            while start > 0, b[start - 1] == 0x20 || b[start - 1] == 0x09 { start -= 1 }
            end = lineEnd + 1
        } else if m.comma != nil {
            end = lineEnd  // inline: the space after the comma goes too
        }
        out.removeSubrange(start..<end)
        if let prevComma { out.remove(at: prevComma) }
        return out
    }

    // MARK: Parsing

    struct Member {
        let key: String
        let keyStart: Int
        let value: Node
        /// Position of the comma after the value, if any.
        let comma: Int?
    }

    final class Node {
        enum Kind { case object, array, string, scalar }
        let kind: Kind
        let start: Int
        var end: Int = 0
        var members: [Member] = []
        init(_ kind: Kind, start: Int) { self.kind = kind; self.start = start }
        func member(_ key: String) -> Member? { members.last { $0.key == key } }
    }

    struct Document {
        let bytes: [UInt8]
        /// nil: the text has no value at all (empty, or only comments).
        let root: Node?

        init?(_ text: String) { self.init(bytes: Array(text.utf8)) }

        init?(bytes: [UInt8]) {
            var p = Parser(b: bytes)
            do { root = try p.document() } catch { return nil }
            self.bytes = bytes
        }

        /// The top-level `mcpServers` object, if there is exactly one and it is an object.
        var servers: Node? {
            guard let root, case .object = root.kind else { return nil }
            let s = root.members.filter { $0.key == "mcpServers" }
            guard s.count == 1, case .object = s[0].value.kind else { return nil }
            return s[0].value
        }

        func entries(_ name: String) -> [Member] { servers?.members.filter { $0.key == name } ?? [] }

        func string(_ node: Node?) -> String? {
            guard let node, case .string = node.kind else { return nil }
            return Parser.decodeString(bytes[node.start..<node.end])
        }
    }

    enum ParseError: Error { case bad }

    struct Parser {
        let b: [UInt8]
        var i = 0
        var depth = 0

        init(b: [UInt8]) {
            self.b = b
            if b.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }  // UTF-8 BOM
        }

        mutating func document() throws -> Node? {
            try skipTrivia()
            if i == b.count { return nil }
            let v = try value()
            try skipTrivia()
            guard i == b.count else { throw ParseError.bad }
            return v
        }

        /// Whitespace, // line comments and /* block */ comments.
        mutating func skipTrivia() throws {
            while i < b.count {
                switch b[i] {
                case 0x20, 0x09, 0x0A, 0x0D:
                    i += 1
                case UInt8(ascii: "/") where i + 1 < b.count && b[i + 1] == UInt8(ascii: "/"):
                    while i < b.count, b[i] != 0x0A { i += 1 }
                case UInt8(ascii: "/") where i + 1 < b.count && b[i + 1] == UInt8(ascii: "*"):
                    i += 2
                    while i + 1 < b.count, !(b[i] == UInt8(ascii: "*") && b[i + 1] == UInt8(ascii: "/")) { i += 1 }
                    guard i + 1 < b.count else { throw ParseError.bad }
                    i += 2
                default:
                    return
                }
            }
        }

        mutating func value() throws -> Node {
            guard i < b.count else { throw ParseError.bad }
            depth += 1
            defer { depth -= 1 }
            guard depth < 200 else { throw ParseError.bad }
            switch b[i] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return try string()
            default: return try scalar()
            }
        }

        mutating func object() throws -> Node {
            let node = Node(.object, start: i)
            i += 1
            while true {
                try skipTrivia()
                guard i < b.count else { throw ParseError.bad }
                if b[i] == UInt8(ascii: "}") { break }
                guard b[i] == UInt8(ascii: "\"") else { throw ParseError.bad }
                let keyNode = try string()
                guard let key = Self.decodeString(b[keyNode.start..<keyNode.end]) else { throw ParseError.bad }
                try skipTrivia()
                guard i < b.count, b[i] == UInt8(ascii: ":") else { throw ParseError.bad }
                i += 1
                try skipTrivia()
                let v = try value()
                try skipTrivia()
                guard i < b.count else { throw ParseError.bad }
                if b[i] == UInt8(ascii: ",") {
                    node.members.append(Member(key: key, keyStart: keyNode.start, value: v, comma: i))
                    i += 1
                } else if b[i] == UInt8(ascii: "}") {
                    node.members.append(Member(key: key, keyStart: keyNode.start, value: v, comma: nil))
                    break
                } else {
                    throw ParseError.bad
                }
            }
            i += 1
            node.end = i
            return node
        }

        mutating func array() throws -> Node {
            let node = Node(.array, start: i)
            i += 1
            while true {
                try skipTrivia()
                guard i < b.count else { throw ParseError.bad }
                if b[i] == UInt8(ascii: "]") { break }
                _ = try value()
                try skipTrivia()
                guard i < b.count else { throw ParseError.bad }
                if b[i] == UInt8(ascii: ",") { i += 1 } else if b[i] != UInt8(ascii: "]") { throw ParseError.bad }
            }
            i += 1
            node.end = i
            return node
        }

        mutating func string() throws -> Node {
            let node = Node(.string, start: i)
            i += 1
            while i < b.count {
                switch b[i] {
                case UInt8(ascii: "\""):
                    i += 1
                    node.end = i
                    return node
                case UInt8(ascii: "\\"):
                    i += 2
                case 0x00..<0x20:
                    throw ParseError.bad  // raw control characters (a newline) aren't allowed in a string
                default:
                    i += 1
                }
            }
            throw ParseError.bad
        }

        mutating func scalar() throws -> Node {
            let node = Node(.scalar, start: i)
            let allowed = Set("+-.0123456789eEtruefalsn".utf8)
            while i < b.count, allowed.contains(b[i]) { i += 1 }
            let token = String(decoding: b[node.start..<i], as: UTF8.self)
            guard ["true", "false", "null"].contains(token) || (!token.isEmpty && Double(token) != nil
                    && token.first.map { $0 == "-" || $0.isNumber } == true) else { throw ParseError.bad }
            node.end = i
            return node
        }

        /// A quoted JSON string token -> its value.
        static func decodeString(_ raw: ArraySlice<UInt8>) -> String? {
            guard raw.count >= 2 else { return nil }
            if !raw.contains(UInt8(ascii: "\\")) {
                return String(decoding: raw.dropFirst().dropLast(), as: UTF8.self)
            }
            return (try? JSONSerialization.jsonObject(with: Data(raw), options: .fragmentsAllowed)) as? String
        }
    }
}
