import Foundation

/// A JSON document as written: object keys keep their order and numbers keep their exact
/// text, so nothing changes on the way to another format (Foundation's parser loses both).
indirect enum JSONValue: Equatable {
    case object([(key: String, value: JSONValue)])
    case array([JSONValue])
    case string(String)
    /// The literal as it appears in the file (e.g. `1.50`, `12345678901234567890`).
    case number(String)
    case bool(Bool)
    case null

    static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case let (.object(a), .object(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        case let (.array(a), .array(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.number(a), .number(b)): return a == b
        case let (.bool(a), .bool(b)): return a == b
        case (.null, .null): return true
        default: return false
        }
    }
}

// MARK: - Parsing

/// Strict RFC 8259 parser over UTF-8 bytes, with a nesting limit so a hostile file
/// (`[[[[…`) can't exhaust the stack.
struct JSONParser {
    static let maxDepth = 512

    struct Failure: Error {
        let message: String
        let line: Int
        let column: Int
    }

    private let bytes: [UInt8]
    private var index = 0

    static func parse(_ data: Data) throws -> JSONValue {
        var parser = JSONParser(bytes: Array(data))
        // A UTF-8 byte order mark is allowed by many editors; skip it.
        if parser.bytes.starts(with: [0xEF, 0xBB, 0xBF]) { parser.index = 3 }
        parser.skipWhitespace()
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw parser.failure(L("there is more text after the end of the data")) }
        return value
    }

    private init(bytes: [UInt8]) { self.bytes = bytes }

    private func failure(_ message: String) -> Failure {
        let upTo = bytes[..<min(index, bytes.count)]
        let line = upTo.filter { $0 == 0x0A }.count + 1
        let column = upTo.count - (upTo.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0) + 1
        return Failure(message: message, line: line, column: column)
    }

    private var current: UInt8? { index < bytes.count ? bytes[index] : nil }

    /// A cut-off file is told apart from a wrong character, since that is the usual cause.
    private func unexpected(_ message: String) -> Failure {
        current == nil ? failure(L("the data ends too early")) : failure(message)
    }

    private mutating func skipWhitespace() {
        while let byte = current, byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 { index += 1 }
    }

    private mutating func expect(_ literal: String, _ value: JSONValue) throws -> JSONValue {
        let expected = Array(literal.utf8)
        guard bytes.count - index >= expected.count, Array(bytes[index..<index + expected.count]) == expected else {
            throw failure(L("unexpected character"))
        }
        index += expected.count
        return value
    }

    private mutating func value(depth: Int) throws -> JSONValue {
        guard depth < JSONParser.maxDepth else { throw failure(L("the data is nested more than %@ levels deep", String(JSONParser.maxDepth))) }
        guard let byte = current else { throw failure(L("the data ends too early")) }
        switch byte {
        case UInt8(ascii: "{"): return try object(depth: depth)
        case UInt8(ascii: "["): return try array(depth: depth)
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): return try expect("true", .bool(true))
        case UInt8(ascii: "f"): return try expect("false", .bool(false))
        case UInt8(ascii: "n"): return try expect("null", .null)
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try number())
        default: throw failure(L("unexpected character"))
        }
    }

    private mutating func object(depth: Int) throws -> JSONValue {
        index += 1
        var members: [(key: String, value: JSONValue)] = []
        skipWhitespace()
        if current == UInt8(ascii: "}") { index += 1; return .object(members) }
        while true {
            skipWhitespace()
            guard current == UInt8(ascii: "\"") else { throw unexpected(L("a key in quotes was expected")) }
            let key = try string()
            skipWhitespace()
            guard current == UInt8(ascii: ":") else { throw unexpected(L("“:” was expected after a key")) }
            index += 1
            skipWhitespace()
            members.append((key, try value(depth: depth + 1)))
            skipWhitespace()
            if current == UInt8(ascii: ",") { index += 1; continue }
            if current == UInt8(ascii: "}") { index += 1; return .object(members) }
            throw unexpected(L("“,” or “}” was expected"))
        }
    }

    private mutating func array(depth: Int) throws -> JSONValue {
        index += 1
        var elements: [JSONValue] = []
        skipWhitespace()
        if current == UInt8(ascii: "]") { index += 1; return .array(elements) }
        while true {
            skipWhitespace()
            elements.append(try value(depth: depth + 1))
            skipWhitespace()
            if current == UInt8(ascii: ",") { index += 1; continue }
            if current == UInt8(ascii: "]") { index += 1; return .array(elements) }
            throw unexpected(L("“,” or “]” was expected"))
        }
    }

    private mutating func number() throws -> String {
        let start = index
        if current == UInt8(ascii: "-") { index += 1 }
        func digits() -> Int {
            let from = index
            while let byte = current, byte >= 0x30 && byte <= 0x39 { index += 1 }
            return index - from
        }
        if current == UInt8(ascii: "0") { index += 1 } else if digits() == 0 { throw failure(L("invalid number")) }
        if current == UInt8(ascii: ".") {
            index += 1
            guard digits() > 0 else { throw failure(L("invalid number")) }
        }
        if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
            index += 1
            if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { index += 1 }
            guard digits() > 0 else { throw failure(L("invalid number")) }
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private mutating func string() throws -> String {
        index += 1
        var scalars = String.UnicodeScalarView()
        var raw: [UInt8] = []
        func flush() {
            if !raw.isEmpty { scalars.append(contentsOf: String(decoding: raw, as: UTF8.self).unicodeScalars); raw.removeAll() }
        }
        while let byte = current {
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                flush()
                return String(scalars)
            case UInt8(ascii: "\\"):
                flush()
                index += 1
                guard let escape = current else { throw failure(L("the data ends too early")) }
                index += 1
                switch escape {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800...0xDBFF).contains(code), current == UInt8(ascii: "\\"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "u") {
                        index += 2
                        let low = try hex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw failure(L("invalid character code")) }
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    // A lone surrogate can't be stored as text; keep the replacement character.
                    scalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                default:
                    throw failure(L("invalid escape sequence"))
                }
            case 0x00..<0x20:
                throw failure(L("a control character must be escaped inside text"))
            default:
                raw.append(byte)
                index += 1
            }
        }
        throw failure(L("the data ends too early"))
    }

    private mutating func hex4() throws -> UInt32 {
        guard bytes.count - index >= 4, let code = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else {
            throw failure(L("invalid character code"))
        }
        index += 4
        return code
    }
}

