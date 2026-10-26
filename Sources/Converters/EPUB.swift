import Foundation
import ImageIO

enum EPUBReader {
    /// Unzips the book and joins its spine chapters into one HTML file whose image
    /// references are absolute, so NSAttributedString can load it.
    static func combinedHTML(_ epub: URL) throws -> (html: URL, workspace: URL) {
        let workspace = try Output.scratchDirectory()
        do {
            try runChecked("/usr/bin/ditto", ["-x", "-k", epub.path, workspace.path], what: L("Opening the EPUB"))
            let container = try XMLDocument(contentsOf: workspace.appendingPathComponent("META-INF/container.xml"), options: [.nodeLoadExternalEntitiesNever])
            guard let rootPath = try container.nodes(forXPath: "//*[local-name()='rootfile']/@full-path").first?.stringValue else {
                throw Problem(L("The EPUB is malformed: the file that lists its contents (container.xml/OPF) is missing."), suggestion: L("Open it in Books or Calibre to check whether it is damaged."))
            }
            let opfURL = workspace.appendingPathComponent(rootPath)
            let package = try XMLDocument(contentsOf: opfURL, options: [.nodeLoadExternalEntitiesNever])
            var manifest: [String: String] = [:]
            for item in try package.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']") {
                guard let element = item as? XMLElement,
                      let id = element.attribute(forName: "id")?.stringValue,
                      let href = element.attribute(forName: "href")?.stringValue else { continue }
                manifest[id] = href.removingPercentEncoding ?? href
            }
            let title = try package.nodes(forXPath: "//*[local-name()='title']").first?.stringValue ?? "EPUB"
            var bodies: [String] = []
            for ref in try package.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']/@idref") {
                guard let id = ref.stringValue, let href = manifest[id] else { continue }
                let chapterURL = opfURL.deletingLastPathComponent().appendingPathComponent(href)
                guard let body = chapterBody(chapterURL) else { continue }
                bodies.append(body)
            }
            guard !bodies.isEmpty else { throw Problem(L("The EPUB has no text chapters (it may be only pictures or have DRM)."), suggestion: L("Books bought with DRM can’t be converted.")) }
            let html = """
            <!DOCTYPE html><html><head><meta charset="utf-8"><title>\(Markdown.escape(title))</title></head>
            <body>\(bodies.joined(separator: "\n<hr>\n"))</body></html>
            """
            let file = workspace.appendingPathComponent("combined.html")
            try html.write(to: file, atomically: true, encoding: .utf8)
            return (file, workspace)
        } catch {
            try? FileManager.default.removeItem(at: workspace)
            throw error
        }
    }

    static func chapterBody(_ url: URL) -> String? {
        let document = (try? XMLDocument(contentsOf: url, options: [.nodeLoadExternalEntitiesNever]))
            ?? (try? XMLDocument(contentsOf: url, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]))
        guard let document, let body = try? document.nodes(forXPath: "//*[local-name()='body']").first as? XMLElement else {
            return nil
        }
        let base = url.deletingLastPathComponent()
        for node in (try? body.nodes(forXPath: ".//*[local-name()='img']")) ?? [] {
            guard let img = node as? XMLElement, let src = img.attribute(forName: "src")?.stringValue,
                  !src.hasPrefix("data:") else { continue }
            img.addAttribute(XMLNode.attribute(withName: "src", stringValue: base.appendingPathComponent(src.removingPercentEncoding ?? src).absoluteString) as! XMLNode)
        }
        return body.children?.map { $0.xmlString }.joined() ?? ""
    }
}

