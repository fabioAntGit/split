import AppKit

/// A cell position: row and column from 0, as in `Sheet.rows`.
struct SheetCell: Hashable {
    let row: Int
    let column: Int
}

struct Sheet {
    var name: String
    var rows: [[String]]
    /// European CSVs (";" separated) write decimals as "1234,56".
    var decimalComma = false
    /// Cells written as text even when they look like numbers or dates (e.g. "007" from JSON).
    var literalText: Set<SheetCell> = []
    /// Formulas read from a workbook; `rows` holds their last computed values.
    /// An empty formula marks a cell that shares another cell's formula.
    var formulas: [SheetCell: String] = [:]
}

enum SpreadsheetConverter: ConversionFamily {
    static let tableTargets: [Format] = [.xlsx, .csv, .tsv, .html, .pdf]

    static func targets(from source: Format) -> [Format] {
        guard source.group == .spreadsheet else { return [] }
        switch source {
        case .csv, .tsv, .xlsx: return tableTargets
        case .numbers: return Engines.numbers ? tableTargets : []
        default: return Engines.numbers || Engines.excel || Engines.soffice != nil ? tableTargets : []
        }
    }

    static func convert(_ url: URL, from source: Format, to target: Format) throws -> [URL] {
        let officeFidelity = Settings.useOfficeApps && Engines.excel && [.xlsx, .xls, .ods].contains(source)
        if target == .pdf && ([.xls, .numbers, .ods].contains(source) || officeFidelity) {
            return [try OfficeBridge.spreadsheetToPDF(url, from: source)]
        }
        if target == .xlsx && [.xls, .ods, .numbers].contains(source) {
            // The app that reads the workbook writes the XLSX itself: formulas, formatting,
            // merged cells and charts stay, instead of going through a table of values.
            let out = Output.url(for: url, ext: "xlsx")
            let dir = try Output.scratchDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let exported = try OfficeBridge.spreadsheetToXLSX(url, from: source, into: dir)
            try FileManager.default.moveItem(at: exported, to: out)
            return [out]
        }
        let sheets = try read(url, from: source)
        guard sheets.contains(where: { !$0.rows.isEmpty }) else { throw Problem(L("“%@” opened, but every sheet is empty.", url.lastPathComponent)) }
        reportLosses(sheets, from: source, to: target)
        switch target {
        case .csv, .tsv:
            let delimiter: Character = target == .csv ? "," : "\t"
            let filled = sheets.filter { !$0.rows.isEmpty }
            var outputs: [URL] = []
            for sheet in filled {
                let suffix = filled.count > 1 ? " - \(sheet.name)" : ""
                let out = Output.url(for: url, ext: target.ext, suffix: suffix)
                try CSV.format(sheet.rows, delimiter: delimiter).write(to: out, atomically: true, encoding: .utf8)
                outputs.append(out)
            }
            return outputs
        case .xlsx:
            let out = Output.url(for: url, ext: "xlsx")
            try XLSX.write(sheets, to: out)
            return [out]
        case .html:
            let out = Output.url(for: url, ext: "html")
            try html(sheets, title: Output.baseName(url)).write(to: out, atomically: true, encoding: .utf8)
            return [out]
        case .pdf:
            let out = Output.url(for: url, ext: "pdf")
            let attributed = try DocumentPipeline.fromHTML(html(sheets, title: Output.baseName(url)), baseURL: url.deletingLastPathComponent())
            let wide = sheets.contains { ($0.rows.map(\.count).max() ?? 0) > 6 }
            let temp = Output.tempSibling(of: out)
            do { try PDFRender.write(attributed, to: temp, landscape: wide) } catch { Output.discard(temp); throw error }
            try Output.commit(temp, to: out)
            return [out]
        default:
            throw Problem(L("Spreadsheets only convert to XLSX, CSV, TSV, HTML or PDF."))
        }
    }