// MARK: - Writing

enum JSONWriter {
    /// Pretty-printed with two spaces, keys in their original order, numbers as written.
    static func string(_ value: JSONValue, indent: String = "") -> String {
        let inner = indent + "  "
        switch value {
        case .object(let members):
            guard !members.isEmpty else { return "{}" }
            return "{\n" + members.map { inner + quote($0.key) + ": " + string($0.value, indent: inner) }.joined(separator: ",\n") + "\n" + indent + "}"
        case .array(let elements):
            guard !elements.isEmpty else { return "[]" }
            return "[\n" + elements.map { inner + string($0, indent: inner) }.joined(separator: ",\n") + "\n" + indent + "]"
        case .string(let text): return quote(text)
        case .number(let literal): return literal
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "null"
        }
    }

    static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

/// YAML 1.2 block style. Every JSON document is valid YAML, so nothing is lost: text that
/// could be read as something else (numbers, `yes`, dates, empty) is quoted.
enum YAMLWriter {
    static func document(_ value: JSONValue) -> String {
        switch value {
        case .object(let members) where !members.isEmpty: return block(value, indent: "") + "\n"
        case .array(let elements) where !elements.isEmpty: return block(value, indent: "") + "\n"
        default: return scalar(value) + "\n"
        }
    }

    private static func block(_ value: JSONValue, indent: String) -> String {
        switch value {
        case .object(let members):
            return members.map { member in
                let key = indent + scalar(.string(member.key)) + ":"
                switch member.value {
                case .object(let inner) where !inner.isEmpty: return key + "\n" + block(member.value, indent: indent + "  ")
                case .array(let inner) where !inner.isEmpty: return key + "\n" + block(member.value, indent: indent + "  ")
                default: return key + " " + scalar(member.value)
                }
            }.joined(separator: "\n")
        case .array(let elements):
            return elements.map { element in
                switch element {
                case .object(let inner) where !inner.isEmpty:
                    // The first key goes on the dash line; the rest line up under it.
                    let nested = block(element, indent: indent + "  ")
                    return indent + "- " + nested.dropFirst(indent.count + 2)
                case .array(let inner) where !inner.isEmpty:
                    return indent + "-\n" + block(element, indent: indent + "  ")
                default:
                    return indent + "- " + scalar(element)
                }
            }.joined(separator: "\n")
        default:
            return indent + scalar(value)
        }
    }

