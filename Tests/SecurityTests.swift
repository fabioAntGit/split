import AppKit
import PDFKit

/// The local-only guarantee and hostile inputs: nothing may reach the network, escape the
/// destination folder, run commands through a file name, or expand without limit.
/// Every remote reference points at a local tripwire, so "0 connections" is measured, not assumed.
func registerSecurityTests() {
    let wire: Tripwire
    do {
        wire = try Tripwire()
    } catch {
        test("Security", "Network tripwire") { throw error }
        return
    }
    let net = wire.base

    /// Runs `body` and fails if anything connected to the tripwire meanwhile (late loads included).
    func offline(_ what: String, line: UInt = #line, _ body: () throws -> Void) rethrows {
        let before = wire.connections
        try body()
        spinRunLoop(0.4)
        let made = wire.connections - before
        let paths = Set(wire.requests(since: before).map { $0.split(separator: " ").dropFirst().first.map(String.init) ?? $0 }).sorted()
        check(made == 0, "\(what): \(made) network connection(s): \(paths)", line: line)
    }

    /// Every destination the wheel offers; returns what failed.
    func convertAll(_ url: URL) -> [String] {
        guard let format = Format.detect(url) else { return ["unknown format"] }
        return Conversions.targets(for: format).filter { $0 != .pages }.compactMap { target in
            do {
                _ = try Conversions.convert(url, to: target)
                return nil
            } catch {
                return "\(target.label): \(Explain.error(error).message)"
            }
        }
    }

    test("Security", "The network tripwire detects connections (control)") {
        check(wire.selfTest(), "the tripwire didn’t count the control connection, so the other tests would prove nothing")
    }

    test("Security", "Hostile HTML → every target without touching the network") {
        let page = try Hostile.file("hostile.html", in: "html", Hostile.html(net))
        try Hostile.stylesheets(net, next: page)
        offline("HTML") {
            let failures = convertAll(page)
            check(failures.isEmpty, "conversions failed: \(failures)")
        }
        let text = page.deletingPathExtension().appendingPathExtension("txt")
        check(Files.text(text).contains("Text that must survive"), "the page’s text should survive the clean-up")
    }

    test("Security", "Hostile Markdown (images and embedded HTML) without touching the network") {
        let markdown = try Hostile.file("hostile.md", in: "markdown", """
        # Title

        ![picture](\(net)/md-image.png)

        <img src="\(net)/md-raw.png"><link rel="stylesheet" href="\(net)/md.css">
        <iframe src="\(net)/md-frame"></iframe>

        A paragraph with a [link](\(net)/link) that must not be followed.
        """)
        offline("Markdown") {
            let failures = convertAll(markdown)
            check(failures.isEmpty, "conversions failed: \(failures)")
        }
    }

    test("Security", "Hostile SVG (image, use, @import, foreignObject) without touching the network") {
        let svg = try Hostile.file("hostile.svg", in: "svg", """
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="200" height="100" viewBox="0 0 200 100">
          <style>@import url(\(net)/svg.css); .x { fill: url(\(net)/fill.svg#g); }</style>
          <image href="\(net)/a.png" width="50" height="50"/>
          <image xlink:href="\(net)/b.png" x="50" width="50" height="50"/>
          <use href="\(net)/sprite.svg#icon"/>
          <rect x="100" width="100" height="100" fill="#ff8800"/>
          <foreignObject width="10" height="10"><iframe xmlns="http://www.w3.org/1999/xhtml" src="\(net)/fo"></iframe></foreignObject>
        </svg>
        """)
        offline("SVG") {
            let failures = convertAll(svg)
            check(failures.isEmpty, "conversions failed: \(failures)")
        }
        let png = svg.deletingPathExtension().appendingPathExtension("png")
        if let image = Pixels.load(png) {
            let pixel = Pixels.at(image, image.width * 3 / 4, image.height / 2)
            check(pixel[0] > 200 && pixel[1] > 100 && pixel[1] < 170 && pixel[2] < 60, "the local drawing should still show: \(pixel)")
        } else {
            check(false, "SVG → PNG produced no image")
        }
    }

    test("Security", "Hostile EPUB (images, CSS and an external entity) without touching the network") {
        let epub = try Hostile.package("hostile.epub", in: "epub", stored: ["mimetype": "application/epub+zip"], files: [
            "META-INF/container.xml": """
            <?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
            """,
            "OEBPS/content.opf": """
            <?xml version="1.0"?><!DOCTYPE package [<!ENTITY remote SYSTEM "\(net)/xxe-opf">]>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">x</dc:identifier><dc:title>Book &remote;</dc:title><dc:language>en</dc:language></metadata>
            <manifest><item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c1"/></spine></package>
            """,
            "OEBPS/ch1.xhtml": """
            <?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>C</title><link rel="stylesheet" href="\(net)/epub.css"/><link rel="stylesheet" href="local.css"/></head>
            <body><h1>Chapter</h1><p>The book’s text.</p><img src="\(net)/epub.png"/><p style="background:url(\(net)/epub-bg.png)">end</p></body></html>
            """,
            "OEBPS/local.css": "@import url(\(net)/epub-import.css); h1 { color: #c50; background: url('\(net)/epub-css-bg.png'); }",
        ])
        offline("EPUB") {
            for target in Conversions.targets(for: .epub) {
                do {
                    _ = try Conversions.convert(epub, to: target)
                } catch {
                    // Refusing the hostile book is acceptable, as long as it is explained.
                    check(Explain.error(error).fullText.count > 25, "\(target.label): an error without an explanation")
                }
            }
        }
    }

    test("Security", "DOCX and RTF with pictures linked to the Internet (canary tokens) without touching the network") {
        let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
        let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let docx = try Hostile.package("canary.docx", in: "docx", files: [
            "[Content_Types].xml": """
            <?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
            """,
            "_rels/.rels": """
            <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="\(r)/officeDocument" Target="word/document.xml"/></Relationships>
            """,
            "word/_rels/document.xml.rels": """
            <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId9" Type="\(r)/image" Target="\(net)/canary.png" TargetMode="External"/><Relationship Id="rId8" Type="\(r)/hyperlink" Target="\(net)/link" TargetMode="External"/></Relationships>
            """,
            "word/document.xml": """
            <?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="\(w)" xmlns:r="\(r)" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>
            <w:p><w:r><w:t>A document with a remote picture.</w:t></w:r></w:p>
            <w:p><w:r><w:drawing><wp:inline><wp:extent cx="952500" cy="952500"/><wp:docPr id="1" name="Canary"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="c.png"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:link="rId9"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="952500" cy="952500"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
            <w:p><w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText xml:space="preserve"> INCLUDEPICTURE "\(net)/field.png" \\d </w:instrText></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>
            <w:p><w:hyperlink r:id="rId8"><w:r><w:t>link</w:t></w:r></w:hyperlink></w:p>
            </w:body></w:document>
            """,
        ])
        let rtf = try Hostile.file("canary.rtf", in: "rtf", """
        {\\rtf1\\ansi{\\fonttbl\\f0 Helvetica;}\\f0 RTF text.\\par{\\field{\\*\\fldinst INCLUDEPICTURE "\(net)/rtf.png" \\\\d}{\\fldrslt }}\\par}
        """)
        offline("DOCX/RTF") {
            check(convertAll(docx).isEmpty, "DOCX: \(convertAll(docx))")
            check(convertAll(rtf).isEmpty, "RTF: \(convertAll(rtf))")
        }
    }

    test("Security", "Web pages disguised as .doc or .rtf (as Word saves them) without touching the network") {
        for name in ["page.doc", "page.rtf"] {
            let file = try Hostile.file(name, in: "disguised", Hostile.html(net))
            try Hostile.stylesheets(net, next: file)
            offline(name) {
                for target in [Format.pdf, .txt, .docx] {
                    do {
                        _ = try Conversions.convert(file, to: target)
                    } catch {
                        check(Explain.error(error).fullText.count > 25, "\(name) → \(target.label): an error without an explanation")
                    }
                }
            }
        }
    }

    test("Security", "Playlists disguised as video don’t make ffmpeg or AVFoundation go online") {
        let playlists = [
            ("playlist.mp4", "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\n\(net)/seg0.ts\n#EXT-X-ENDLIST\n"),
            ("concat.mov", "ffconcat version 1.0\nfile '\(net)/a.mp4'\n"),
            ("playlist.mp3", "#EXTM3U\n#EXTINF:2,\n\(net)/audio.mp3\n"),
        ]
        try offline("disguised playlists") {
            for (name, content) in playlists {
                let file = try Hostile.file(name, in: "playlists", content)
                for target in [Format.mp3, .mov, .gif] {
                    do {
                        _ = try Conversions.convert(file, to: target)
                        check(false, "\(name) → \(target.label) should fail: it isn’t a real video")
                    } catch {
                        check(Explain.error(error).fullText.count > 25, "\(name): an error without an explanation")
                    }
                }
                _ = try? MediaConverter.probe(file)
                _ = try? Tools.compress(file)
                // The video editor's player must not stream it either.
                let model = MediaEditorModel(url: file)
                spinRunLoop(0.6)
                _ = model
            }
        }
    }

    test("Security", "XLSX with external entities (XXE) reads no files and doesn’t go online") {
        let xlsx = try Hostile.spreadsheet("xxe.xlsx", sheet: """
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE worksheet [<!ENTITY remote SYSTEM "\(net)/xxe"><!ENTITY passwd SYSTEM "file:///etc/passwd">]>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        <row r="1"><c r="A1" t="inlineStr"><is><t>Name</t></is></c><c r="B1" t="inlineStr"><is><t>Value</t></is></c></row>
        <row r="2"><c r="A2" t="inlineStr"><is><t>a&remote;</t></is></c><c r="B2" t="inlineStr"><is><t>b&passwd;</t></is></c></row>
        </sheetData></worksheet>
        """)
        offline("XXE") {
            for target in Conversions.targets(for: .xlsx) {
                do {
                    let outputs = try Conversions.convert(xlsx, to: target)
                    for output in outputs where [.csv, .tsv, .txt, .html, .md].contains(target) {
                        check(!Files.text(output).contains("root:"), "\(target.label): the content of /etc/passwd got into the result")
                    }
                } catch {
                    check(Explain.error(error).fullText.count > 25, "\(target.label): an error without an explanation")
                }
            }
        }
    }

    test("Security", "An XLSX “billion laughs” ends quickly instead of using up memory") {
        var entities = "<!ENTITY l0 \"ha\">"
        for level in 1...9 { entities += "<!ENTITY l\(level) \"" + String(repeating: "&l\(level - 1);", count: 10) + "\">" }
        let xlsx = try Hostile.spreadsheet("laughs.xlsx", sheet: """
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE worksheet [\(entities)]>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        <row r="1"><c r="A1" t="inlineStr"><is><t>&l9;</t></is></c></row></sheetData></worksheet>
        """)
        let done = DispatchSemaphore(value: 0)
        var size: Int64 = 0
        DispatchQueue.global().async {
            if let csv = try? Conversions.convert(xlsx, to: .csv).first { size = Files.size(csv) }
            done.signal()
        }
        check(done.wait(timeout: .now() + 20) == .success, "the conversion didn’t finish in 20 s (unbounded entity expansion)")
        check(size < 10_000_000, "the result has \(size) bytes: the entities were expanded")
    }

    test("Security", "Archives with paths out of the folder (zip slip) stay contained") {
        let dir = try Hostile.folder("archives")
        let victim = dir.appendingPathComponent("victim", isDirectory: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        let absolute = dir.appendingPathComponent("absolute.txt")
        try Hostile.python("""
        import io, sys, tarfile, zipfile
        d, victim, absolute = sys.argv[1], sys.argv[2], sys.argv[3]
        z = zipfile.ZipFile(d + '/escape.zip', 'w'); z.writestr('../../outside-zip.txt', 'x'); z.writestr('ok.txt', 'ok'); z.close()
        def add(t, name, data=b'x', link=None):
            i = tarfile.TarInfo(name)
            if link: i.type, i.linkname = tarfile.SYMTYPE, link; t.addfile(i)
            else: i.size = len(data); t.addfile(i, io.BytesIO(data))
        t = tarfile.open(d + '/escape.tar.gz', 'w:gz'); add(t, '../../outside-tar.txt'); add(t, absolute); add(t, 'ok.txt'); t.close()
        t = tarfile.open(d + '/link.tar', 'w'); add(t, 'link', link=victim); add(t, 'link/inside.txt'); add(t, 'ok.txt'); t.close()
        t = tarfile.open(d + '/only-link.tar', 'w'); add(t, 'Folder/out', link='/etc'); add(t, 'Folder/ok.txt'); t.close()
        z = zipfile.ZipFile(d + '/link.zip', 'w')
        i = zipfile.ZipInfo('link'); i.create_system = 3; i.external_attr = 0o120777 << 16; z.writestr(i, victim)
        z.writestr('link/inside-zip.txt', 'x'); z.close()
        """, arguments: [dir.path, victim.path, absolute.path])
        for name in ["escape.zip", "escape.tar.gz", "link.tar", "only-link.tar", "link.zip"] {
            do {
                let results = try ArchiveTools.extract(dir.appendingPathComponent(name))
                for result in results {
                    check(result.path.hasPrefix(dir.path + "/"), "\(name): extracted outside the folder: \(result.path)")
                    let escaping = Hostile.escapingLinks(in: result)
                    check(escaping.isEmpty, "\(name): a link out of the archive was left: \(escaping)")
                }
            } catch {
                let message = Explain.error(error).fullText
                check(message.contains("outside the destination folder") || message.contains("damaged"), "\(name): \(message)")
            }
        }
        let root = Fixtures.root.deletingLastPathComponent()
        for leaked in ["outside-zip.txt", "outside-tar.txt"] {
            for folder: URL in [dir.deletingLastPathComponent(), Fixtures.root!, root, root.deletingLastPathComponent()] {
                check(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(leaked).path), "\(leaked) escaped to \(folder.path)")
            }
        }
        check(!FileManager.default.fileExists(atPath: absolute.path), "an absolute path inside the TAR was written outside the folder")
        check(Files.list(victim).isEmpty, "a link inside the archive wrote into the victim folder: \(Files.list(victim).map(\.lastPathComponent))")
    }

    test("Security", "File names with commands run nothing") {
        let dir = try Hostile.folder("names")
        let names: [(String, String, Format)] = [
            ("$(touch PWNED1).jpg", "quadrants.jpg", .png),
            ("`touch PWNED2`.png", "quadrants.png", .webp),
            ("a\"; do shell script \"touch PWNED3\" --.png", "quadrants.png", .jpg),
            ("-y.wav", "tone.wav", .mp3),
            ("-i.mp4", "clip.mp4", .gif),
            ("name & ; | > < ' \" ação 日本.mp3", "tone.mp3", .wav),
            ("--help.pdf", "report.pdf", .txt),
        ]
        for (name, sample, target) in names {
            let file = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: file.path) { try FileManager.default.copyItem(at: Fixtures.url(sample), to: file) }
            do {
                let outputs = try Conversions.convert(file, to: target)
                check(outputs.allSatisfy { $0.deletingLastPathComponent().path == dir.path }, "\(name): result outside the folder")
            } catch {
                check(false, "\(name) → \(target.label): \(Explain.error(error).fullText)")
            }
        }
        _ = try? Tools.stripMetadata(dir.appendingPathComponent("$(touch PWNED1).jpg"))
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for folder: URL in [dir, cwd, Fixtures.root!, URL(fileURLWithPath: NSHomeDirectory())] {
            let pwned = Files.list(folder).filter { $0.lastPathComponent.hasPrefix("PWNED") }
            check(pwned.isEmpty, "a file name ran a command: \(pwned.map(\.path))")
        }
    }

    test("Security", "Paths in AppleScript (Office/iWork) are quoted without allowing commands") {
        let marker = Fixtures.root.appendingPathComponent("_security/PWNED-applescript")
        let samples = [
            "/Users/x/Report \"final\".docx",
            "C:\\path\\with\\backslashes.pptx",
            "\" & (do shell script \"touch \(marker.path)\") & \"",
            "\\\" & (do shell script \"touch \(marker.path)\") & \\\"",
            "ação ✓ 日本 — end",
        ]
        for sample in samples {
            let result = try runProcess("/usr/bin/osascript", ["-e", "return " + OfficeBridge.appleScriptString(sample)])
            check(result.stdout.hasSuffix("\n") ? String(result.stdout.dropLast()) == sample : result.stdout == sample,
                  "the text changed going through AppleScript: \(sample) → \(result.stdout)")
        }
        check(!FileManager.default.fileExists(atPath: marker.path), "a path managed to run a command inside AppleScript")
    }

    test("Security", "The built app uses no networking API") {
        let binary = Hostile.project.appendingPathComponent("build/Split.app/Contents/MacOS/Split")
        try require(FileManager.default.fileExists(atPath: binary.path), "build/Split.app is missing (Tests/run.sh builds it before the tests)")
        let libraries = try runProcess("/usr/bin/otool", ["-L", binary.path]).stdout
        for forbidden in ["Network.framework", "WebKit.framework", "CFNetwork.framework", "libcurl", "SafariServices", "AuthenticationServices"] {
            check(!libraries.contains(forbidden), "the app links \(forbidden)")
        }
        let imported = try runProcess("/usr/bin/nm", ["-u", binary.path]).stdout.split(separator: "\n").map(String.init)
        for fragment in ["URLSession", "NSURLConnection", "NSURLDownload", "WKWebView", "CFSocket", "CFStreamCreatePairWithSocket",
                         "_nw_connection", "_nw_endpoint", "NSStream", "MultipeerConnectivity"] {
            let hits = imported.filter { $0.contains(fragment) }
            check(hits.isEmpty, "the app imports \(fragment): \(hits.prefix(3))")
        }
        for symbol in ["_socket", "_connect", "_getaddrinfo", "_gethostbyname", "_sendto"] {
            check(!imported.contains(symbol), "the app calls \(symbol)()")
        }
        // The only web addresses inside are XML namespace identifiers, never fetched.
        let strings = try runProcess("/usr/bin/strings", ["-a", binary.path]).stdout
        let allowed = ["schemas.openxmlformats.org", "schemas.microsoft.com", "purl.org", "www.w3.org", "www.idpf.org", "www.daisy.org",
                       "ns.adobe.com", "www.apple.com"]
        let pattern = try NSRegularExpression(pattern: "https?://([A-Za-z0-9.-]+)")
        let hosts = Set(pattern.matches(in: strings, range: NSRange(strings.startIndex..., in: strings)).compactMap {
            Range($0.range(at: 1), in: strings).map { String(strings[$0]) }
        })
        check(hosts.subtracting(allowed).isEmpty, "unexpected addresses in the binary: \(hosts.subtracting(allowed).sorted())")
        let plist = try String(contentsOf: binary.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist"))
        check(!plist.contains("NSAppTransportSecurity") && !plist.contains("NSAllowsArbitraryLoads"), "the Info.plist opens network exceptions")
    }

    test("Security", "ffmpeg only opens local files in every command") {
        // Every "-i" the app passes goes through MediaConverter.localInput (protocol whitelist "file").
        for file in Hostile.sources() {
            let text = Files.text(file)
            for (index, line) in text.components(separatedBy: "\n").enumerated() where line.contains("\"-i\"") {
                // lavfi inputs are ffmpeg's own generators (silence, colour), not files or URLs.
                check(line.contains("protocol_whitelist") || line.contains("func localInput") || line.contains("\"lavfi\""),
                      "\(file.lastPathComponent):\(index + 1) passes -i without the local protocol whitelist")
            }
        }
        check(MediaConverter.localInput(URL(fileURLWithPath: "/tmp/a.mp4")) == ["-protocol_whitelist", "file", "-i", "/tmp/a.mp4"], "localInput changed")
        check(Hostile.sources().count > 20, "the source files weren’t found: \(Hostile.sources().count)")
    }

    test("Security", "HTML clean-up: single cases") {
        let cases: [(String, String)] = [
            ("<img src=\"http://x.pt/a.png\">", "x.pt"),
            ("<IMG SRC='https://x.pt/a.png'>", "x.pt"),
            ("<img src=//x.pt/a.png>", "x.pt"),
            ("<link rel=stylesheet href=\"https://x.pt/s.css\">", "x.pt"),
            ("<style>@import url('https://x.pt/s.css');</style>", "x.pt"),
            ("<div style=\"background:url(https://x.pt/b.png)\">", "x.pt"),
            ("<script>fetch('https://x.pt')</script>", "fetch"),
            ("<iframe src=\"https://x.pt\"></iframe>", "iframe"),
            ("<base href=\"https://x.pt/\">", "x.pt"),
            ("<meta http-equiv=\"refresh\" content=\"0;url=https://x.pt\">", "x.pt"),
            ("<img srcset=\"a.png 1x, https://x.pt/b.png 2x\">", "x.pt"),
            ("<img src=\"&#104;ttps://x.pt/a.png\">", "x.pt"),
            ("<img src=\"&#x68;ttps&colon;//x.pt/a.png\">", "x.pt"),
            ("<img src=\"ht&#9;tps://x.pt/a.png\">", "x.pt"),
            ("<img/src=\"https://x.pt/a.png\">", "x.pt"),
            ("<image href=\"https://x.pt/a.png\"/>", "x.pt"),
            ("<div style=\"background:url(\\68 ttps://x.pt/b.png)\">", "x.pt"),
            ("<div style=\"background-image:image-set('https://x.pt/b.png' 1x)\">", "x.pt"),
            ("<style>@import 'https://x.pt/s.css';</style>", "x.pt"),
            ("<img src=x onerror=\"fetch('https://x.pt')\">", "x.pt"),
            ("<embed src=\"https://x.pt/e\">", "x.pt"),
        ]
        for (input, leaked) in cases {
            let clean = LocalOnly.html(input)
            check(!clean.lowercased().contains(leaked), "still refers to \(leaked): \(input) → \(clean)")
        }
        let local = "<p class=\"a>b\">Hello <img src=\"photo.png\" alt='Photo > all'> <a href=\"https://x.pt\">link</a> &amp; 5 &lt; 6</p>"
        check(LocalOnly.html(local) == local, "the clean-up changed HTML with nothing remote: \(LocalOnly.html(local))")
        check(LocalOnly.html("<img src=\"data:image/png;base64,AAAA\">").contains("data:"), "embedded pictures (data:) are local")
        check(LocalOnly.isRemote("HTTP://x") && LocalOnly.isRemote("//x") && LocalOnly.isRemote("http:x.pt") && !LocalOnly.isRemote("folder/x.png")
              && !LocalOnly.isRemote("file:///x") && !LocalOnly.isRemote("pictures/ação.png"), "isRemote")
        let prose = "<img src=\"a.png\" alt=\"Note: a chart\" title=\"Source: Eurostat, 2024\">"
        check(LocalOnly.html(prose) == prose, "text with a colon isn’t an address: \(LocalOnly.html(prose))")
        check(!LocalOnly.html("<meta property=\"og:image\" content=\"https://x.pt/i.png\">").contains("x.pt"), "any attribute with an address goes")
        check(LocalOnly.html("<link rel=\"icon\" href=\"favicon.png\">").isEmpty, "a <link> that isn’t a stylesheet goes")
        check(!LocalOnly.svg("<image href=\"https://x.pt/a.png\"/>").contains("x.pt"), "SVG <image href>")
    }
}