    /// Tables of values can't hold formulas or a workbook's look; say so when the source had them.
    static func reportLosses(_ sheets: [Sheet], from source: Format, to target: Format) {
        let formulas = sheets.reduce(0) { $0 + $1.formulas.count }
        if formulas > 0 && target != .xlsx {
            Fidelity.note(L("%@ keeps the results of the %@ formulas, not the formulas themselves. XLSX keeps them.", target.label, String(formulas)))
        }
        if (target == .csv || target == .tsv) && sheets.filter({ !$0.rows.isEmpty }).count > 1 {
            Fidelity.note(L("%@ holds one sheet per file, so each sheet became its own file.", target.label))
        }
    }

    static func read(_ url: URL, from source: Format) throws -> [Sheet] {
        switch source {
        case .csv:
            let text = try DocumentPipeline.readText(url)
            let delimiter = CSV.guessDelimiter(text)
            return [Sheet(name: Output.baseName(url), rows: CSV.parse(text, delimiter: delimiter), decimalComma: delimiter == ";")]
        case .tsv:
            return [Sheet(name: Output.baseName(url), rows: CSV.parse(try DocumentPipeline.readText(url), delimiter: "\t"))]
        case .xlsx:
            return try XLSX.read(url)
        default:
            let dir = try Output.scratchDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            return try XLSX.read(try OfficeBridge.spreadsheetToXLSX(url, from: source, into: dir))
        }
    }

