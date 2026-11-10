using System.Globalization;
using System.Text;
using System.Text.Json;

namespace Sozvon.Core.Assistants;

/// <summary>
/// Cursor has no <c>mcp add</c> command: its MCP servers live in %USERPROFILE%\.cursor\mcp.json, which is JSONC in practice
/// (people keep // comments in it). So the Sozvon entry is edited as text, as on the Mac: everything else in the file,
/// comments, other servers and formatting, stays character for character. Anything that cannot be parsed safely gives
/// null, and the app offers the Copy button instead of touching the file.
/// </summary>
public static class CursorMcpConfig
{
    /// <summary>Whether <c>mcpServers.&lt;name&gt;</c> points at <paramref name="url"/> and, with a token, sends it. Commented-out entries don't count.</summary>
    public static bool HasServer(string text, string name, string url, string? token = null)
    {
        if (Document.Parse(text) is not { } doc || doc.Entries(name).LastOrDefault()?.Value is not { Kind: Kind.Object } entry) return false;
        if (doc.String(entry.Member("url")?.Value) != url) return false;
        if (token is null) return true;
        return doc.String(entry.Member("headers")?.Value?.Member("Authorization")?.Value) == $"Bearer {token}";
    }

    /// <summary>Whether there is any <c>mcpServers.&lt;name&gt;</c> entry, whatever it points at.</summary>
    public static bool HasEntry(string text, string name) => Document.Parse(text)?.Entries(name).Count > 0;

    /// <summary>
    /// Adds or updates <c>"&lt;name&gt;": {"url": …, "headers": {"Authorization": "Bearer …"}}</c> in <c>mcpServers</c>. An
    /// existing entry is replaced in place (duplicates are removed); a new one becomes the first member. Empty text gives
    /// a new file; a top-level object without <c>mcpServers</c> gets one. Null: not JSON(C) that can be edited safely.
    /// </summary>
    public static string? Upsert(string text, string name, string url, string token)
    {
        var value = Entry(url, token);
        if (Document.Parse(text) is not { } doc) return null;
        if (doc.Root is not { } root)
        {
            // Nothing but whitespace or comments: the new document goes after them.
            var fresh = Render(new Value.Object([("mcpServers", new Value.Object([(name, value)]))]), "", "  ") + "\n";
            var separator = text.Length == 0 || text.EndsWith('\n') ? "" : "\n";
            return text + separator + fresh;
        }
        if (root.Kind != Kind.Object) return null;
        var servers = root.Members.Where(m => m.Key == "mcpServers").ToList();
        if (servers.Count > 1) return null;
        if (servers.Count == 0) return InsertFirst(("mcpServers", new Value.Object([(name, value)])), root, text);
        if (servers[0].Value.Kind != Kind.Object) return null;
        while (doc.Entries(name).Count > 1)
        {
            if (doc.Servers is not { } holder || RemoveMember(doc.Entries(name)[^1], holder, text) is not { } shorter) return null;
            text = shorter;
            if (Document.Parse(text) is not { } reparsed) return null;
            doc = reparsed;
        }
        if (doc.Servers is not { } objectNode) return null;
        if (doc.Entries(name).FirstOrDefault() is { } existing)
        {
            var (indent, unit, multiline) = Layout(existing, objectNode, text);
            var rendered = multiline ? Render(value, indent, unit) : RenderInline(value);
            return text[..existing.Value.Start] + rendered + text[existing.Value.End..];
        }
        return InsertFirst((name, value), objectNode, text);
    }

    /// <summary>Removes every <c>mcpServers.&lt;name&gt;</c> entry. No entry: the text comes back unchanged. Null: cannot parse.</summary>
    public static string? Remove(string text, string name)
    {
        if (Document.Parse(text) is not { } doc) return null;
        while (doc.Entries(name).LastOrDefault() is { } last)
        {
            if (doc.Servers is not { } holder || RemoveMember(last, holder, text) is not { } shorter) return null;
            text = shorter;
            if (Document.Parse(text) is not { } reparsed) return null;
            doc = reparsed;
        }
        return text;
    }

    /// <summary>The block to paste by hand (the Copy button), with a hint where it goes.</summary>
    public static string Snippet(string name, string url, string token) =>
        "// Add to \"mcpServers\" in %USERPROFILE%\\.cursor\\mcp.json (Cursor and Cursor CLI both read it):\n"
        + Quote(name) + ": " + Render(Entry(url, token), "", "  ");

    private static Value Entry(string url, string token) =>
        new Value.Object([("url", new Value.Text(url)), ("headers", new Value.Object([("Authorization", new Value.Text($"Bearer {token}"))]))]);

    // Rendering

    private abstract record Value
    {
        public sealed record Text(string Content) : Value;

        public sealed record Object(IReadOnlyList<(string Key, Value Value)> Members) : Value;
    }

    internal static string Quote(string s)
    {
        var quoted = new StringBuilder("\"");
        foreach (var ch in s)
        {
            quoted.Append(ch switch
            {
                '"' => "\\\"",
                '\\' => "\\\\",
                '\n' => "\\n",
                '\r' => "\\r",
                '\t' => "\\t",
                < ' ' => "\\u" + ((int)ch).ToString("x4", CultureInfo.InvariantCulture),
                _ => ch.ToString(),
            });
        }
        return quoted.Append('"').ToString();
    }

