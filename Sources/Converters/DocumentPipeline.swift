import AppKit
import PDFKit
import Vision

// Documents go through NSAttributedString (Cocoa reads/writes docx, doc, odt, rtf,
// rtfd, html). macOS already reads and writes most office text formats, so the
// app only adds EPUB and Markdown, and leaves .pages to Pages.app.
enum DocumentPipeline: ConversionFamily {
    static let textTargets: [Format] = [.pdf, .docx, .odt, .rtf, .txt, .html, .epub]

    static func targets(from source: Format) -> [Format] {
        guard source.group == .document else { return [] }
        switch source {
        case .pdf: return [.png, .jpg, .txt, .docx, .rtf, .html, .epub]
        case .pages: return Engines.pages ? [.pdf, .docx, .epub, .txt, .rtf] : []
        default: return textTargets + (Engines.pages ? [.pages] : [])
        }
    }

    static func convert(_ url: URL, from source: Format, to target: Format) throws -> [URL] {
        if source == .pages || target == .pages {
            return try OfficeBridge.pages(url, from: source, to: target)
        }
        if source == .pdf && (target == .png || target == .jpg) {
            return try PDFTools.renderPages(url, as: target)
        }
        // Word keeps the real layout (headers, columns, tables); the Cocoa path below is the fallback.
        if target == .pdf && [.docx, .doc, .odt, .rtf].contains(source) && OfficeBridge.canUseWord {
            do {
                return [try OfficeBridge.wordToPDF(url)]
            } catch {
                NSLog("[Split] Word export failed, using the built-in converter: \(error.localizedDescription)")
            }
        }
        let out = Output.url(for: url, ext: target.ext)
        let title = Output.baseName(url)
        switch target {
        case .epub:
            try EPUBWriter.write(html: try html(for: url, from: source, target: target), title: title, base: url.deletingLastPathComponent(), to: out)
        case .html where source == .md:
            try Markdown.document(try readText(url), title: title).write(to: out, atomically: true, encoding: .utf8)
        default:
            let attributed = try load(url, from: source)
            reportLosses(url, from: source, to: target, loaded: attributed)
            try save(attributed, as: target, to: out)
        }
        return [out]
    }

    // MARK: Fidelity