    static func html(_ sheets: [Sheet], title: String) -> String {
        var body = ""
        for sheet in sheets where !sheet.rows.isEmpty {
            if sheets.count > 1 { body += "<h2>\(Markdown.escape(sheet.name))</h2>" }
            let width = sheet.rows.map(\.count).max() ?? 0
            body += "<table>"
            for (index, row) in sheet.rows.enumerated() {
                let tag = index == 0 ? "th" : "td"
                let padded = row + Array(repeating: "", count: width - row.count)
                body += "<tr>" + padded.map { "<\(tag)>\(Markdown.escape($0))</\(tag)>" }.joined() + "</tr>"
            }
            body += "</table>"
        }
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>\(Markdown.escape(title))</title>
        <style>body{font:10pt Helvetica,Arial,sans-serif}table{border-collapse:collapse;margin-bottom:1.5em}
        td,th{border:1px solid #999;padding:3px 6px;vertical-align:top}th{background:#eee;text-align:left}</style>
        </head><body>\(body)</body></html>
        """
    }
}

// MARK: - CSV

enum CSV {
    /// European Excel exports use ";" — pick whichever separator dominates the first line.
    static func guessDelimiter(_ text: String) -> Character {
        let headerLine = text.prefix { $0 != "\n" }
        let semicolons = headerLine.filter { $0 == ";" }.count
        let commas = headerLine.filter { $0 == "," }.count
        let tabs = headerLine.filter { $0 == "\t" }.count
        if tabs > commas && tabs > semicolons { return "\t" }
        return semicolons > commas ? ";" : ","
    }

    static func parse(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character? = nil
        while let char = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if char == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(char)
                }
            } else if char == "\"" && field.isEmpty {
                inQuotes = true
            } else if char == delimiter {
                row.append(field)
                field = ""
            } else if char == "\n" || char == "\r\n" || char == "\r" {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else {
                field.append(char)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    static func format(_ rows: [[String]], delimiter: Character) -> String {
        rows.map { row in
            row.map { value in
                if value.contains(delimiter) || value.contains("\"") || value.contains("\n") || value.contains("\r") {
                    return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return value
            }.joined(separator: String(delimiter))
        }.joined(separator: "\n") + "\n"
    }
}

// MARK: - XLSX reader/writer (values, dates, percentages, formulas, header style, column widths)

enum XLSX {
    static func entry(_ archive: URL, _ path: String) throws -> Data? {
        let result = try runProcess("/usr/bin/unzip", ["-p", archive.path, path])
        return result.status == 0 && !result.stdoutData.isEmpty ? result.stdoutData : nil
    }

    static func read(_ url: URL) throws -> [Sheet] {
        guard let workbookData = try entry(url, "xl/workbook.xml") else {
            throw Problem(L("“%@” isn’t a valid XLSX.", url.lastPathComponent),
                                  suggestion: FileCheck.mismatch(url) ?? L("It lacks the internal structure of an Excel workbook. It may be damaged or password-protected."))
        }
        let shared = try entry(url, "xl/sharedStrings.xml").map(SharedStringsParser.parse) ?? []
        let relationships = try entry(url, "xl/_rels/workbook.xml.rels").map(RelationshipParser.parse) ?? [:]
        let styles = try entry(url, "xl/styles.xml").map(StylesParser.parse) ?? []
        let workbook = WorkbookParser.parse(workbookData)
        var sheets: [Sheet] = []
        for (index, sheet) in workbook.sheets.enumerated() {
            var target = relationships[sheet.relationship] ?? "worksheets/sheet\(index + 1).xml"
            if target.hasPrefix("/") { target.removeFirst() } else { target = "xl/" + target }
            guard let data = try entry(url, target) else { continue }
            let parsed = SheetParser.parse(data, shared: shared, styles: styles, date1904: workbook.date1904)
            sheets.append(Sheet(name: sheet.name, rows: parsed.rows, formulas: parsed.formulas))
        }
        return sheets
    }

    // MARK: Number formats

    enum CellKind { case general, date, dateTime, time, percent }

    /// Built-in format ids from ECMA-376 §18.8.30 plus custom codes.
    static func kind(numFmtID: Int, code: String?) -> CellKind {
        switch numFmtID {
        case 14, 15, 16, 17: return .date
        case 18, 19, 20, 21, 45, 46, 47: return .time
        case 22: return .dateTime
        case 9, 10: return .percent
        default: break
        }
        guard let code else { return .general }
        // Ignore quoted text, escapes and [colour]/[locale] blocks before looking for date tokens.
        let cleaned = code.replacingOccurrences(of: "\"[^\"]*\"", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\\\.", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
            .lowercased()
        if cleaned.contains("%") { return .percent }
        let hasDate = cleaned.contains("y") || cleaned.contains("d") || (cleaned.contains("m") && !cleaned.contains("h"))
        let hasTime = cleaned.contains("h") || cleaned.contains("s")
        if hasDate && hasTime { return .dateTime }
        if hasDate { return .date }
        if hasTime { return .time }
        return .general
    }

    static func date(fromSerial serial: Double, date1904: Bool) -> Date {
        var components = DateComponents()
        components.year = date1904 ? 1904 : 1899
        components.month = date1904 ? 1 : 12
        components.day = date1904 ? 1 : 30
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let epoch = calendar.date(from: components)!
        return epoch.addingTimeInterval((serial * 86_400).rounded())
    }

    static func serial(from date: Date) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let epoch = calendar.date(from: DateComponents(year: 1899, month: 12, day: 30))!
        return date.timeIntervalSince(epoch) / 86_400
    }

    private static func formatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = pattern
        return formatter
    }

    static let isoDate = formatter("yyyy-MM-dd")
    static let isoDateTime = formatter("yyyy-MM-dd HH:mm")
    static let isoTime = formatter("HH:mm:ss")

    /// Cell text as it should appear in CSV/HTML: ISO dates, percentages with "%".
    static func display(_ value: String, kind: CellKind, date1904: Bool) -> String {
        guard kind != .general, let number = Double(value) else { return value }
        switch kind {
        case .date: return isoDate.string(from: date(fromSerial: number, date1904: date1904))
        case .dateTime: return isoDateTime.string(from: date(fromSerial: number, date1904: date1904))
        case .time: return isoTime.string(from: date(fromSerial: number.truncatingRemainder(dividingBy: 1), date1904: false))
        case .percent:
            let percent = number * 100
            let text = percent == percent.rounded() ? String(Int(percent)) : String(format: "%.2f", percent)
                .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            return text + "%"
        case .general: return value
        }
    }

    // MARK: Writing helpers

    static func columnName(_ index: Int) -> String {
        var n = index + 1
        var name = ""
        while n > 0 {
            let remainder = (n - 1) % 26
            name = String(UnicodeScalar(65 + remainder)!) + name
            n = (n - 1) / 26
        }
        return name
    }

    static func columnIndex(_ reference: String) -> Int {
        var index = 0
        for char in reference.uppercased() {
            guard let ascii = char.asciiValue, ascii >= 65, ascii <= 90 else { break }
            index = index * 26 + Int(ascii - 64)
        }
        return max(0, index - 1)
    }

    static func xmlEscape(_ text: String) -> String {
        Markdown.escape(text).filter { char in
            // Strip control characters that are illegal in XML 1.0.
            char.unicodeScalars.allSatisfy { $0.value >= 0x20 || $0 == "\t" || $0 == "\n" || $0 == "\r" }
        }
    }

    static func isNumber(_ value: String) -> Bool {
        guard !value.isEmpty, value.count < 16, Double(value) != nil else { return false }
        if value.hasPrefix("0") && value.count > 1 && !value.hasPrefix("0.") { return false }
        return value.allSatisfy { "0123456789.-+eE".contains($0) }
    }

    /// Style ids in the stylesheet written below.
    enum Style: Int { case normal = 0, header = 1, date = 2, dateTime = 3, percent = 4 }

    /// How a CSV cell is stored: number, date serial, percentage, formula or text.
    enum Cell: Equatable {
        case number(String, Style)
        case formula(String)
        case text(String)
    }

    static func cell(_ value: String, decimalComma: Bool) -> Cell {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.count > 1 && trimmed.hasPrefix("=") { return .formula(String(trimmed.dropFirst())) }
        if isNumber(trimmed) { return .number(trimmed, .normal) }
        if decimalComma, trimmed.range(of: "^-?[0-9]+,[0-9]+$", options: .regularExpression) != nil {
            return .number(trimmed.replacingOccurrences(of: ",", with: "."), .normal)
        }
        if trimmed.hasSuffix("%") {
            let body = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            if let number = Double(body), isNumber(body) { return .number(String(number / 100), .percent) }
        }
        if let date = parseDate(trimmed) {
            let style: Style = trimmed.contains(":") ? .dateTime : .date
            return .number(String(serial(from: date)), style)
        }
        return .text(value)
    }

    /// ISO (2024-03-31, 2024-03-31 14:05) and Portuguese day-first dates (31/03/2024).
    static func parseDate(_ text: String) -> Date? {
        guard text.count >= 8, text.count <= 19, text.first?.isNumber == true else { return nil }
        let patterns = ["yyyy-MM-dd", "yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "dd/MM/yyyy", "dd-MM-yyyy", "dd/MM/yyyy HH:mm"]
        for pattern in patterns where pattern.count == text.count || (pattern.contains("'T'") && pattern.count - 2 == text.count) {
            let parser = formatter(pattern)
            parser.isLenient = false
            if let date = parser.date(from: text), parser.string(from: date) == text { return date }
        }
        return nil
    }

    static func write(_ sheets: [Sheet], to out: URL) throws {
        let workspace = try Output.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fm = FileManager.default
        for dir in ["_rels", "xl/_rels", "xl/worksheets"] {
            try fm.createDirectory(at: workspace.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        var usedNames = Set<String>()
        var sheetEntries = ""
        var relationships = ""
        var overrides = ""
        for (index, sheet) in sheets.enumerated() {
            var name = String(sheet.name.filter { !"[]:*?/\\".contains($0) }.prefix(31))
            if name.isEmpty || usedNames.contains(name) { name = "Folha\(index + 1)" }
            usedNames.insert(name)
            sheetEntries += "<sheet name=\"\(xmlEscape(name))\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
            relationships += "<Relationship Id=\"rId\(index + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(index + 1).xml\"/>"
            overrides += "<Override PartName=\"/xl/worksheets/sheet\(index + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
            try worksheetXML(sheet).write(to: workspace.appendingPathComponent("xl/worksheets/sheet\(index + 1).xml"), atomically: true, encoding: .utf8)
        }
        let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        try (header + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>\(overrides)</Types>")
            .write(to: workspace.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try (header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>")
            .write(to: workspace.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
        // fullCalcOnLoad: formulas written from CSV have no cached value, so Excel/Numbers compute them on open.
        try (header + "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>\(sheetEntries)</sheets><calcPr calcId=\"191029\" fullCalcOnLoad=\"1\"/></workbook>")
            .write(to: workspace.appendingPathComponent("xl/workbook.xml"), atomically: true, encoding: .utf8)
        let stylesID = sheets.count + 1
        try (header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(relationships)<Relationship Id=\"rId\(stylesID)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>")
            .write(to: workspace.appendingPathComponent("xl/_rels/workbook.xml.rels"), atomically: true, encoding: .utf8)
        try (header + stylesheet).write(to: workspace.appendingPathComponent("xl/styles.xml"), atomically: true, encoding: .utf8)

        let temp = Output.tempSibling(of: out)
        do {
            try runChecked("/usr/bin/zip", ["-X", "-r", "-q", temp.path, "[Content_Types].xml", "_rels", "xl"], cwd: workspace, what: L("Creating the XLSX"))
        } catch {
            Output.discard(temp)
            throw error
        }
        try Output.commit(temp, to: out)
    }

    static let stylesheet = """
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
    <numFmts count="2"><numFmt numFmtId="164" formatCode="yyyy\\-mm\\-dd"/><numFmt numFmtId="165" formatCode="yyyy\\-mm\\-dd\\ hh:mm"/></numFmts>\
    <fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>\
    <fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>\
    <fill><patternFill patternType="solid"><fgColor rgb="FFF2F2F2"/><bgColor indexed="64"/></patternFill></fill></fills>\
    <borders count="2"><border><left/><right/><top/><bottom/><diagonal/></border>\
    <border><left/><right/><top/><bottom style="thin"><color rgb="FFBFBFBF"/></bottom><diagonal/></border></borders>\
    <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
    <cellXfs count="5"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
    <xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1"/>\
    <xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>\
    <xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>\
    <xf numFmtId="10" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs>\
    <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
    """

    /// A first row of text over rows with numbers or dates reads as a header.
    static func hasHeader(_ rows: [[String]], decimalComma: Bool) -> Bool {
        guard rows.count > 1, let first = rows.first, first.contains(where: { !$0.isEmpty }) else { return false }
        return first.allSatisfy { value in
            if case .text = cell(value, decimalComma: decimalComma) { return true }
            return value.isEmpty
        }
    }

    static func worksheetXML(_ sheet: Sheet) -> String {
        let header = hasHeader(sheet.rows, decimalComma: sheet.decimalComma)
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
        if header {
            xml += "<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews>"
        }
        let columns = sheet.rows.map(\.count).max() ?? 0
        if columns > 0 {
            xml += "<cols>"
            for column in 0..<columns {
                let longest = sheet.rows.prefix(500).map { $0.count > column ? $0[column].count : 0 }.max() ?? 0
                let width = min(60, max(8, Double(longest) * 1.1 + 2))
                xml += "<col min=\"\(column + 1)\" max=\"\(column + 1)\" width=\"\(String(format: "%.1f", width))\" customWidth=\"1\"/>"
            }
            xml += "</cols>"
        }
        xml += "<sheetData>"
        for (r, row) in sheet.rows.enumerated() {
            xml += "<row r=\"\(r + 1)\">"
            for (c, value) in row.enumerated() where !value.isEmpty {
                let ref = columnName(c) + String(r + 1)
                if (header && r == 0) || sheet.literalText.contains(SheetCell(row: r, column: c)) {
                    let style = header && r == 0 ? " s=\"\(Style.header.rawValue)\"" : ""
                    xml += "<c r=\"\(ref)\"\(style) t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlEscape(value))</t></is></c>"
                    continue
                }
                switch cell(value, decimalComma: sheet.decimalComma) {
                case .number(let number, let style):
                    xml += "<c r=\"\(ref)\"\(style == .normal ? "" : " s=\"\(style.rawValue)\"")><v>\(number)</v></c>"
                case .formula(let formula):
                    xml += "<c r=\"\(ref)\"><f>\(xmlEscape(formula))</f></c>"
                case .text(let text):
                    xml += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlEscape(text))</t></is></c>"
                }
            }
            xml += "</row>"
        }
        xml += "</sheetData></worksheet>"
        return xml
    }
}

// MARK: XML parsers

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    var strings: [String] = []
    var current = ""
    var inText = false
    var inPhonetic = false

    static func parse(_ data: Data) -> [String] {
        let delegate = SharedStringsParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.strings
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "si": current = ""
        case "t": inText = !inPhonetic
        case "rPh": inPhonetic = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "si": strings.append(current)
        case "t": inText = false
        case "rPh": inPhonetic = false
        default: break
        }
    }
}

private final class WorkbookParser: NSObject, XMLParserDelegate {
    var sheets: [(name: String, relationship: String)] = []
    var date1904 = false

    static func parse(_ data: Data) -> WorkbookParser {
        let delegate = WorkbookParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "workbookPr" {
            date1904 = ["1", "true"].contains(attributes["date1904"] ?? "")
        }
        guard name == "sheet" else { return }
        let relationship = attributes.first { $0.key == "r:id" || $0.key.hasSuffix(":id") }?.value ?? ""
        sheets.append((attributes["name"] ?? "Folha\(sheets.count + 1)", relationship))
    }
}

private final class RelationshipParser: NSObject, XMLParserDelegate {
    var targets: [String: String] = [:]

    static func parse(_ data: Data) -> [String: String] {
        let delegate = RelationshipParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.targets
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "Relationship", let id = attributes["Id"], let target = attributes["Target"] { targets[id] = target }
    }
}

/// Reads cellXfs → number format kind, so date serials can be shown as dates.
final class StylesParser: NSObject, XMLParserDelegate {
    var customFormats: [Int: String] = [:]
    var kinds: [XLSX.CellKind] = []
    var inCellXfs = false

    static func parse(_ data: Data) -> [XLSX.CellKind] {
        let delegate = StylesParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.kinds
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "numFmt":
            if let id = Int(attributes["numFmtId"] ?? ""), let code = attributes["formatCode"] { customFormats[id] = code }
        case "cellXfs":
            inCellXfs = true
        case "xf" where inCellXfs:
            let id = Int(attributes["numFmtId"] ?? "") ?? 0
            kinds.append(XLSX.kind(numFmtID: id, code: customFormats[id]))
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "cellXfs" { inCellXfs = false }
    }
}

private final class SheetParser: NSObject, XMLParserDelegate {
    let shared: [String]
    let styles: [XLSX.CellKind]
    let date1904: Bool
    var rows: [[String]] = []
    var row: [String] = []
    var column = 0
    var cellType = ""
    var cellStyle = 0
    var value = ""
    var collecting = false
    var formula: String?
    var collectingFormula = false
    var formulas: [SheetCell: String] = [:]

    init(shared: [String], styles: [XLSX.CellKind], date1904: Bool) {
        self.shared = shared
        self.styles = styles
        self.date1904 = date1904
    }

    static func parse(_ data: Data, shared: [String], styles: [XLSX.CellKind], date1904: Bool) -> (rows: [[String]], formulas: [SheetCell: String]) {
        let delegate = SheetParser(shared: shared, styles: styles, date1904: date1904)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        while let last = delegate.rows.last, last.allSatisfy({ $0.isEmpty }) { delegate.rows.removeLast() }
        return (delegate.rows, delegate.formulas)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "row":
            let target = (Int(attributes["r"] ?? "") ?? rows.count + 1) - 1
            while rows.count < target { rows.append([]) }
            row = []
        case "c":
            cellType = attributes["t"] ?? ""
            cellStyle = Int(attributes["s"] ?? "") ?? 0
            column = attributes["r"].map(XLSX.columnIndex) ?? row.count
            value = ""
            formula = nil
        case "f":
            formula = ""
            collectingFormula = true
        case "v", "t":
            collecting = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collectingFormula { formula? += string } else if collecting { value += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "v", "t":
            collecting = false
        case "f":
            collectingFormula = false
        case "c":
            if let formula { formulas[SheetCell(row: rows.count, column: column)] = formula }
            var text = value
            switch cellType {
            case "s": text = Int(value).flatMap { $0 < shared.count ? shared[$0] : nil } ?? ""
            case "b": text = value == "1" ? "TRUE" : "FALSE"
            case "", "n":
                let kind = cellStyle < styles.count ? styles[cellStyle] : .general
                text = XLSX.display(value, kind: kind, date1904: date1904)
            default: break
            }
            while row.count < column { row.append("") }
            if row.count == column { row.append(text) } else { row[column] = text }
        case "row":
            rows.append(row)
        default:
            break
        }
    }
}