    /// <summary>A pretty value; <paramref name="indent"/> is the indentation of the line the value starts on.</summary>
    private static string Render(Value value, string indent, string unit)
    {
        if (value is Value.Text text) return Quote(text.Content);
        var members = ((Value.Object)value).Members;
        if (members.Count == 0) return "{}";
        var inner = indent + unit;
        return "{\n" + string.Join(",\n", members.Select(m => inner + Quote(m.Key) + ": " + Render(m.Value, inner, unit))) + "\n" + indent + "}";
    }

    private static string RenderInline(Value value) => value is Value.Text text
        ? Quote(text.Content)
        : "{" + string.Join(", ", ((Value.Object)value).Members.Select(m => Quote(m.Key) + ": " + RenderInline(m.Value))) + "}";

    // Editing

    /// <summary>The whitespace between the start of the line and <paramref name="pos"/>, when only spaces or tabs come before it.</summary>
    private static string? LinePrefix(int pos, string b)
    {
        var i = pos;
        while (i > 0 && b[i - 1] is ' ' or '\t') i--;
        return i == 0 || b[i - 1] == '\n' ? b[i..pos] : null;
    }

    /// <summary>The indentation of a member's line, the indentation unit, and whether the object has one member per line.</summary>
    private static (string Indent, string Unit, bool Multiline) Layout(Member member, Node holder, string b)
    {
        if (LinePrefix(member.KeyStart, b) is not { } indent) return ("", "  ", false);
        var outer = LineIndent(holder.Start, b);
        var unit = indent.StartsWith(outer, StringComparison.Ordinal) && indent.Length > outer.Length ? indent[outer.Length..] : "  ";
        return (indent, unit, true);
    }

    /// <summary>The leading whitespace of the line holding <paramref name="pos"/>.</summary>
    private static string LineIndent(int pos, string b)
    {
        var start = pos;
        while (start > 0 && b[start - 1] != '\n') start--;
        var end = start;
        while (end < b.Length && b[end] is ' ' or '\t') end++;
        return b[start..end];
    }

    /// <summary>Inserts the member right after the object's <c>{</c>.</summary>
    private static string InsertFirst((string Key, Value Value) member, Node holder, string b)
    {
        string inserted;
        if (holder.Members.FirstOrDefault() is { } first)
        {
            var (indent, unit, multiline) = Layout(first, holder, b);
            inserted = multiline
                ? "\n" + indent + Quote(member.Key) + ": " + Render(member.Value, indent, unit) + ","
                : Quote(member.Key) + ": " + RenderInline(member.Value) + ", ";
        }
        else
        {
            var outer = LineIndent(holder.Start, b);
            var indent = outer + "  ";
            inserted = "\n" + indent + Quote(member.Key) + ": " + Render(member.Value, indent, "  ") + "\n" + outer;
        }
        return b.Insert(holder.Start + 1, inserted);
    }

    /// <summary>Removes one member with its comma, and its whole line when nothing else is on it.</summary>
    private static string? RemoveMember(Member m, Node holder, string b)
    {
        var index = holder.Members.FindIndex(x => x.KeyStart == m.KeyStart);
        if (index < 0) return null;
        var start = m.KeyStart;
        var end = m.Value.End;
        int? previousComma = null;
        if (m.Comma is { } comma) end = comma + 1;
        else if (index > 0) previousComma = holder.Members[index - 1].Comma; // the last member: the comma before it goes instead
        var lineEnd = end;
        while (lineEnd < b.Length && b[lineEnd] is ' ' or '\t') lineEnd++;
        if (LinePrefix(start, b) is not null && lineEnd < b.Length && b[lineEnd] is '\n' or '\r')
        {
            while (start > 0 && b[start - 1] is ' ' or '\t') start--;
            end = b[lineEnd] == '\r' && lineEnd + 1 < b.Length && b[lineEnd + 1] == '\n' ? lineEnd + 2 : lineEnd + 1;
        }
        else if (m.Comma is not null)
        {
            end = lineEnd; // inline: the space after the comma goes too
        }
        var removed = b.Remove(start, end - start);
        return previousComma is { } p ? removed.Remove(p, 1) : removed;
    }

    // Parsing

    private enum Kind { Object, Array, String, Scalar }

    private sealed record Member(string Key, int KeyStart, Node Value, int? Comma);

    private sealed class Node(Kind kind, int start)
    {
        public Kind Kind { get; } = kind;
        public int Start { get; } = start;
        public int End { get; set; }
        public List<Member> Members { get; } = [];

        public Member? Member(string key) => Members.LastOrDefault(m => m.Key == key);
    }

    private sealed class Document(string text, Node? root)
    {
        /// <summary>Null: the text has no value at all (empty, or only comments).</summary>
        public Node? Root { get; } = root;

        public static Document? Parse(string text)
        {
            try
            {
                return new Document(text, new Parser(text).Document());
            }
            catch (FormatException)
            {
                return null;
            }
        }

