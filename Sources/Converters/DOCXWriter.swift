import AppKit
import ImageIO

/// Writes rich text as a Word document with what the macOS exporter leaves out: pictures
/// and links. Character formatting, alignment and tables come along too; anything else
/// (lists, indents) keeps its text as the system laid it out.
enum DOCXWriter {
    /// A picture taken from the text, stored as word/media/imageN.ext.
    private struct Media {
        let id: String
        let name: String
        let data: Data
        let size: CGSize
    }

    private final class Builder {
        var relationships: [String] = []
        var media: [Media] = []
        var links: [String: String] = [:]
        var drawingID = 0

        func linkID(_ url: URL) -> String {
            if let id = links[url.absoluteString] { return id }
            let id = "rId\(relationships.count + 10)"
            relationships.append("<Relationship Id=\"\(id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(xml(url.absoluteString, attribute: true))\" TargetMode=\"External\"/>")
            links[url.absoluteString] = id
            return id
        }

        func add(_ attachment: NSTextAttachment) -> Media? {
            guard let picture = DOCXWriter.picture(attachment) else { return nil }
            let id = "rId\(relationships.count + 10)"
            let name = "image\(media.count + 1).\(picture.ext)"
            relationships.append("<Relationship Id=\"\(id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\(name)\"/>")
            let item = Media(id: id, name: name, data: picture.data, size: picture.size)
            media.append(item)
            return item
        }
    }