    /// Pictures the source file holds, counted in the file itself (not in what macOS read).
    static func pictureCount(_ url: URL, format: Format) -> Int {
        switch format {
        case .docx, .odt:
            let folder = format == .docx ? "word/media/" : "Pictures/"
            guard let listing = try? runProcess("/usr/bin/unzip", ["-Z1", url.path]), listing.status == 0 else { return 0 }
            return listing.stdout.split(separator: "\n").filter { $0.hasPrefix(folder) && !$0.hasSuffix("/") }.count
        case .rtf:
            return ((try? readText(url)) ?? "").components(separatedBy: "{\\pict").count - 1
        case .html:
            let text = (try? readText(url)) ?? ""
            let images = (try? NSRegularExpression(pattern: #"<img\b[^>]*\bsrc\s*=\s*["']?(?!https?:|//)"#, options: .caseInsensitive))?
                .numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) ?? 0
            return images
        case .md:
            return ((try? readText(url)) ?? "").components(separatedBy: "![").count - 1
        default:
            return 0
        }
    }

    /// Says which pictures or links didn't make it, and which formats would have kept them.
    static func reportLosses(_ url: URL, from source: Format, to target: Format, loaded: NSAttributedString) {
        let found = DOCXWriter.count(loaded)
        let expected = pictureCount(url, format: source)
        if expected > found.pictures {
            Fidelity.note(L("macOS couldn’t read %@ of the pictures in the document, so they were left out. Turn on “Use Word, Excel and PowerPoint” in Settings (or install LibreOffice) to keep them.",
                            String(expected - found.pictures)))
        }
        if source == .pdf && target != .pdf {
            Fidelity.note(L("From a PDF only the text comes across; pictures and page layout stay in the PDF."))
        }
        guard found.pictures > 0 else { return }
        switch target {
        case .odt, .rtf:
            Fidelity.note(L("%@ written by macOS can’t hold pictures, so %@ were left out. DOCX, RTFD, HTML, EPUB or PDF keep them.", target.label, String(found.pictures)))
        case .txt:
            Fidelity.note(L("TXT holds only text, so %@ pictures were left out.", String(found.pictures)))
        default:
            break
        }
    }

    /// Cocoa's HTML export points pictures at files it never writes; put each picture inside the page.
    static func embedPictures(_ html: String, from text: NSAttributedString) -> String {
        var pictures: [String] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            guard let attachment = value as? NSTextAttachment, let picture = DOCXWriter.picture(attachment) else { return }
            pictures.append("data:image/\(picture.ext);base64," + picture.data.base64EncodedString())
        }
        guard !pictures.isEmpty, let regex = try? NSRegularExpression(pattern: #"(<img\b[^>]*?\bsrc\s*=\s*")([^"]*)(")"#, options: .caseInsensitive) else {
            return html
        }
        let source = html as NSString
        var result = ""
        var last = 0
        var index = 0
        for match in regex.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            let src = source.substring(with: match.range(at: 2))
            result += source.substring(with: NSRange(location: last, length: match.range(at: 2).location - last))
            if index < pictures.count && !src.hasPrefix("data:") {
                result += pictures[index]
            } else {
                result += src
            }
            index += 1
            last = match.range(at: 2).location + match.range(at: 2).length
        }
        return result + source.substring(from: last)
    }

    // MARK: Reading

    /// Any text file as a string, whatever encoding it was saved in (see `TextDecoding`).
    static func readText(_ url: URL) throws -> String {
        TextDecoding.decode(try Data(contentsOf: url)).text
    }

    static func load(_ url: URL, from source: Format) throws -> NSAttributedString {
        switch source {
        case .txt:
            let font = NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12)
            return NSAttributedString(string: try readText(url), attributes: [.font: font])
        case .md:
            return try fromHTML(Markdown.document(try readText(url), title: Output.baseName(url)), baseURL: url.deletingLastPathComponent())
        case .html:
            return try fromHTML(try readText(url), baseURL: url.deletingLastPathComponent())
        case .epub:
            let book = try EPUBReader.combinedHTML(url)
            defer { try? FileManager.default.removeItem(at: book.workspace) }
            let html = LocalOnly.html(try readText(book.html), base: book.html.deletingLastPathComponent())
            try html.write(to: book.html, atomically: true, encoding: .utf8)
            return try onMain {
                try NSAttributedString(url: book.html, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                 .characterEncoding: String.Encoding.utf8.rawValue],
                                       documentAttributes: nil)
            }
        case .pdf:
            return try PDFTools.attributedText(url)
        default:
            // Word saves "web pages" as .doc, and Cocoa would sniff them and import them as HTML,
            // remote images and all. HTML goes through the local-only path; everything else is
            // read with its declared type so nothing is ever auto-detected as a web page.
            if FileCheck.sniff(url) == "HTML" {
                return try fromHTML(try readText(url), baseURL: url.deletingLastPathComponent())
            }
            let types: [Format: NSAttributedString.DocumentType] = [.doc: .docFormat, .docx: .officeOpenXML, .odt: .openDocument,
                                                                    .rtf: .rtf, .rtfd: .rtfd]
            let options: [NSAttributedString.DocumentReadingOptionKey: Any] = types[source].map { [.documentType: $0] } ?? [:]
            return try onMain { try NSAttributedString(url: url, options: options, documentAttributes: nil) }
        }
    }

    static func fromHTML(_ html: String, baseURL: URL) throws -> NSAttributedString {
        // Write next to the source's resources so relative image paths resolve.
        let dir = try Output.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("document.html")
        var based = LocalOnly.html(html, base: baseURL)
        if based.range(of: "<head>", options: .caseInsensitive) != nil {
            based = based.replacingOccurrences(of: "<head>", with: "<head><base href=\"\(baseURL.absoluteString)\">", options: .caseInsensitive)
        } else {
            based = "<head><base href=\"\(baseURL.absoluteString)\"></head>" + based
        }
        try based.write(to: file, atomically: true, encoding: .utf8)
        return try onMain {
            try NSAttributedString(url: file, options: [.documentType: NSAttributedString.DocumentType.html,
                                                        .characterEncoding: String.Encoding.utf8.rawValue],
                                   documentAttributes: nil)
        }
    }

    /// HTML used to build EPUBs; Markdown and HTML keep their own structure (and their local pictures).
    static func html(for url: URL, from source: Format, target: Format = .epub) throws -> String {
        switch source {
        case .md: return Markdown.document(try readText(url), title: Output.baseName(url))
        case .html: return LocalOnly.html(try readText(url), base: url.deletingLastPathComponent())
        default:
            let attributed = try load(url, from: source)
            reportLosses(url, from: source, to: target, loaded: attributed)
            let data = try onMain {
                try attributed.data(from: NSRange(location: 0, length: attributed.length),
                                    documentAttributes: [.documentType: NSAttributedString.DocumentType.html,
                                                         .characterEncoding: String.Encoding.utf8.rawValue])
            }
            return embedPictures(String(decoding: data, as: UTF8.self), from: attributed)
        }
    }

    // MARK: Writing

    /// Private system font names (".SFNS-…") can't be resolved by Word or other apps.
    static func portableFonts(_ attributed: NSAttributedString) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: attributed)
        copy.enumerateAttribute(.font, in: NSRange(location: 0, length: copy.length)) { value, range, _ in
            guard let font = value as? NSFont, font.fontName.hasPrefix(".") else { return }
            let traits = font.fontDescriptor.symbolicTraits
            let name: String
            switch (traits.contains(.bold), traits.contains(.italic)) {
            case (true, true): name = "Helvetica-BoldOblique"
            case (true, false): name = "Helvetica-Bold"
            case (false, true): name = "Helvetica-Oblique"
            default: name = "Helvetica"
            }
            if let replacement = NSFont(name: name, size: font.pointSize) { copy.addAttribute(.font, value: replacement, range: range) }
        }
        return copy
    }

    static func save(_ attributed: NSAttributedString, as target: Format, to out: URL) throws {
        let attributed = portableFonts(attributed)
        let temp = Output.tempSibling(of: out)
        let range = NSRange(location: 0, length: attributed.length)
        do {
            switch target {
            case .pdf:
                try PDFRender.write(attributed, to: temp)
            case .txt:
                // Attachment placeholders (U+FFFC) mean nothing in plain text.
                try attributed.string.replacingOccurrences(of: "\u{FFFC}", with: "").write(to: temp, atomically: true, encoding: .utf8)
            case .docx:
                // The system exporter drops pictures and links from DOCX; this writer keeps them.
                try DOCXWriter.write(attributed, to: temp)
            case .rtfd:
                let wrapper = try onMain {
                    try attributed.fileWrapper(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
                }
                try wrapper.write(to: temp, options: .atomic, originalContentsURL: nil)
            default:
                let types: [Format: NSAttributedString.DocumentType] = [
                    .docx: .officeOpenXML, .doc: .docFormat, .odt: .openDocument, .rtf: .rtf, .html: .html,
                ]
                guard let type = types[target] else {
                    throw Problem(L("The macOS text converter can’t save %@.", target.label), suggestion: L("Choose DOCX, RTF or PDF."))
                }
                var attributes: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
                if target == .html { attributes[.characterEncoding] = String.Encoding.utf8.rawValue }
                let data = try onMain { try attributed.data(from: range, documentAttributes: attributes) }
                if target == .html {
                    try embedPictures(String(decoding: data, as: UTF8.self), from: attributed).write(to: temp, atomically: true, encoding: .utf8)
                } else {
                    try data.write(to: temp)
                }
            }
        } catch {
            Output.discard(temp)
            throw error
        }
        try Output.commit(temp, to: out)
    }
}