enum EPUBWriter {
    /// Builds an EPUB 3 (with EPUB 2 NCX) from HTML; chapters split at each <h1>. Pictures that
    /// are inside the page (data:) or are local files next to it (`base`) are packed into the book.
    static func write(html: String, title: String, base: URL? = nil, to out: URL) throws {
        // Tidy only honours the http-equiv form of the charset declaration; without it
        // UTF-8 text is read as Latin-1.
        let declared = "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\">"
        let source: String
        if let head = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            source = html.replacingCharacters(in: head, with: html[head] + declared)
        } else {
            source = "<html><head>\(declared)</head><body>\(html)</body></html>"
        }
        guard let data = source.data(using: .utf8),
              let document = try? XMLDocument(data: data, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]) else {
            throw Problem(L("The document’s content isn’t valid HTML for an EPUB."), suggestion: L("Convert it to DOCX or HTML first and try again."))
        }
        let styles = ((try? document.nodes(forXPath: "//*[local-name()='style']")) ?? []).compactMap { $0.stringValue }.joined(separator: "\n")
        var pictures: [(name: String, data: Data, type: String)] = []
        for case let image as XMLElement in (try? document.nodes(forXPath: "//*[local-name()='img']")) ?? [] {
            guard let src = image.attribute(forName: "src")?.stringValue, let picture = packedPicture(src, base: base) else {
                // A picture that can't be packed would be a broken link in the book.
                image.detach()
                continue
            }
            let name = "images/picture-\(pictures.count + 1).\(picture.ext)"
            pictures.append((name, picture.data, picture.type))
            image.attribute(forName: "src")?.stringValue = name
        }
        guard let body = (try? document.nodes(forXPath: "//*[local-name()='body']"))?.first as? XMLElement else {
            throw Problem(L("The document has no text to put in the EPUB."))
        }
        var chapters: [(title: String, xhtml: String)] = []
        var current: [String] = []
        var currentTitle = title
        for child in body.children ?? [] {
            if child.kind == .element, child.name?.lowercased() == "h1", !current.isEmpty {
                chapters.append((currentTitle, current.joined()))
                current = []
            }
            if child.kind == .element, child.name?.lowercased() == "h1" {
                currentTitle = child.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? title
            }
            current.append(child.xmlString)
        }
        if !current.isEmpty || chapters.isEmpty { chapters.append((currentTitle, current.joined())) }

        let workspace = try Output.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let oebps = workspace.appendingPathComponent("OEBPS")
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: oebps.appendingPathComponent("images"), withIntermediateDirectories: true)
        for picture in pictures { try picture.data.write(to: oebps.appendingPathComponent(picture.name)) }

        try "application/epub+zip".write(to: workspace.appendingPathComponent("mimetype"), atomically: true, encoding: .ascii)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.write(to: workspace.appendingPathComponent("META-INF/container.xml"), atomically: true, encoding: .utf8)

        let css = "body{font-family:serif;line-height:1.5}img{max-width:100%}table{border-collapse:collapse}td,th{border:1px solid #999;padding:.3em}\n" + styles
        try css.write(to: oebps.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)

        let escapedTitle = Markdown.escape(title)
        let language = Localizer.shared.language.resolved.rawValue
        for (index, chapter) in chapters.enumerated() {
            try """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(language)">
            <head><meta charset="utf-8"/><title>\(Markdown.escape(chapter.title))</title><link rel="stylesheet" href="style.css"/></head>
            <body>\(chapter.xhtml)</body></html>
            """.write(to: oebps.appendingPathComponent("chapter-\(index + 1).xhtml"), atomically: true, encoding: .utf8)
        }
        let navItems = chapters.enumerated().map { "<li><a href=\"chapter-\($0.offset + 1).xhtml\">\(Markdown.escape($0.element.title))</a></li>" }.joined()
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(language)">
        <head><meta charset="utf-8"/><title>\(escapedTitle)</title></head>
        <body><nav epub:type="toc" id="toc"><h1>\(Markdown.escape(L("Contents")))</h1><ol>\(navItems)</ol></nav></body></html>
        """.write(to: oebps.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)

        let identifier = "urn:uuid:\(UUID().uuidString.lowercased())"
        let navPoints = chapters.enumerated().map {
            "<navPoint id=\"np\($0.offset + 1)\" playOrder=\"\($0.offset + 1)\"><navLabel><text>\(Markdown.escape($0.element.title))</text></navLabel><content src=\"chapter-\($0.offset + 1).xhtml\"/></navPoint>"
        }.joined()
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
        <head><meta name="dtb:uid" content="\(identifier)"/></head>
        <docTitle><text>\(escapedTitle)</text></docTitle><navMap>\(navPoints)</navMap></ncx>
        """.write(to: oebps.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)

        let modified = ISO8601DateFormatter().string(from: Date()).prefix(19) + "Z"
        let manifest = chapters.indices.map { "<item id=\"c\($0 + 1)\" href=\"chapter-\($0 + 1).xhtml\" media-type=\"application/xhtml+xml\"/>" }.joined()
            + pictures.enumerated().map { "<item id=\"p\($0.offset + 1)\" href=\"\($0.element.name)\" media-type=\"\($0.element.type)\"/>" }.joined()
        let spine = chapters.indices.map { "<itemref idref=\"c\($0 + 1)\"/>" }.joined()
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid" xml:lang="\(language)">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">\(identifier)</dc:identifier>
            <dc:title>\(escapedTitle)</dc:title>
            <dc:language>\(language)</dc:language>
            <meta property="dcterms:modified">\(modified)</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="css" href="style.css" media-type="text/css"/>
            \(manifest)
          </manifest>
          <spine toc="ncx">\(spine)</spine>
        </package>
        """.write(to: oebps.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        // The mimetype entry must be first and stored uncompressed.
        let temp = Output.tempSibling(of: out)
        do {
            try runChecked("/usr/bin/zip", ["-X0", "-q", temp.path, "mimetype"], cwd: workspace, what: L("Creating the EPUB"))
            try runChecked("/usr/bin/zip", ["-X9", "-r", "-q", temp.path, "META-INF", "OEBPS"], cwd: workspace, what: L("Creating the EPUB"))
        } catch {
            Output.discard(temp)
            throw error
        }
        try Output.commit(temp, to: out)
    }

    /// A picture for the book: embedded (data:) or a local file. Never anything remote.
    static func packedPicture(_ src: String, base: URL?) -> (data: Data, ext: String, type: String)? {
        var data: Data?
        if src.hasPrefix("data:"), let comma = src.firstIndex(of: ","), src[..<comma].hasSuffix(";base64") {
            data = Data(base64Encoded: String(src[src.index(after: comma)...]))
        } else if !LocalOnly.isRemote(src), let base {
            let path = src.removingPercentEncoding ?? src
            let file = path.hasPrefix("file://") ? URL(string: src) : URL(fileURLWithPath: path, relativeTo: base)
            if let file, file.isFileURL { data = try? Data(contentsOf: file.standardizedFileURL) }
        }
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        switch CGImageSourceGetType(source) as String? {
        case "public.png": return (data, "png", "image/png")
        case "public.jpeg": return (data, "jpg", "image/jpeg")
        case "com.compuserve.gif": return (data, "gif", "image/gif")
        case "public.svg-image": return (data, "svg", "image/svg+xml")
        default:
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            let png = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            return CGImageDestinationFinalize(destination) ? (png as Data, "png", "image/png") : nil
        }
    }
}
