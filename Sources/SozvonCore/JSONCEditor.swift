// Shared machinery to edit a named entry inside a JSON(C) document as text: everything else in the
// file — comments, other servers, key order, number formatting — stays byte for byte. Used for the
// MCP configs of Cursor (mcpServers), ZCode and OpenCode (mcp.servers). Anything that fails to
// parse gives nil, and the app offers the Copy button instead of touching the file.

import Foundation

enum JSONCEditor {
    // MARK: Values

    enum Value {
        case string(String)
        case bool(Bool)
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
        case .bool(let b): return b ? "true" : "false"
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
        case .bool(let b): return b ? "true" : "false"
        case .object(let members):
            return "{" + members.map { quote($0.0) + ": " + renderInline($0.1) }.joined(separator: ", ") + "}"
        }
    }

    // MARK: Model

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
        /// Every member with this key, in order.
        func members(_ key: String) -> [Member] { members.filter { $0.key == key } }
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

    // MARK: Editing primitives

    /// Whitespace between the start of the line and `pos`, if only spaces or tabs come before it on that line.
    static func linePrefix(_ pos: Int, _ b: [UInt8]) -> String? {
        var i = pos
        while i > 0, b[i - 1] == 0x20 || b[i - 1] == 0x09 { i -= 1 }
        guard i == 0 || b[i - 1] == 0x0A else { return nil }
        return String(decoding: b[i..<pos], as: UTF8.self)
    }

    /// Leading whitespace of the line containing `pos`.
    static func lineIndent(_ pos: Int, _ b: [UInt8]) -> String {
        var start = pos
        while start > 0, b[start - 1] != 0x0A { start -= 1 }
        var end = start
        while end < b.count, b[end] == 0x20 || b[end] == 0x09 { end += 1 }
        return String(decoding: b[start..<end], as: UTF8.self)
    }

    /// Indentation of a member's line, the indentation unit, and whether the object is laid out one member per line.
    static func layout(of member: Member, in object: Node, _ b: [UInt8]) -> (String, String, Bool) {
        guard let indent = linePrefix(member.keyStart, b) else { return ("", "  ", false) }
        let outer = lineIndent(object.start, b)
        let unit = indent.hasPrefix(outer) && indent.count > outer.count ? String(indent.dropFirst(outer.count)) : "  "
        return (indent, unit, true)
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

    // MARK: Document editing

    /// A mutable editing session over one document. Nodes are re-fetched from the current parse
    /// after every change, so no node reference outlives an edit.
    struct Edit {
        private(set) var bytes: [UInt8]
        private var doc: Document

        init?(_ text: String) {
            guard let doc = Document(text) else { return nil }
            self.doc = doc
            self.bytes = doc.bytes
        }

        var text: String { String(decoding: bytes, as: UTF8.self) }

        /// The object at `path` walked down from the root (the root itself for an empty path):
        /// every segment must be a single object. nil: the path is missing or ambiguous, or the
        /// root isn't an object.
        func container(_ path: [String]) -> Node? {
            guard let root = doc.root, case .object = root.kind else { return nil }
            var node = root
            for key in path {
                let matches = node.members(key)
                guard matches.count == 1, case .object = matches[0].value.kind else { return nil }
                node = matches[0].value
            }
            return node
        }

        /// The string value of a node (the entry's field lookups).
        func string(_ node: Node?) -> String? { doc.string(node) }

        private mutating func reparsed() -> Bool {
            guard let d = Document(bytes: bytes) else { return false }
            doc = d
            return true
        }

        private mutating func insert(_ member: (String, Value), into container: Node) -> Bool {
            bytes = JSONCEditor.insertFirst(member, into: container, bytes)
            return reparsed()
        }

        private mutating func remove(_ member: Member, from container: Node) -> Bool {
            guard let out = JSONCEditor.removeMember(member, from: container, bytes) else { return false }
            bytes = out
            return reparsed()
        }

        /// Replaces the member's value in place, keeping its layout.
        private mutating func replace(_ member: Member, in container: Node, with value: Value) -> Bool {
            let (indent, unit, multiline) = layout(of: member, in: container, bytes)
            let rendered = multiline ? JSONCEditor.render(value, indent: indent, unit: unit) : renderInline(value)
            bytes.replaceSubrange(member.value.start..<member.value.end, with: Array(rendered.utf8))
            return reparsed()
        }

        /// Adds or updates `name` in the object at `path`, creating missing containers along the
        /// path. Duplicated `name` entries collapse into the first one. An existing path segment
        /// that isn't a single object refuses the edit (false); so does a non-object root.
        mutating func upsert(_ name: String, value: Value, path: [String]) -> Bool {
            guard let root = doc.root else {
                // Nothing but whitespace or comments: the new document goes after them.
                var fresh: Value = .object([(name, value)])
                for key in path.reversed() { fresh = .object([(key, fresh)]) }
                let sep = bytes.isEmpty || bytes.last == 0x0A ? "" : "\n"
                bytes += Array((sep + JSONCEditor.render(fresh, indent: "", unit: "  ") + "\n").utf8)
                return reparsed()
            }
            guard case .object = root.kind else { return false }
            var walked: [String] = []
            for key in path {
                guard let container = container(walked) else { return false }
                let matches = container.members(key)
                if matches.count > 1 { return false }
                guard let existing = matches.first else {
                    // Missing container: wrap the rest of the path with the entry inside.
                    var inner: Value = .object([(name, value)])
                    for later in path.dropFirst(walked.count + 1).reversed() { inner = .object([(later, inner)]) }
                    return insert((key, inner), into: container)
                }
                guard case .object = existing.value.kind else { return false }
                walked.append(key)
            }
            while let container = self.container(path), let last = container.members(name).last,
                  container.members(name).count > 1 {
                guard remove(last, from: container) else { return false }
            }
            guard let container = self.container(path) else { return false }
            if let existing = container.member(name) {
                return replace(existing, in: container, with: value)
            }
            return insert((name, value), into: container)
        }

        /// Removes every `name` entry from the object at `path`. No entry, or a missing or broken
        /// path: nothing to do (true). A document whose root isn't a JSON object is refused (false),
        /// like upsert. false is also returned when the document stops parsing mid-edit.
        mutating func remove(_ name: String, path: [String]) -> Bool {
            if let root = doc.root, case .object = root.kind {
                // expected shape; fall through
            } else if doc.root != nil {
                return false
            } else {
                return true  // no value at all: nothing to remove
            }
            while let container = container(path), let last = container.members(name).last {
                guard remove(last, from: container) else { return false }
            }
            return true
        }
    }
}