// MARK: - PDF output (paginated A4 print of the attributed text)

enum PDFRender {
    static func write(_ attributed: NSAttributedString, to url: URL, landscape: Bool = false) throws {
        let ok = onMain { () -> Bool in
            let info = NSPrintInfo(dictionary: [
                .jobDisposition: NSPrintInfo.JobDisposition.save,
                .jobSavingURL: url,
            ])
            info.paperSize = landscape ? NSSize(width: 841.8, height: 595.2) : NSSize(width: 595.2, height: 841.8)
            info.orientation = landscape ? .landscape : .portrait
            info.topMargin = 56
            info.bottomMargin = 56
            info.leftMargin = 56
            info.rightMargin = 56
            info.horizontalPagination = .fit
            info.verticalPagination = .automatic
            info.isHorizontallyCentered = false
            info.isVerticallyCentered = false

            let width = info.paperSize.width - info.leftMargin - info.rightMargin
            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
            textView.appearance = NSAppearance(named: .aqua)
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            textView.textStorage?.setAttributedString(printable(attributed))
            if let container = textView.textContainer { textView.layoutManager?.ensureLayout(for: container) }
            textView.sizeToFit()

            let operation = NSPrintOperation(view: textView, printInfo: info)
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            return operation.run()
        }
        guard ok, let document = PDFDocument(url: url), document.pageCount > 0 else {
            throw Problem(L("The macOS printing system couldn’t create the PDF."),
                                  suggestion: L("Check that there is disk space and that the folder can be written to. If the document is very large, split it."))
        }
    }