    static func scalar(_ value: JSONValue) -> String {
        switch value {
        case .object: return "{}"
        case .array: return "[]"
        case .number(let literal): return literal
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "null"
        case .string(let text): return isPlainSafe(text) ? text : JSONWriter.quote(text)
        }
    }

    private static let reserved: Set<String> = ["true", "false", "yes", "no", "on", "off", "y", "n", "null", "~", ".nan", ".inf", "-.inf", "<<"]

    /// Plain (unquoted) only for text that YAML can't mistake for anything else.
    static func isPlainSafe(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first, let last = text.unicodeScalars.last else { return false }
        guard !reserved.contains(text.lowercased()) else { return false }
        guard CharacterSet.letters.contains(first) || first == "_" else { return false }
        guard last != " ", last != ":" else { return false }
        guard !text.contains(": "), !text.contains(" #") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " _-./()'&+,"))
        return text.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

// MARK: - XML

/// JSON ↔ XML without losing anything. Each key becomes an element; what XML can't say on
/// its own is marked with a `type` attribute (number, boolean, null, array, object), and keys
/// that aren't valid element names go in `<entry key="…">`. Reading such a file back gives
/// the same JSON; any other XML maps attributes to `@name` and mixed text to `#text`.
enum XMLBridge {
    static func document(_ value: JSONValue) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + element("root", key: nil, value, indent: "") + "\n"
    }

    private static func element(_ name: String, key: String?, _ value: JSONValue, indent: String) -> String {
        var attributes = key.map { " key=\"\(escape($0, attribute: true))\"" } ?? ""
        let inner = indent + "  "
        switch value {
        case .object(let members):
            if members.isEmpty { return indent + "<\(name)\(attributes) type=\"object\"/>" }
            let children = members.map { member -> String in
                isName(member.key) ? element(member.key, key: nil, member.value, indent: inner)
                    : element("entry", key: member.key, member.value, indent: inner)
            }
            return indent + "<\(name)\(attributes)>\n" + children.joined(separator: "\n") + "\n" + indent + "</\(name)>"
        case .array(let elements):
            attributes += " type=\"array\""
            if elements.isEmpty { return indent + "<\(name)\(attributes)/>" }
            let children = elements.map { element("item", key: nil, $0, indent: inner) }
            return indent + "<\(name)\(attributes)>\n" + children.joined(separator: "\n") + "\n" + indent + "</\(name)>"
        case .string(let text):
            return text.isEmpty ? indent + "<\(name)\(attributes)/>" : indent + "<\(name)\(attributes)>\(escape(text, attribute: false))</\(name)>"
        case .number(let literal):
            return indent + "<\(name)\(attributes) type=\"number\">\(literal)</\(name)>"
        case .bool(let flag):
            return indent + "<\(name)\(attributes) type=\"boolean\">\(flag)</\(name)>"
        case .null:
            return indent + "<\(name)\(attributes) type=\"null\"/>"
        }
    }