        /// <summary>The top-level <c>mcpServers</c> object, when there is exactly one and it is an object.</summary>
        public Node? Servers
        {
            get
            {
                if (Root is not { Kind: Kind.Object } root) return null;
                var servers = root.Members.Where(m => m.Key == "mcpServers").ToList();
                return servers.Count == 1 && servers[0].Value.Kind == Kind.Object ? servers[0].Value : null;
            }
        }

        public List<Member> Entries(string name) => Servers?.Members.Where(m => m.Key == name).ToList() ?? [];

        public string? String(Node? node) => node is { Kind: Kind.String } ? Parser.Decode(text[node.Start..node.End]) : null;
    }

    private sealed class Parser(string b)
    {
        private const int MaxDepth = 200;
        private int _i = b.StartsWith('﻿') ? 1 : 0;
        private int _depth;

        public Node? Document()
        {
            SkipTrivia();
            if (_i == b.Length) return null;
            var value = Value();
            SkipTrivia();
            if (_i != b.Length) throw new FormatException();
            return value;
        }

        /// <summary>Whitespace, // line comments and /* block */ comments.</summary>
        private void SkipTrivia()
        {
            while (_i < b.Length)
            {
                if (b[_i] is ' ' or '\t' or '\n' or '\r')
                {
                    _i++;
                }
                else if (b[_i] == '/' && _i + 1 < b.Length && b[_i + 1] == '/')
                {
                    while (_i < b.Length && b[_i] != '\n') _i++;
                }
                else if (b[_i] == '/' && _i + 1 < b.Length && b[_i + 1] == '*')
                {
                    _i += 2;
                    while (_i + 1 < b.Length && !(b[_i] == '*' && b[_i + 1] == '/')) _i++;
                    if (_i + 1 >= b.Length) throw new FormatException();
                    _i += 2;
                }
                else
                {
                    return;
                }
            }
        }

        private Node Value()
        {
            if (_i >= b.Length || ++_depth >= MaxDepth) throw new FormatException();
            try
            {
                return b[_i] switch
                {
                    '{' => Object(),
                    '[' => Array(),
                    '"' => String(),
                    _ => Scalar(),
                };
            }
            finally
            {
                _depth--;
            }
        }

        private Node Object()
        {
            var node = new Node(Kind.Object, _i++);
            while (true)
            {
                SkipTrivia();
                if (_i >= b.Length) throw new FormatException();
                if (b[_i] == '}') break;
                if (b[_i] != '"') throw new FormatException();
                var keyNode = String();
                var key = Decode(b[keyNode.Start..keyNode.End]) ?? throw new FormatException();
                SkipTrivia();
                if (_i >= b.Length || b[_i] != ':') throw new FormatException();
                _i++;
                SkipTrivia();
                var value = Value();
                SkipTrivia();
                if (_i >= b.Length) throw new FormatException();
                if (b[_i] == ',')
                {
                    node.Members.Add(new Member(key, keyNode.Start, value, _i));
                    _i++;
                }
                else if (b[_i] == '}')
                {
                    node.Members.Add(new Member(key, keyNode.Start, value, null));
                    break;
                }
                else
                {
                    throw new FormatException();
                }
            }
            node.End = ++_i;
            return node;
        }

        private Node Array()
        {
            var node = new Node(Kind.Array, _i++);
            while (true)
            {
                SkipTrivia();
                if (_i >= b.Length) throw new FormatException();
                if (b[_i] == ']') break;
                Value();
                SkipTrivia();
                if (_i >= b.Length) throw new FormatException();
                if (b[_i] == ',') _i++;
                else if (b[_i] != ']') throw new FormatException();
            }
            node.End = ++_i;
            return node;
        }

        private Node String()
        {
            var node = new Node(Kind.String, _i++);
            while (_i < b.Length)
            {
                switch (b[_i])
                {
                    case '"':
                        node.End = ++_i;
                        return node;
                    case '\\':
                        _i += 2;
                        break;
                    case < ' ':
                        throw new FormatException(); // a raw control character (a newline) is not allowed in a string
                    default:
                        _i++;
                        break;
                }
            }
            throw new FormatException();
        }

        private Node Scalar()
        {
            var node = new Node(Kind.Scalar, _i);
            while (_i < b.Length && "+-.0123456789eEtruefalsn".Contains(b[_i])) _i++;
            var token = b[node.Start.._i];
            var number = token.Length > 0 && (token[0] == '-' || char.IsAsciiDigit(token[0]))
                && double.TryParse(token, NumberStyles.Float, CultureInfo.InvariantCulture, out _);
            if (token is not ("true" or "false" or "null") && !number) throw new FormatException();
            node.End = _i;
            return node;
        }

        /// <summary>A quoted JSON string token as its value.</summary>
        internal static string? Decode(string raw)
        {
            if (raw.Length < 2) return null;
            if (!raw.Contains('\\')) return raw[1..^1];
            try
            {
                return JsonSerializer.Deserialize<string>(raw);
            }
            catch (JsonException)
            {
                return null;
            }
        }
    }
}