    /// Text without an explicit colour would print white when the Mac is in dark mode.
    static func printable(_ attributed: NSAttributedString) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: DocumentPipeline.portableFonts(attributed))
        let full = NSRange(location: 0, length: copy.length)
        copy.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            if value == nil { copy.addAttribute(.foregroundColor, value: NSColor.black, range: range) }
        }
        copy.enumerateAttribute(.font, in: full) { value, range, _ in
            if value == nil { copy.addAttribute(.font, value: NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12), range: range) }
        }
        return copy
    }
}

// MARK: - PDF helpers

enum PDFTools {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            if FileCheck.sniff(url) != "PDF" {
                throw Problem(L("“%@” isn’t a valid PDF.", url.lastPathComponent),
                                      suggestion: FileCheck.mismatch(url) ?? L("The content doesn’t start like a PDF: the file is damaged or incomplete."))
            }
            if let document = PDFDocument(url: url), document.isLocked {
                throw Problem(L("The PDF “%@” is password-protected.", url.lastPathComponent),
                                      suggestion: L("Open it in Preview with the password and export an unprotected copy (File › Export as PDF)."))
            }
            throw Problem(L("The PDF “%@” is damaged or has no pages.", url.lastPathComponent),
                                  suggestion: L("Open it in Preview to check. If it opens, use File › Export as PDF to repair it."))
        }
        if document.isLocked {
            throw Problem(L("The PDF “%@” is password-protected.", url.lastPathComponent),
                                  suggestion: L("Open it in Preview with the password and export an unprotected copy (File › Export as PDF)."))
        }
        return document
    }

    static func attributedText(_ url: URL) throws -> NSAttributedString {
        let document = try open(url)
        let result = NSMutableAttributedString()
        var foundText = false
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            if index > 0 { result.append(NSAttributedString(string: "\n\u{000C}")) }
            if let text = page.attributedString, text.string.trimmingCharacters(in: .whitespacesAndNewlines).count > 0 {
                result.append(text)
                foundText = true
            } else if let text = try? recognizeText(page), !text.isEmpty {
                // Scanned page: no text layer, so read it with Vision OCR.
                result.append(NSAttributedString(string: text, attributes: [.font: NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12)]))
                foundText = true
            }
        }
        guard foundText else {
            throw Problem(L("“%@” has no text: neither selectable text nor text that can be recognized in its pictures (OCR).", url.lastPathComponent),
                                  suggestion: L("If the pages are photos, convert to PNG or JPG instead of text."))
        }
        return DocumentPipeline.portableFonts(result)
    }

    static func pageImage(_ page: PDFPage, scale: CGFloat = 2) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let size = CGSize(width: (rotated ? bounds.height : bounds.width) * scale,
                          height: (rotated ? bounds.width : bounds.height) * scale)
        guard size.width >= 1, size.height >= 1, let context = ImageConverter.bitmapContext(size) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    static func recognizeText(_ page: PDFPage) throws -> String {
        guard let image = pageImage(page, scale: 2.5) else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func renderPages(_ url: URL, as format: Format) throws -> [URL] {
        let document = try open(url)
        if document.pageCount == 1, let page = document.page(at: 0), let image = pageImage(page) {
            let out = Output.url(for: url, ext: format.ext)
            try ImageConverter.write(image, metadata: nil, to: out, as: format)
            return [out]
        }
        let folder = Output.folder(for: url, suffix: " (\(format.label))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let digits = String(document.pageCount).count
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let image = pageImage(page) else {
                throw Problem(L("Page %@ of “%@” couldn’t be drawn.", index + 1, url.lastPathComponent),
                                      suggestion: L("The page may be damaged or huge. Open the PDF in Preview to check."))
            }
            let number = String(format: "%0\(digits)d", index + 1)
            let out = folder.appendingPathComponent(L("Page %@", number) + "." + format.ext)
            try ImageConverter.write(image, metadata: nil, to: out, as: format)
        }
        return [folder]
    }
}