    /// XML 1.0 names, kept to ASCII-safe rules and never starting with "xml".
    static func isName(_ key: String) -> Bool {
        key.range(of: #"^[A-Za-z_][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil && !key.lowercased().hasPrefix("xml")
    }

    static func escape(_ text: String, attribute: Bool) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"" where attribute: out += "&quot;"
            case "\n" where attribute: out += "&#10;"
            case "\t" where attribute: out += "&#9;"
            case "\r": out += "&#13;"
            default:
                // Control characters can't appear in XML 1.0 at all, not even escaped.
                if scalar.value < 0x20 && scalar != "\n" && scalar != "\t" {
                    Fidelity.note(L("Control characters were left out: XML can’t hold them."))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    // MARK: Reading

    final class Node {
        let name: String
        var attributes: [(String, String)]
        var children: [Node] = []
        var text = ""
        var hasMixedText = false

        init(name: String, attributes: [(String, String)]) {
            self.name = name
            self.attributes = attributes
        }
    }

    /// Parses without external entities or DTD loading, with a depth limit.
    static func parse(_ data: Data) throws -> Node {
        let delegate = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else {
            let error = parser.parserError as NSError?
            throw Problem(L("The XML could not be read: %@ (line %@).", delegate.failure ?? reason(error), String(parser.lineNumber)),
                          suggestion: L("Check that the file is complete and is really XML."),
                          technical: error.map { "\($0.domain) \($0.code)" })
        }
        if delegate.droppedComments { Fidelity.note(L("Comments and processing instructions in the XML were left out: JSON has no place for them.")) }
        return root
    }

    /// The parser's error in plain words; its own text is only a code number.
    private static func reason(_ error: NSError?) -> String {
        switch error.flatMap({ XMLParser.ErrorCode(rawValue: $0.code) }) {
        case .prematureDocumentEndError?, .emptyDocumentError?: return L("the data ends too early")
        case .tagNameMismatchError?, .notWellBalancedError?, .ltSlashRequiredError?, .unfinishedTagError?:
            return L("an element is closed by a tag with another name")
        case .extraContentError?: return L("there is more text after the last element")
        case .entityRefLoopError?, .entityBoundaryError?, .parsedEntityRefInInternalSubsetError?:
            return L("it defines entities that refer to themselves or expand without limit")
        default: return L("it isn’t well-formed XML")
        }
    }

    /// The document's JSON. Files written by `document(_:)` come back exactly; any other XML
    /// keeps its root element's name as the single top-level key.
    static func json(document root: Node) -> JSONValue {
        root.name == "root" ? json(root) : .object([(root.name, json(root))])
    }

    static func json(_ node: Node) -> JSONValue {
        let isEntry = node.name == "entry" && node.attributes.contains { $0.0 == "key" }
        let typeValue = node.attributes.first { $0.0 == "type" }?.1
        let marksType = typeValue.map { ["number", "boolean", "null", "array", "object"].contains($0) } ?? false
        let ownAttributes = node.attributes.filter { !(isEntry && $0.0 == "key") }
        let trimmed = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if marksType, ownAttributes.count == 1, let typeValue {
            switch typeValue {
            case "number" where node.children.isEmpty && JSONConverter.isCanonicalNumber(trimmed): return .number(trimmed)
            case "boolean" where node.children.isEmpty && (trimmed == "true" || trimmed == "false"): return .bool(trimmed == "true")
            case "null" where node.children.isEmpty && trimmed.isEmpty: return .null
            case "array" where trimmed.isEmpty && node.children.allSatisfy({ $0.name == "item" }): return .array(node.children.map { json($0) })
            case "object" where node.children.isEmpty && trimmed.isEmpty: return .object([])
            default: break
            }
        }
        if node.children.isEmpty && ownAttributes.isEmpty { return .string(node.text) }
        var members: [(key: String, value: JSONValue)] = ownAttributes.map { ("@" + $0.0, .string($0.1)) }
        // Children with the same name become one array, at the place of the first one.
        var order: [String] = []
        var groups: [String: [JSONValue]] = [:]
        for child in node.children {
            let key = child.name == "entry" ? (child.attributes.first { $0.0 == "key" }?.1 ?? child.name) : child.name
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(json(child))
        }
        for key in order {
            let values = groups[key] ?? []
            members.append((key, values.count == 1 ? values[0] : .array(values)))
        }
        if !trimmed.isEmpty { members.append(("#text", .string(node.text))) }
        if node.hasMixedText { Fidelity.note(L("Text mixed between elements was joined into “#text”.")) }
        return .object(members)
    }

    private final class TreeBuilder: NSObject, XMLParserDelegate {
        var root: Node?
        var stack: [Node] = []
        var failure: String?
        var droppedComments = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            guard stack.count < JSONParser.maxDepth else {
                failure = L("the data is nested more than %@ levels deep", String(JSONParser.maxDepth))
                parser.abortParsing()
                return
            }
            // XMLParser hands attributes over unordered; sort them so the output is stable.
            let node = Node(name: name, attributes: attributes.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
            if let parent = stack.last {
                if !parent.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parent.hasMixedText = true }
                parent.children.append(node)
            } else {
                root = node
            }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard let node = stack.last else { return }
            if !node.children.isEmpty && !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { node.hasMixedText = true }
            node.text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if let node = stack.popLast(), !node.children.isEmpty, node.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                node.text = ""
            }
        }

        func parser(_ parser: XMLParser, foundComment comment: String) { droppedComments = true }
        func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) { droppedComments = true }
    }
}

