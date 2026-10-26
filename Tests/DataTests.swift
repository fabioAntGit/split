import AppKit

/// JSON, XML and YAML: nothing a format can hold may be lost on the way, and hostile files
/// must fail with an explanation instead of hanging or reading what they shouldn't.
func registerDataTests() {
    func parse(_ text: String) throws -> JSONValue { try JSONParser.parse(Data(text.utf8)) }

    test("Data", "The JSON reader keeps key order, exact numbers and every kind of text") {
        let value = try parse(#"{"z": 1, "a": [1.50, -0, 1e400, 12345678901234567890], "s": "tab\t \"q\" é 🍊", "n": null, "t": true}"#)
        guard case .object(let pairs) = value else { throw TestFailure("not an object") }
        check(pairs.map(\.key) == ["z", "a", "s", "n", "t"], "key order: \(pairs.map(\.key))")
        check(pairs[1].value == .array([.number("1.50"), .number("-0"), .number("1e400"), .number("12345678901234567890")]),
              "numbers keep their exact text: \(pairs[1].value)")
        check(pairs[2].value == .string("tab\t \"q\" é 🍊"), "escapes and surrogate pairs: \(pairs[2].value)")
        let written = JSONWriter.string(value)
        check(try parse(written) == value, "writing and reading back gives the same value")
        check(written.contains("12345678901234567890") && written.contains("1.50"), "big and padded numbers are written as they were")
        check(try parse("\u{FEFF}[1]") == .array([.number("1")]), "a byte-order mark is skipped")
    }

    test("Data", "Broken JSON is explained with its line and column") {
        for (text, fragment) in [("{\"a\": 1,\n  \"b\" 2}", "line 2"), ("[1, 2", "ends too early"), ("{\"a\": tru}", "unexpected"), ("[1] x", "more text")] {
            do {
                _ = try parse(text)
                check(false, "“\(text)” should fail")
            } catch let failure as JSONParser.Failure {
                check("\(failure.message) line \(failure.line)".contains(fragment), "“\(text)”: \(failure.message), line \(failure.line), column \(failure.column)")
            }
        }
        let deep = String(repeating: "[", count: JSONParser.maxDepth + 10) + String(repeating: "]", count: JSONParser.maxDepth + 10)
        check((try? parse(deep)) == nil, "nesting deeper than \(JSONParser.maxDepth) is refused instead of overflowing the stack")
        let file = try Hostile.file("broken.json", in: "json", "{\"name\": \"Split\",\n \"oops\"}")
        expectError("broken JSON file", contains: ["not valid JSON", "line 2"]) { _ = try Conversions.convert(file, to: .csv) }
    }

    test("Data", "JSON → XML → JSON comes back exactly, keys that aren’t XML names included") {
        let value = try parse(#"{"name": "Split", "1st": "x", "a b": [1, "2", null, true, {"deep": []}], "empty": {}, "amp": "<&>", "pi": 3.14}"#)
        let xml = XMLBridge.document(value)
        check(XMLParser(data: Data(xml.utf8)).parse(), "valid XML: \(xml.prefix(200))")
        let back = XMLBridge.json(document: try XMLBridge.parse(Data(xml.utf8)))
        check(back == value, "round trip:\n\(JSONWriter.string(back))")
        let folder = try Hostile.folder("json-xml")
        let source = folder.appendingPathComponent("data.json")
        try JSONWriter.string(value).write(to: source, atomically: true, encoding: .utf8)
        let converted = try Conversions.convert(source, to: .xml)[0]
        let again = try Conversions.convert(converted, to: .json)[0]
        check(try JSONConverter.read(again) == value, "through files as well")
    }

    test("Data", "Any XML becomes JSON with its attributes, text and repeated elements") {
        let (value, notes) = try Fidelity.collect {
            XMLBridge.json(document: try XMLBridge.parse(Data("""
            <?xml version="1.0"?><!-- a comment --><catalog lang="en"><book id="1">Intro <b>bold</b> end</book><book id="2"/></catalog>
            """.utf8)))
        }
        let text = JSONWriter.string(value)
        check(text.contains("\"catalog\"") && text.contains("\"@lang\"") && text.contains("\"@id\""), "attributes become @keys: \(text)")
        check(text.contains("\"book\": ["), "repeated elements become an array: \(text)")
        check(text.contains("#text"), "mixed text is kept as #text")
        check(notes.contains { $0.contains("Comments") } && notes.contains { $0.contains("#text") }, "what JSON can’t hold is said: \(notes)")
    }

    test("Data", "Hostile XML: external entities, billion laughs and deep nesting") {
        let wire = "<?xml version=\"1.0\"?><!DOCTYPE r [<!ENTITY x SYSTEM \"file:///etc/passwd\">]><r>a&x;b</r>"
        let parsed = try? XMLBridge.parse(Data(wire.utf8))
        check(parsed.map { !JSONWriter.string(XMLBridge.json(document: $0)).contains("root:") } ?? true, "an external entity is never read")
        var entities = "<!ENTITY l0 \"ha\">"
        for level in 1...9 { entities += "<!ENTITY l\(level) \"" + String(repeating: "&l\(level - 1);", count: 10) + "\">" }
        let laughs = "<?xml version=\"1.0\"?><!DOCTYPE r [\(entities)]><r>&l9;</r>"
        let started = Date()
        let result = try? XMLBridge.parse(Data(laughs.utf8))
        check(Date().timeIntervalSince(started) < 10, "billion laughs took \(Date().timeIntervalSince(started)) s")
        check(result.map { JSONWriter.string(XMLBridge.json(document: $0)).count < 10_000_000 } ?? true, "the entities weren’t expanded without limit")
        let deep = String(repeating: "<a>", count: 3000) + String(repeating: "</a>", count: 3000)
        check((try? XMLBridge.parse(Data(deep.utf8))) == nil, "very deep XML is refused")
        expectError("XML that isn’t XML", contains: ["could not be read", "line"]) { _ = try XMLBridge.parse(Data("<a><b></a>".utf8)) }
    }

    test("Data", "YAML: ambiguous text is quoted so it reads back as text") {
        let value = try parse(#"{"plain": "hello", "yes": "yes", "no": "No", "null": "null", "num": "1.0", "colon": "a: b", "dash": "- x", "lead": " x", "multi": "a\nb", "real": 1.0, "list": [], "map": {}}"#)
        let yaml = YAMLWriter.document(value)
        check(yaml.contains("plain: hello"), "plain text stays plain: \(yaml)")
        for quoted in ["\"yes\"", "\"No\"", "\"null\"", "\"1.0\"", "\"a: b\"", "\"- x\"", "\" x\""] {
            check(yaml.contains(quoted), "\(quoted) should be quoted:\n\(yaml)")
        }
        check(yaml.contains("real: 1.0") && yaml.contains("list: []") && yaml.contains("map: {}"), "numbers and empty containers:\n\(yaml)")
    }

    test("Data", "JSON ↔ tables: nested keys become columns, text stays text") {
        let value = try parse(#"[{"id": "007", "user": {"name": "Ana"}, "tags": ["a", "b"]}, {"id": 8, "extra": null}]"#)
        let table = JSONTable.make(value)
        check(table.columns == ["id", "user.name", "tags[0]", "tags[1]", "extra"], "columns: \(table.columns)")
        let folder = try Hostile.folder("json-table")
        let source = folder.appendingPathComponent("users.json")
        try JSONWriter.string(value).write(to: source, atomically: true, encoding: .utf8)
        let (outputs, notes) = try Fidelity.collect { try Conversions.convert(source, to: .xlsx) }
        let sheet = String(decoding: try XLSX.entry(outputs[0], "xl/worksheets/sheet1.xml") ?? Data(), as: UTF8.self)
        check(sheet.contains("007"), "“007” is kept as text, not turned into 7")
        check(notes.contains { $0.contains("null") }, "null becoming an empty cell is said: \(notes)")
        let csv = try Conversions.convert(source, to: .csv)[0]
        check(Files.text(csv).hasPrefix("id,user.name,tags[0],tags[1],extra"), "CSV header: \(Files.text(csv).prefix(60))")
        let back = try Conversions.convert(try Fixtures.isolated("people.tsv", in: "json-table"), to: .json)
        check(Files.text(back[0]).contains("\"Name\": \"Ana\"") && Files.text(back[0]).contains("\"Age\": 31"), "TSV → JSON records: \(Files.text(back[0]).prefix(80))")
    }

    test("Data", "Spreadsheet formulas: JSON keeps the values and says so") {
        let dates = try Fixtures.isolated("dates.xlsx", in: "json-formulas")
        let (outputs, notes) = try Fidelity.collect { try Conversions.convert(dates, to: .json) }
        check(Files.text(outputs[0]).contains("\"Sum\": 2"), "the cached value of 1+1: \(Files.text(outputs[0]).prefix(120))")
        check(notes.contains { $0.contains("formulas") }, "the lost formulas are said: \(notes)")
    }
}