    static func write(_ text: NSAttributedString, to out: URL) throws {
        let builder = Builder()
        let body = paragraphs(text, builder: builder)
        let workspace = try Output.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fm = FileManager.default
        for folder in ["_rels", "word/_rels", "word/media", "docProps"] {
            try fm.createDirectory(at: workspace.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        let imageTypes = Set(builder.media.map { ($0.name as NSString).pathExtension })
            .map { "<Default Extension=\"\($0)\" ContentType=\"image/\($0 == "jpg" ? "jpeg" : $0)\"/>" }.joined()
        try (header + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>\(imageTypes)"
            + "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
            + "</Types>").write(to: workspace.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try (header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/>"
            + "</Relationships>").write(to: workspace.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
        try (header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + builder.relationships.joined() + "</Relationships>")
            .write(to: workspace.appendingPathComponent("word/_rels/document.xml.rels"), atomically: true, encoding: .utf8)
        for item in builder.media {
            try item.data.write(to: workspace.appendingPathComponent("word/media/\(item.name)"))
        }
        let document = header + """
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)\
        <w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1417" w:right="1417" w:bottom="1417" w:left="1417" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr>\
        </w:body></w:document>
        """
        try document.write(to: workspace.appendingPathComponent("word/document.xml"), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: workspace.appendingPathComponent("docProps"))

        let temp = Output.tempSibling(of: out)
        do {
            try runChecked("/usr/bin/zip", ["-X", "-r", "-q", temp.path, "[Content_Types].xml", "_rels", "word"], cwd: workspace,
                           what: L("Creating the DOCX"))
        } catch {
            Output.discard(temp)
            throw error
        }
        try Output.commit(temp, to: out)
    }

    // MARK: Body

    /// Paragraphs in order; runs of paragraphs inside the same table become a Word table.
    private static func paragraphs(_ text: NSAttributedString, builder: Builder) -> String {
        let string = text.string as NSString
        var xmlBody = ""
        var location = 0
        var tableCells: [(row: Int, column: Int, span: Int, xml: String)] = []
        var currentTable: NSTextTable?

        func flushTable() {
            guard let table = currentTable else { return }
            xmlBody += tableXML(tableCells, columns: table.numberOfColumns)
            tableCells = []
            currentTable = nil
        }

        while location < string.length {
            var end = 0
            var contentsEnd = 0
            string.getParagraphStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            let range = NSRange(location: location, length: contentsEnd - location)
            let style = text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
            let paragraph = paragraphXML(text, range: range, style: style, builder: builder)
            if let block = style?.textBlocks.last as? NSTextTableBlock {
                if currentTable !== block.table { flushTable(); currentTable = block.table }
                if let index = tableCells.firstIndex(where: { $0.row == block.startingRow && $0.column == block.startingColumn }) {
                    tableCells[index].xml += paragraph
                } else {
                    tableCells.append((block.startingRow, block.startingColumn, block.columnSpan, paragraph))
                }
            } else {
                flushTable()
                xmlBody += paragraph
            }
            location = max(end, location + 1)
        }
        flushTable()
        return xmlBody.isEmpty ? "<w:p/>" : xmlBody
    }

    private static func tableXML(_ cells: [(row: Int, column: Int, span: Int, xml: String)], columns: Int) -> String {
        let rows = (cells.map(\.row).max() ?? 0) + 1
        let border = "w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"999999\""
        var xml = "<w:tbl><w:tblPr><w:tblW w:w=\"0\" w:type=\"auto\"/><w:tblBorders><w:top \(border)/><w:left \(border)/><w:bottom \(border)/>"
            + "<w:right \(border)/><w:insideH \(border)/><w:insideV \(border)/></w:tblBorders></w:tblPr><w:tblGrid>"
            + String(repeating: "<w:gridCol/>", count: max(columns, 1)) + "</w:tblGrid>"
        for row in 0..<rows {
            xml += "<w:tr>"
            var column = 0
            while column < max(columns, 1) {
                if let cell = cells.first(where: { $0.row == row && $0.column == column }) {
                    let span = max(1, cell.span)
                    xml += "<w:tc><w:tcPr>\(span > 1 ? "<w:gridSpan w:val=\"\(span)\"/>" : "")</w:tcPr>\(cell.xml.isEmpty ? "<w:p/>" : cell.xml)</w:tc>"
                    column += span
                } else {
                    xml += "<w:tc><w:p/></w:tc>"
                    column += 1
                }
            }
            xml += "</w:tr>"
        }
        return xml + "</w:tbl>"
    }

    private static func paragraphXML(_ text: NSAttributedString, range: NSRange, style: NSParagraphStyle?, builder: Builder) -> String {
        var properties = ""
        switch style?.alignment {
        case .center: properties += "<w:jc w:val=\"center\"/>"
        case .right: properties += "<w:jc w:val=\"right\"/>"
        case .justified: properties += "<w:jc w:val=\"both\"/>"
        default: break
        }
        if let indent = style?.headIndent, indent > 0 { properties += "<w:ind w:left=\"\(Int(indent * 20))\"/>" }
        var xml = "<w:p>" + (properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>")
        var openLink: URL?
        text.enumerateAttributes(in: range) { attributes, runRange, _ in
            let link = (attributes[.link] as? URL) ?? (attributes[.link] as? String).flatMap(URL.init(string:))
            let external = link.flatMap { ["http", "https", "mailto"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
            if openLink != external {
                if openLink != nil { xml += "</w:hyperlink>" }
                if let external { xml += "<w:hyperlink r:id=\"\(builder.linkID(external))\">" }
                openLink = external
            }
            if let attachment = attributes[.attachment] as? NSTextAttachment {
                if let media = builder.add(attachment) {
                    builder.drawingID += 1
                    xml += drawingXML(media, id: builder.drawingID)
                }
                return
            }
            let content = (text.string as NSString).substring(with: runRange)
            xml += runXML(content, attributes: attributes, isLink: external != nil)
        }
        if openLink != nil { xml += "</w:hyperlink>" }
        return xml + "</w:p>"
    }

    private static func runXML(_ content: String, attributes: [NSAttributedString.Key: Any], isLink: Bool) -> String {
        var properties = ""
        if let font = attributes[.font] as? NSFont {
            let family = font.familyName.flatMap { $0.hasPrefix(".") ? nil : $0 } ?? "Helvetica"
            properties += "<w:rFonts w:ascii=\"\(xml(family, attribute: true))\" w:hAnsi=\"\(xml(family, attribute: true))\" w:cs=\"\(xml(family, attribute: true))\"/>"
            let traits = font.fontDescriptor.symbolicTraits
            if traits.contains(.bold) { properties += "<w:b/>" }
            if traits.contains(.italic) { properties += "<w:i/>" }
            properties += "<w:sz w:val=\"\(Int((font.pointSize * 2).rounded()))\"/>"
        }
        if let underline = attributes[.underlineStyle] as? Int, underline != 0 { properties += "<w:u w:val=\"single\"/>" }
        else if isLink { properties += "<w:u w:val=\"single\"/>" }
        if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 { properties += "<w:strike/>" }
        if let color = (attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB) {
            let hex = String(format: "%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
            if hex != "000000" { properties += "<w:color w:val=\"\(hex)\"/>" }
        } else if isLink {
            properties += "<w:color w:val=\"0563C1\"/>"
        }
        if let shift = attributes[.baselineOffset] as? CGFloat, shift != 0 {
            properties += "<w:vertAlign w:val=\"\(shift > 0 ? "superscript" : "subscript")\"/>"
        }
        let rPr = properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>"
        // Tabs and line breaks are elements of their own in Word.
        var xmlRun = ""
        var buffer = ""
        func flush() {
            if !buffer.isEmpty { xmlRun += "<w:r>\(rPr)<w:t xml:space=\"preserve\">\(xml(buffer, attribute: false))</w:t></w:r>"; buffer = "" }
        }
        for character in content {
            switch character {
            case "\t": flush(); xmlRun += "<w:r>\(rPr)<w:tab/></w:r>"
            case "\u{2028}", "\u{0B}": flush(); xmlRun += "<w:r>\(rPr)<w:br/></w:r>"
            case "\u{0C}": flush(); xmlRun += "<w:r><w:br w:type=\"page\"/></w:r>"
            default: buffer.append(character)
            }
        }
        flush()
        return xmlRun
    }

    private static func drawingXML(_ media: Media, id: Int) -> String {
        // Inline pictures at their size in the text, never wider than the A4 text column.
        let maxWidth: CGFloat = 453
        let scale = media.size.width > maxWidth ? maxWidth / media.size.width : 1
        let cx = Int(media.size.width * scale * 12700)
        let cy = Int(media.size.height * scale * 12700)
        return "<w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\"><wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/>"
            + "<wp:docPr id=\"\(id)\" name=\"Picture \(id)\"/><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\">"
            + "<pic:pic><pic:nvPicPr><pic:cNvPr id=\"\(id)\" name=\"\(media.name)\"/><pic:cNvPicPr/></pic:nvPicPr>"
            + "<pic:blipFill><a:blip r:embed=\"\(media.id)\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
            + "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr>"
            + "</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>"
    }

    // MARK: Pictures

    /// The attachment's picture as PNG, JPEG or GIF (what Word reads everywhere), with its size in points.
    static func picture(_ attachment: NSTextAttachment) -> (data: Data, ext: String, size: CGSize)? {
        var data = attachment.fileWrapper?.regularFileContents
        if data == nil, let image = attachment.image, let tiff = image.tiffRepresentation { data = tiff }
        guard let raw = data, let source = CGImageSourceCreateWithData(raw as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let pixels = CGSize(width: properties[kCGImagePropertyPixelWidth] as? Int ?? 0, height: properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
        let dpi = properties[kCGImagePropertyDPIWidth] as? Double ?? 72
        var size = attachment.bounds.size
        if size.width <= 0 || size.height <= 0 { size = CGSize(width: pixels.width * 72 / dpi, height: pixels.height * 72 / dpi) }
        let type = CGImageSourceGetType(source) as String? ?? ""
        switch type {
        case "public.png": return (raw, "png", size)
        case "public.jpeg": return (raw, "jpeg", size)
        case "com.compuserve.gif": return (raw, "gif", size)
        default:
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            let png = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            return CGImageDestinationFinalize(destination) ? (png as Data, "png", size) : nil
        }
    }

    static func count(_ text: NSAttributedString) -> (pictures: Int, links: Int) {
        var pictures = 0
        var links = 0
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in if value != nil { pictures += 1 } }
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in if value != nil { links += 1 } }
        return (pictures, links)
    }

    static func xml(_ text: String, attribute: Bool) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"" where attribute: out += "&quot;"
            default:
                if scalar.value >= 0x20 || scalar == "\n" || scalar == "\t" { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }
}