// MARK: - Local-only content

/// macOS imports HTML (and Markdown, EPUB, Word "web pages") with WebKit, which fetches remote
/// images, styles and fonts from a separate system service: neither a URLProtocol, a CSP nor a
/// sandbox on this process stops it (the tests prove each). So the document itself is cleaned
/// before WebKit sees it: any attribute or CSS value that points elsewhere is dropped, after
/// decoding entities and escapes so `&#104;ttp:` can't hide a scheme; local stylesheets are
/// inlined after the same cleaning, since they could import remote ones. Plain links (<a href>)
/// stay: they don't load anything.
enum LocalOnly {
    /// Attributes whose value the HTML loader fetches (href only outside <a>/<area>).
    private static let fetched: Set<String> = [
        "src", "srcset", "href", "background", "poster", "data", "xlink:href", "lowsrc", "dynsrc", "imagesrcset",
        "codebase", "archive", "longdesc", "icon", "manifest", "action", "formaction", "ping", "profile", "usemap",
        "attributionsrc", "itemtype",
    ]

    /// Elements that only load or run things, removed outright; our own <base> is added later.
    private static let elementRules: [String] = [
        "<script\\b[^>]*>[\\s\\S]*?</script\\s*>",
        "<script\\b[^>]*/?>",
        "</?(iframe|frame|frameset|object|embed|applet|video|audio|source|track|portal|base)\\b[^>]*>",
        "<meta\\b[^>]*http-equiv\\s*=\\s*[\"']?\\s*refresh[^>]*>",
    ]

    private static let tag = try! NSRegularExpression(pattern: "<([a-zA-Z][^\\s/>]*)((?:[^>\"']|\"[^\"]*\"|'[^']*')*)>")
    private static let attribute = try! NSRegularExpression(pattern: "([^\\s\"'>/=]+)(?:\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s\"'>]+))?")
    private static let styleBlock = try! NSRegularExpression(pattern: "(<style\\b[^>]*>)([\\s\\S]*?)(</style\\s*>)", options: .caseInsensitive)
    private static let cssReference = try! NSRegularExpression(pattern: "url\\(\\s*([\"']?)([^)]*?)\\1\\s*\\)|\"([^\"]*)\"|'([^']*)'", options: .caseInsensitive)