// MARK: - Tables

/// Turns JSON into rows and columns without losing anything: every value gets a column
/// named by its path (`address.city`, `tags[0]`), so nested data survives in a flat table.
enum JSONTable {
    struct Table {
        var columns: [String]
        var rows: [[JSONValue?]]
    }

    static func make(_ value: JSONValue) -> Table {
        let records: [JSONValue]
        if case .array(let elements) = value { records = elements } else { records = [value] }
        var columns: [String] = []
        var known = Set<String>()
        var rows: [[String: JSONValue]] = []
        for record in records {
            var cells: [(String, JSONValue)] = []
            flatten(record, path: "", into: &cells)
            if cells.isEmpty { cells = [("value", record)] }
            var row: [String: JSONValue] = [:]
            for (path, leaf) in cells {
                let column = path.isEmpty ? "value" : path
                if known.insert(column).inserted { columns.append(column) }
                row[column] = leaf
            }
            rows.append(row)
        }
        return Table(columns: columns, rows: rows.map { row in columns.map { row[$0] } })
    }

    private static func flatten(_ value: JSONValue, path: String, into cells: inout [(String, JSONValue)]) {
        switch value {
        case .object(let members) where !members.isEmpty:
            for member in members {
                flatten(member.value, path: path.isEmpty ? member.key : path + "." + member.key, into: &cells)
            }
        case .array(let elements) where !elements.isEmpty:
            for (index, element) in elements.enumerated() {
                flatten(element, path: path + "[\(index)]", into: &cells)
            }
        default:
            // Leaves, and empty objects/arrays (kept as `{}`/`[]` so they don't vanish).
            cells.append((path, value))
        }
    }

    /// The text a cell shows. Numbers keep their literal; empty containers stay visible.
    static func text(_ value: JSONValue?) -> String {
        switch value {
        case .none, .some(.null): return ""
        case .some(.string(let text)): return text
        case .some(.number(let literal)): return literal
        case .some(.bool(let flag)): return flag ? "true" : "false"
        case .some(.object): return "{}"
        case .some(.array): return "[]"
        }
    }
}

// MARK: - Conversions

/// JSON → CSV, TSV, XLSX, HTML, XML and YAML; XML and tables (CSV, TSV, XLSX and what
/// Numbers/Excel read) → JSON.
enum JSONConverter: ConversionFamily {
    static let dataTargets: [Format] = [.csv, .tsv, .xlsx, .html, .xml, .yaml]

    static func targets(from source: Format) -> [Format] {
        if source == .json { return dataTargets }
        if source == .xml { return [.json] }
        if source.group == .spreadsheet, !SpreadsheetConverter.targets(from: source).isEmpty { return [.json] }
        return []
    }

    static func convert(_ url: URL, from source: Format, to target: Format) throws -> [URL] {
        if source == .json { return try fromJSON(url, to: target) }
        if source == .xml {
            let value = XMLBridge.json(document: try XMLBridge.parse(try Data(contentsOf: url)))
            let out = Output.url(for: url, ext: "json")
            try (JSONWriter.string(value) + "\n").write(to: out, atomically: true, encoding: .utf8)
            return [out]
        }
        return [try toJSON(url, from: source)]
    }

    static func read(_ url: URL) throws -> JSONValue {
        // JSON is UTF-8 by definition, but files saved by older Windows tools are not always.
        let data = TextDecoding.utf8(try Data(contentsOf: url)).data
        do {
            return try JSONParser.parse(data)
        } catch let failure as JSONParser.Failure {
            throw Problem(L("“%@” is not valid JSON: %@ (line %@, column %@).", url.lastPathComponent, failure.message,
                            String(failure.line), String(failure.column)),
                          suggestion: L("Open it in a text editor and fix that spot, or export it again from the app that created it."))
        }
    }