/// Builders for hostile inputs, kept out of the shared fixtures so nothing else reads them.
enum Hostile {
    static var project: URL {
        URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Every Swift file of the app, in all its folders.
    static func sources() -> [URL] {
        let walker = FileManager.default.enumerator(at: project.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)
        return (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    static func folder(_ name: String) throws -> URL {
        let dir = Fixtures.root.appendingPathComponent("_security/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func file(_ name: String, in folder: String, _ content: String) throws -> URL {
        let url = try self.folder(folder).appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A zip package (EPUB/DOCX/XLSX); `stored` entries go first and uncompressed, as EPUB requires.
    static func package(_ name: String, in folder: String, stored: [String: String] = [:], files: [String: String]) throws -> URL {
        let dir = try self.folder(folder)
        let staging = dir.appendingPathComponent("_\(name)", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        for (path, content) in stored.merging(files, uniquingKeysWith: { a, _ in a }) {
            let file = staging.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: file, atomically: true, encoding: .utf8)
        }
        let out = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: out)
        if !stored.isEmpty {
            try runChecked("/usr/bin/zip", ["-X", "-0", "-q", out.path] + stored.keys.sorted(), cwd: staging, what: "Creating a test package")
        }
        let tops = Set(files.keys.map { String($0.split(separator: "/")[0]) }).sorted()
        try runChecked("/usr/bin/zip", ["-X", "-r", "-q", out.path] + tops, cwd: staging, what: "Creating a test package")
        try FileManager.default.removeItem(at: staging)
        return out
    }

    /// A minimal workbook whose only sheet is `sheet`.
    static func spreadsheet(_ name: String, sheet: String) throws -> URL {
        let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        return try package(name, in: "xlsx", files: [
            "[Content_Types].xml": """
            <?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>
            """,
            "_rels/.rels": """
            <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="\(r)/officeDocument" Target="xl/workbook.xml"/></Relationships>
            """,
            "xl/workbook.xml": """
            <?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="\(r)"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>
            """,
            "xl/_rels/workbook.xml.rels": """
            <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="\(r)/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
            """,
            "xl/worksheets/sheet1.xml": sheet,
        ])
    }

    static func python(_ script: String, arguments: [String]) throws {
        let file = try folder("scripts").appendingPathComponent("make-\(UUID().uuidString.prefix(6)).py")
        try script.write(to: file, atomically: true, encoding: .utf8)
        try runChecked("/usr/bin/python3", ["-I", file.path] + arguments, what: "Creating the hostile archives")
    }

    /// Symbolic links inside `root` that resolve outside it.
    static func escapingLinks(in root: URL) -> [String] {
        let base = root.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return [] }
        var found: [String] = []
        if (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { found.append(root.lastPathComponent) }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            let target = url.resolvingSymlinksInPath().path
            if !(target == base || target.hasPrefix(base + "/")) { found.append(url.lastPathComponent) }
        }
        return found
    }

    /// A local stylesheet that imports a remote one, and a second local level that does the same.
    static func stylesheets(_ net: String, next page: URL) throws {
        let dir = page.deletingLastPathComponent()
        try "@import url(\(net)/css-import.css); @import \"level2.css\"; body { background: url(\(net)/css-bg.png); }"
            .write(to: dir.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        try "p { background-image: url('\(net)/css-level2.png'); } @import '\(net)/css-level2.css';"
            .write(to: dir.appendingPathComponent("level2.css"), atomically: true, encoding: .utf8)
    }

    /// Remote references in every form the HTML importer might follow.
    static func html(_ net: String) -> String {
        let port = net.split(separator: ":").last.map(String.init) ?? ""
        return """
        <!DOCTYPE html><html><base href="\(net)/base/"><head><meta charset="utf-8">
        <link rel="stylesheet" href="\(net)/style.css"><link rel="icon" href="\(net)/icon.png"><link rel="stylesheet" href="style.css">
        <style>@import url("\(net)/import.css"); body { background: url(\(net)/bg.png); }
        @font-face { font-family: X; src: url('\(net)/font.woff'); } p { font-family: X; }</style>
        <script src="\(net)/script.js"></script><script>document.write('<img src="\(net)/js.png">')</script>
        <meta http-equiv="refresh" content="0; url=\(net)/refresh">
        </head><body background="\(net)/body.png">
        <h1>Hostile page</h1><p>Text that must survive.</p>
        <img src="\(net)/img.png"><img src="relative.png"><img SRC = '\(net)/upper.png'><img src=\(net)/unquoted.png>
        <img src="&#104;ttp://127.0.0.1:\(port)/entity.png"><img src="&#x68;ttp://127.0.0.1:\(port)/hex.png">
        <img src="h&#116;tp://127.0.0.1:\(port)/mid-entity.png"><img src=" \(net)/spaced.png">
        <img srcset="local.png 1x, \(net)/srcset.png 2x"><img src="//127.0.0.1:\(port)/protocol-relative.png">
        <picture><source srcset="\(net)/picture.png"><img src="x.png"></picture>
        <iframe src="\(net)/frame"></iframe><object data="\(net)/object"></object><embed src="\(net)/embed">
        <video poster="\(net)/poster.png" src="\(net)/video.mp4"></video><audio src="\(net)/audio.mp3"></audio>
        <input type="image" src="\(net)/input.png">
        <div style="background-image: url('\(net)/style-attr.png')">div</div>
        <div style="background-image: image-set('\(net)/set.png' 1x)">set</div>
        <svg><image href="\(net)/svg-in-html.png" width="10" height="10"/></svg>
        <table background="\(net)/table.png"><tr><td>cell</td></tr></table>
        </body></html>
        """
    }
}