    /// `base` is the document's folder: local stylesheets there are inlined (cleaned), others dropped.
    static func html(_ text: String, base: URL? = nil) -> String {
        var result = text
        for pattern in elementRules {
            result = result.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        result = replace(styleBlock, in: result) { match, text in
            group(match, 1, text) + css(group(match, 2, text), base: base) + group(match, 3, text)
        }
        return replace(tag, in: result) { match, text in cleanTag(match, in: text, base: base) }
    }

    /// SVG is XML with the same loading attributes (<image href>, <use href>, <style>).
    static func svg(_ text: String) -> String { html(text) }

    /// True when a URL (already decoded) would be fetched from somewhere other than this Mac.
    static func isRemote(_ value: String) -> Bool {
        // Browsers ignore tabs, newlines and controls inside URLs ("ht\ttp:"), so do we.
        let compact = String(value.unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7F }).lowercased()
        if compact.hasPrefix("//") || compact.hasPrefix("\\\\") { return true }
        guard let colon = compact.firstIndex(of: ":") else { return false }
        let scheme = compact[..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) }) else { return false }
        return !["file", "data", "cid", "about"].contains(String(scheme))
    }

    /// For attributes that are only text (alt, title, data-*): an absolute address inside them.
    private static func mentionsRemote(_ value: String) -> Bool {
        value.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "(" || $0 == "'" || $0 == "\"" }).contains { token in
            token.hasPrefix("//") || (token.contains("://") && isRemote(String(token)))
        }
    }

    private static func cleanTag(_ match: NSTextCheckingResult, in text: String, base: URL?) -> String {
        let original = group(match, 0, text)
        let name = group(match, 1, text)
        let region = group(match, 2, text)
        let lower = name.lowercased()
        if lower == "link" { return inlineStylesheet(region, base: base) }
        let isLink = lower == "a" || lower == "area"
        var kept: [String] = []
        var changed = false
        let range = NSRange(region.startIndex..., in: region)
        for item in attribute.matches(in: region, range: range) {
            let raw = group(item, 0, region)
            let key = group(item, 1, region).lowercased()
            var value = group(item, 2, region)
            if value.hasPrefix("\"") || value.hasPrefix("'") { value = String(value.dropFirst().dropLast()) }
            let decoded = decodeEntities(value)
            if key.hasPrefix("on") {
                changed = true
                continue
            }
            if key == "style" {
                let clean = css(decoded, base: nil)
                if clean != decoded {
                    kept.append("style=\"\(clean.replacingOccurrences(of: "\"", with: "&quot;"))\"")
                    changed = true
                    continue
                }
            } else if fetched.contains(key) && !(isLink && key == "href") {
                let candidates = key.hasSuffix("srcset") ? decoded.split(separator: ",").map { String($0) } : [decoded]
                if candidates.contains(where: { isRemote($0.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: " ")[0]) }) {
                    changed = true
                    continue
                }
            } else if !(isLink && key == "href") && mentionsRemote(decoded) {
                // Any other attribute with an address in it: WebKit may know a loading use we don't.
                changed = true
                continue
            }
            kept.append(raw)
        }
        guard changed else { return original }
        let selfClosing = region.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/")
        return "<" + name + kept.map { " " + $0 }.joined() + (selfClosing ? " /" : "") + ">"
    }

    /// <link> never stays: a local stylesheet becomes a cleaned <style> block, anything else
    /// (icons, preloads, remote or unreadable stylesheets) is dropped.
    private static func inlineStylesheet(_ region: String, base: URL?) -> String {
        var values: [String: String] = [:]
        for item in attribute.matches(in: region, range: NSRange(region.startIndex..., in: region)) {
            var value = group(item, 2, region)
            if value.hasPrefix("\"") || value.hasPrefix("'") { value = String(value.dropFirst().dropLast()) }
            values[group(item, 1, region).lowercased()] = decodeEntities(value)
        }
        guard let base, let href = values["href"], !isRemote(href), (values["rel"] ?? "").lowercased().contains("stylesheet"),
              let file = localFile(href, base: base), let text = try? DocumentPipeline.readText(file) else { return "" }
        return "<style>" + css(text, base: file.deletingLastPathComponent()) + "</style>"
    }

    private static func localFile(_ reference: String, base: URL) -> URL? {
        let path = reference.components(separatedBy: CharacterSet(charactersIn: "?#"))[0]
        guard !path.isEmpty else { return nil }
        if path.lowercased().hasPrefix("file:") { return URL(string: path).flatMap { $0.isFileURL ? $0 : nil } }
        let decoded = path.removingPercentEncoding ?? path
        let file = URL(fileURLWithPath: decoded, relativeTo: base).standardizedFileURL
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    private static let importRule = try! NSRegularExpression(
        pattern: "@import\\s+(?:url\\(\\s*([\"']?)([^)]*?)\\1\\s*\\)|([\"'])(.*?)\\3)[^;]*;?", options: .caseInsensitive)

    /// CSS with escapes decoded; @import is inlined when local (cleaned, three levels deep at most)
    /// and dropped otherwise; any url() or string that points elsewhere becomes inert.
    static func css(_ text: String, base: URL?, depth: Int = 0) -> String {
        let unescaped = decodeCSSEscapes(text)
        let decoded = replace(importRule, in: unescaped) { match, text in
            let target = match.range(at: 2).location != NSNotFound ? group(match, 2, text) : group(match, 4, text)
            guard let base, depth < 3, !isRemote(target), let file = localFile(target, base: base),
                  let imported = try? DocumentPipeline.readText(file) else { return "" }
            return css(imported, base: file.deletingLastPathComponent(), depth: depth + 1)
        }
        return replace(cssReference, in: decoded) { match, text in
            let whole = group(match, 0, text)
            if match.range(at: 2).location != NSNotFound {
                return isRemote(group(match, 2, text)) ? "none" : whole
            }
            let string = match.range(at: 3).location != NSNotFound ? group(match, 3, text) : group(match, 4, text)
            return isRemote(string) ? "\"\"" : whole
        }
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "colon": ":", "sol": "/", "tab": "\t", "newline": "\n",
        "period": ".", "lpar": "(", "rpar": ")", "comma": ",", "semi": ";", "equals": "=", "num": "#", "excl": "!", "quest": "?",
        "percnt": "%", "nbsp": "\u{00A0}", "bsol": "\\",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let pattern = try! NSRegularExpression(pattern: "&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);?")
        return replace(pattern, in: text) { match, text in
            let body = group(match, 1, text)
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                return UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
            }
            if body.hasPrefix("#") {
                return UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
            }
            return named[body.lowercased()] ?? group(match, 0, text)
        }
    }

    private static func decodeCSSEscapes(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        let pattern = try! NSRegularExpression(pattern: "\\\\([0-9a-fA-F]{1,6})\\s?|\\\\(.)")
        return replace(pattern, in: text) { match, text in
            if match.range(at: 1).location != NSNotFound {
                return UInt32(group(match, 1, text), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
            }
            return group(match, 2, text)
        }
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, _ text: String) -> String {
        guard match.range(at: index).location != NSNotFound, let range = Range(match.range(at: index), in: text) else { return "" }
        return String(text[range])
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, _ transform: (NSTextCheckingResult, String) -> String) -> String {
        var result = ""
        var last = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[last..<range.lowerBound]
            result += transform(match, text)
            last = range.upperBound
        }
        return result + text[last...]
    }

}