    private static func fromJSON(_ url: URL, to target: Format) throws -> [URL] {
        let value = try read(url)
        let out = Output.url(for: url, ext: target.ext)
        switch target {
        case .yaml:
            try YAMLWriter.document(value).write(to: out, atomically: true, encoding: .utf8)
        case .xml:
            try XMLBridge.document(value).write(to: out, atomically: true, encoding: .utf8)
        case .csv, .tsv, .xlsx, .html:
            let table = JSONTable.make(value)
            let header = table.columns
            let body = table.rows.map { $0.map(JSONTable.text) }
            if table.rows.contains(where: { $0.contains { if case .some(.null) = $0 { return true }; return false } }) {
                Fidelity.note(L("Empty cells stand for JSON null: tables have no separate value for it."))
            }
            switch target {
            case .csv, .tsv:
                // Values are written exactly as text, so a number like 1.50 keeps its trailing zero.
                try CSV.format([header] + body, delimiter: target == .csv ? "," : "\t").write(to: out, atomically: true, encoding: .utf8)
            case .xlsx:
                try XLSX.write([Sheet(name: Output.baseName(url), rows: [header] + body, literalText: literalCells(table))], to: out)
            default:
                try SpreadsheetConverter.html([Sheet(name: Output.baseName(url), rows: [header] + body)], title: Output.baseName(url))
                    .write(to: out, atomically: true, encoding: .utf8)
            }
        default:
            throw Problem(L("JSON converts to CSV, TSV, XLSX, HTML, XML or YAML."))
        }
        return [out]
    }

    /// Text cells from JSON stay text in Excel even when they look like numbers or dates ("007", "2024-01-01").
    private static func literalCells(_ table: JSONTable.Table) -> Set<SheetCell> {
        var cells = Set<SheetCell>()
        for (r, row) in table.rows.enumerated() {
            for (c, value) in row.enumerated() {
                if case .some(.string) = value { cells.insert(SheetCell(row: r + 1, column: c)) }
            }
        }
        return cells
    }

    private static func toJSON(_ url: URL, from source: Format) throws -> URL {
        let sheets = try SpreadsheetConverter.read(url, from: source).filter { !$0.rows.isEmpty }
        guard !sheets.isEmpty else { throw Problem(L("“%@” opened, but every sheet is empty.", url.lastPathComponent)) }
        let documents = sheets.map(records)
        let value: JSONValue = documents.count == 1 ? documents[0] : .object(zip(sheets, documents).map { ($0.name, $1) })
        if sheets.contains(where: { !$0.formulas.isEmpty }) {
            Fidelity.note(L("JSON keeps the results of formulas, not the formulas themselves."))
        }
        let out = Output.url(for: url, ext: "json")
        try (JSONWriter.string(value) + "\n").write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    /// One object per row, keyed by the header row. Text from CSV stays text unless it is
    /// plainly a number or true/false, so "007" or "1,5" are never changed.
    static func records(_ sheet: Sheet) -> JSONValue {
        guard let header = sheet.rows.first else { return .array([]) }
        var keys: [String] = []
        var seen: [String: Int] = [:]
        for (index, name) in header.enumerated() {
            var key = name.isEmpty ? XLSX.columnName(index) : name
            if let count = seen[key] {
                seen[key] = count + 1
                key += " (\(count + 1))"
            } else {
                seen[key] = 1
            }
            keys.append(key)
        }
        let width = max(keys.count, sheet.rows.map(\.count).max() ?? 0)
        while keys.count < width { keys.append(XLSX.columnName(keys.count)) }
        return .array(sheet.rows.dropFirst().map { row in
            .object(keys.enumerated().map { column, key in
                (key, column < row.count ? scalar(row[column]) : .string(""))
            })
        })
    }

    static func scalar(_ text: String) -> JSONValue {
        if text == "TRUE" || text == "true" { return .bool(true) }
        if text == "FALSE" || text == "false" { return .bool(false) }
        if isCanonicalNumber(text) { return .number(text) }
        return .string(text)
    }

    /// JSON's own number grammar, without leading zeros: "12", "-3.5", "1e9". Not "007", "1,5" or "+4".
    static func isCanonicalNumber(_ text: String) -> Bool {
        text.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil && text.count <= 30
    }
}
