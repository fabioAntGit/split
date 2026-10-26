import AppKit
import CoreImage
import ImageIO
import PDFKit

/// Every sample file the tests use, generated fresh for each run (nothing is downloaded).
enum Fixtures {
    static var root: URL!
    static let phrase = "Hello Split — café, crème brûlée, São Paulo"

    static func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    /// A clean copy of one fixture in its own folder, so outputs of one test don't collide with another's.
    static func isolated(_ name: String, in folder: String) throws -> URL {
        let dir = root.appendingPathComponent("_" + folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: url(name), to: target) }
        return target
    }

    static func ffmpeg(_ arguments: [String]) throws {
        try runChecked(try Engines.require("ffmpeg"), ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"] + arguments, what: "Creating a sample")
    }

    static func create(in folder: URL) throws {
        root = folder
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try images()
        try media()
        try documents()
        try spreadsheets()
        try archives()
        try data()
        try misc()
    }

    // MARK: Images

    /// 600×400: red top-left, blue top-right, green bottom-left, yellow bottom-right, alpha in the centre (PNG only).
    static func quadrants(_ width: Int = 600, _ height: Int = 400, transparentCentre: Bool = false) -> CGImage {
        let context = ImageConverter.bitmapContext(CGSize(width: width, height: height))!
        let w = CGFloat(width), h = CGFloat(height)
        // CG origin is bottom-left: the "top" half is y ≥ h/2.
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2))
        context.setFillColor(CGColor(srgbRed: 0, green: 0.8, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: w / 2, height: h / 2))
        context.setFillColor(CGColor(srgbRed: 1, green: 0.9, blue: 0, alpha: 1)); context.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h / 2))
        if transparentCentre { context.clear(CGRect(x: w * 0.4, y: h * 0.4, width: w * 0.2, height: h * 0.2)) }
        return context.makeImage()!
    }

    /// A busy photographic-like image (gradient + noise) that compresses meaningfully.
    static func photo(_ width: Int, _ height: Int) -> CGImage {
        let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: CGFloat(width), y: CGFloat(height)),
            "inputColor0": CIColor(red: 0.9, green: 0.4, blue: 0.1), "inputColor1": CIColor(red: 0.1, green: 0.3, blue: 0.8),
        ])!.outputImage!
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        let blended = noise.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: gradient])
        return Imaging.cgImage(blended, extent: CGRect(x: 0, y: 0, width: width, height: height))!
    }

    static func write(_ image: CGImage, _ name: String, type: String, properties: [CFString: Any] = [:]) throws {
        let destination = CGImageDestinationCreateWithURL(url(name) as CFURL, type as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw TestFailure("The sample \(name) wasn’t created") }
    }

    static func images() throws {
        let quads = quadrants()
        try write(quadrants(transparentCentre: true), "quadrants.png", type: "public.png")
        try write(quads, "quadrants.jpg", type: "public.jpeg", properties: [
            kCGImageDestinationLossyCompressionQuality: 0.95,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 38.72, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 9.14, kCGImagePropertyGPSLongitudeRef: "W"] as [CFString: Any],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "test"],
        ])
        // Stored landscape, displayed portrait (EXIF orientation 6 = rotate 90° clockwise).
        try write(quadrants(300, 200), "rotated.jpg", type: "public.jpeg", properties: [kCGImagePropertyOrientation: 6])
        try write(quads, "quadrants.heic", type: "public.heic", properties: [kCGImageDestinationLossyCompressionQuality: 0.9])
        try write(quads, "quadrants.tiff", type: "public.tiff")
        try write(quads, "quadrants.bmp", type: "com.microsoft.bmp")
        try write(quadrants(64, 64), "icon.ico", type: "com.microsoft.ico")
        try write(photo(2400, 1600), "photo.jpg", type: "public.jpeg", properties: [kCGImageDestinationLossyCompressionQuality: 1.0])

        // Animated GIF with three frames.
        let gif = CGImageDestinationCreateWithURL(url("animated.gif") as CFURL, "com.compuserve.gif" as CFString, 3, nil)!
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for color in [CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1), CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)] {
            CGImageDestinationAddImage(gif, Pixels.solid(120, 80, color), [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(gif) else { throw TestFailure("animated GIF") }

        try runChecked(try Engines.require("cwebp"), ["-quiet", url("quadrants.png").path, "-o", url("quadrants.webp").path], what: "WebP")
        if ((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []).contains("public.avif") {
            try write(quads, "quadrants.avif", type: "public.avif")
        }
        try """
        <svg xmlns="http://www.w3.org/2000/svg" width="300" height="200" viewBox="0 0 300 200">
          <rect width="300" height="200" fill="#ff8800"/><circle cx="150" cy="100" r="60" fill="#ffffff"/>
        </svg>
        """.write(to: url("drawing.svg"), atomically: true, encoding: .utf8)

        // A QR code (Core Image generator) for the reader.
        let qr = CIFilter(name: "CIQRCodeGenerator", parameters: ["inputMessage": Data("https://example.com/split".utf8), "inputCorrectionLevel": "M"])!
            .outputImage!.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let padded = qr.composited(over: CIImage(color: .white).cropped(to: qr.extent.insetBy(dx: -48, dy: -48)))
        try write(Imaging.cgImage(padded, extent: padded.extent)!, "qr.png", type: "public.png")

        // A simple subject on a plain background, for background removal.
        let subject = ImageConverter.bitmapContext(CGSize(width: 600, height: 600))!
        subject.setFillColor(CGColor(gray: 0.96, alpha: 1)); subject.fill(CGRect(x: 0, y: 0, width: 600, height: 600))
        subject.setFillColor(CGColor(srgbRed: 0.85, green: 0.2, blue: 0.1, alpha: 1)); subject.fillEllipse(in: CGRect(x: 170, y: 120, width: 260, height: 360))
        subject.setFillColor(CGColor(srgbRed: 0.2, green: 0.2, blue: 0.25, alpha: 1)); subject.fillEllipse(in: CGRect(x: 230, y: 420, width: 140, height: 140))
        try write(subject.makeImage()!, "subject.png", type: "public.png")
    }

    // MARK: Audio and video

    static func media() throws {
        // 2 s tone with 0.5 s of silence before and after (3 s total), stereo.
        try ffmpeg(["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=2", "-af", "adelay=500|500,apad=pad_dur=0.5,volume=0.3",
                    "-ac", "2", "-c:a", "pcm_s16le", url("tone.wav").path])
        try ffmpeg(["-i", url("tone.wav").path, "-c:a", "libmp3lame", "-b:a", "128k", "-metadata", "title=Secret track", "-metadata", "artist=Split",
                    url("tone.mp3").path])
        try ffmpeg(["-i", url("tone.wav").path, "-c:a", "flac", url("tone.flac").path])
        try ffmpeg(["-i", url("tone.wav").path, "-c:a", "aac", "-b:a", "128k", url("tone.m4a").path])
        try ffmpeg(["-i", url("tone.wav").path, "-c:a", "libopus", url("tone.opus").path])
        try ffmpeg(["-i", url("tone.wav").path, "-c:a", "vorbis", "-strict", "experimental", url("tone.ogg").path])
        try ffmpeg(["-i", url("tone.wav").path, "-c:a", "pcm_s16be", url("tone.aiff").path])
        try ffmpeg(["-i", url("tone.wav").path, "-c:a", "wmav2", url("tone.wma").path])

        let video = ["-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=2", "-f", "lavfi", "-i", "sine=frequency=660:duration=2"]
        try ffmpeg(video + ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", "-metadata", "title=Test video", url("clip.mp4").path])
        try ffmpeg(video + ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", url("clip.mov").path])
        try ffmpeg(video + ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", url("clip.m4v").path])
        try ffmpeg(video + ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", url("clip.mkv").path])
        try ffmpeg(video + ["-c:v", "libvpx-vp9", "-b:v", "300k", "-c:a", "libopus", "-shortest", url("clip.webm").path])
        try ffmpeg(video + ["-c:v", "mpeg4", "-c:a", "libmp3lame", "-shortest", url("clip.avi").path])
        try ffmpeg(video + ["-c:v", "wmv2", "-c:a", "wmav2", "-shortest", url("clip.wmv").path])
        try ffmpeg(["-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=2", "-c:v", "libx264", "-pix_fmt", "yuv420p", url("silent.mp4").path])
        // Longer clip so progress reports have time to arrive.
        try ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=640x480:rate=30:duration=12", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", url("long.mp4").path])
        // Recorded on a phone: landscape pixels with a 90° display rotation.
        try ffmpeg(["-display_rotation", "90", "-i", url("silent.mp4").path, "-c", "copy", url("portrait.mp4").path])

        try """
        1
        00:00:00,500 --> 00:00:02,000
        Hello Split

        2
        00:00:02,500 --> 00:00:04,000
        Second subtitle

        """.write(to: url("subs.srt"), atomically: true, encoding: .utf8)
        try """
        WEBVTT

        00:00:00.500 --> 00:00:02.000
        Hello Split

        """.write(to: url("subs.vtt"), atomically: true, encoding: .utf8)
    }

    // MARK: Documents

    static let html = """
    <!DOCTYPE html><html><head><meta charset="utf-8"><title>Report</title></head><body>
    <h1>Report</h1><p>\(phrase).</p><ul><li>First point</li><li>Second point</li></ul>
    <table><tr><th>Month</th><th>Value</th></tr><tr><td>March</td><td>42</td></tr></table></body></html>
    """

    static func attributed() throws -> NSAttributedString {
        try NSAttributedString(data: Data(html.utf8), options: [.documentType: NSAttributedString.DocumentType.html,
                                                               .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
    }

    static func documents() throws {
        try (phrase + "\nSecond line with accents: çãõéü.\n").write(to: url("notes.txt"), atomically: true, encoding: .utf8)
        try """
        # Report

        \(phrase).

        - First point
        - Second **point**

        [Link](https://example.com)
        """.write(to: url("readme.md"), atomically: true, encoding: .utf8)
        try html.write(to: url("page.html"), atomically: true, encoding: .utf8)
        let text = try attributed()
        try DocumentPipeline.save(text, as: .rtf, to: url("letter.rtf"))
        try DocumentPipeline.save(text, as: .docx, to: url("letter.docx"))
        try DocumentPipeline.save(text, as: .odt, to: url("letter.odt"))
        try DocumentPipeline.save(text, as: .doc, to: url("letter.doc"))
        try EPUBWriter.write(html: html, title: "Book", to: url("book.epub"))

        // Three-page PDF with "Page N" on each page.
        let pdf = PDFDocument()
        for number in 1...3 {
            let page = NSMutableAttributedString(string: "Page \(number)\n\(phrase)",
                                                 attributes: [.font: NSFont(name: "Helvetica", size: 28)!, .foregroundColor: NSColor.black])
            let file = root.appendingPathComponent("page\(number).pdf")
            try PDFRender.write(page, to: file)
            if let single = PDFDocument(url: file), let first = single.page(at: 0) { pdf.insert(first, at: pdf.pageCount) }
            try FileManager.default.removeItem(at: file)
        }
        pdf.documentAttributes = [PDFDocumentAttribute.authorAttribute: "Secret Author", PDFDocumentAttribute.titleAttribute: "Document"]
        guard pdf.write(to: url("report.pdf")) else { throw TestFailure("report.pdf") }

        // Scanned page: text only as pixels (needs OCR).
        let scan = ImageConverter.bitmapContext(CGSize(width: 1240, height: 1754))!
        scan.setFillColor(CGColor(gray: 1, alpha: 1)); scan.fill(CGRect(x: 0, y: 0, width: 1240, height: 1754))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: scan, flipped: false)
        NSAttributedString(string: "Invoice number 2024", attributes: [.font: NSFont.systemFont(ofSize: 64, weight: .bold), .foregroundColor: NSColor.black])
            .draw(at: CGPoint(x: 120, y: 1400))
        NSGraphicsContext.restoreGraphicsState()
        let scanned = PDFDocument()
        scanned.insert(PDFPage(image: NSImage(cgImage: scan.makeImage()!, size: NSSize(width: 595, height: 842)))!, at: 0)
        guard scanned.write(to: url("scanned.pdf")) else { throw TestFailure("scanned.pdf") }

        let locked = PDFDocument(url: url("report.pdf"))!
        guard locked.write(to: url("locked.pdf"), withOptions: [.userPasswordOption: "secret", .ownerPasswordOption: "secret"]) else { throw TestFailure("locked.pdf") }
    }

    // MARK: Spreadsheets

    static func spreadsheets() throws {
        try """
        Product;Price;Date;Discount;Total
        Orange;1,25;31/03/2024;10%;=B2*0.9
        Lemon;0,80;2024-04-01;5%;=B3*0.95
        """.write(to: url("prices.csv"), atomically: true, encoding: .utf8)
        try "Name\tAge\nAna\t31\nRui\t45\n".write(to: url("people.tsv"), atomically: true, encoding: .utf8)
        try XLSX.write([Sheet(name: "Sales", rows: [["Month", "Value"], ["March", "42"], ["April", "17.5"]]),
                        Sheet(name: "Notes", rows: [["Hello Split"]])], to: url("sales.xlsx"))
        try styledXLSX(date1904: false, name: "dates.xlsx")
        try styledXLSX(date1904: true, name: "dates1904.xlsx")
    }

    /// A workbook as Excel writes it: shared strings, date and percent formats, a formula with a cached value.
    static func styledXLSX(date1904: Bool, name: String) throws {
        let dir = root.appendingPathComponent("_xlsx-\(name)")
        try? FileManager.default.removeItem(at: dir)
        for sub in ["_rels", "xl/_rels", "xl/worksheets"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let files: [String: String] = [
            "[Content_Types].xml": """
            <?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/></Types>
            """,
            "_rels/.rels": """
            <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
            """,
            "xl/workbook.xml": """
            <?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><workbookPr\(date1904 ? " date1904=\"1\"" : "")/><sheets><sheet name="Dates" sheetId="1" r:id="rId1"/></sheets></workbook>
            """,
            "xl/_rels/workbook.xml.rels": """
            <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/></Relationships>
            """,
            "xl/styles.xml": """
            <?xml version="1.0" encoding="UTF-8"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="1"><numFmt numFmtId="170" formatCode="dd/mm/yyyy\\ hh:mm"/></numFmts><fonts count="1"><font/></fonts><fills count="1"><fill/></fills><borders count="1"><border/></borders><cellXfs count="4"><xf numFmtId="0"/><xf numFmtId="14" applyNumberFormat="1"/><xf numFmtId="170" applyNumberFormat="1"/><xf numFmtId="10" applyNumberFormat="1"/></cellXfs></styleSheet>
            """,
            "xl/sharedStrings.xml": """
            <?xml version="1.0" encoding="UTF-8"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="3" uniqueCount="3"><si><t>Date</t></si><si><t>When</t></si><si><r><t>Rate</t></r><rPh><t>X</t></rPh></si></sst>
            """,
            "xl/worksheets/sheet1.xml": """
            <?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c><c r="D1" t="inlineStr"><is><t>Sum</t></is></c></row><row r="2"><c r="A2" s="1"><v>\(date1904 ? "43555" : "45017")</v></c><c r="B2" s="2"><v>\(date1904 ? "43555.5" : "45017.5")</v></c><c r="C2" s="3"><v>0.125</v></c><c r="D2"><f>1+1</f><v>2</v></c><c r="E2" t="b"><v>1</v></c></row></sheetData></worksheet>
            """,
        ]
        for (path, content) in files {
            try content.write(to: dir.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        try runChecked("/usr/bin/zip", ["-X", "-r", "-q", url(name).path, "[Content_Types].xml", "_rels", "xl"], cwd: dir, what: "Test XLSX")
        try FileManager.default.removeItem(at: dir)
    }

    // MARK: Archives

    static func archives() throws {
        let folder = root.appendingPathComponent("_bundle/Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "one".write(to: folder.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        try "two".write(to: folder.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8)
        let parent = folder.deletingLastPathComponent()
        try runChecked("/usr/bin/zip", ["-r", "-q", url("folder.zip").path, "Folder"], cwd: parent, what: "zip")
        try runChecked("/usr/bin/tar", ["-cf", url("folder.tar").path, "-C", parent.path, "Folder"], what: "tar")
        try runChecked("/usr/bin/tar", ["-czf", url("folder.tar.gz").path, "-C", parent.path, "Folder"], what: "tgz")
        try runChecked("/usr/bin/zip", ["-q", "-j", url("two.zip").path, folder.appendingPathComponent("one.txt").path, folder.appendingPathComponent("two.txt").path], what: "zip")
        try FileManager.default.removeItem(at: parent)
        var corrupt = Data([0x50, 0x4B, 0x03, 0x04])
        corrupt.append(Data((0..<400).map { _ in UInt8.random(in: 0...255) }))
        try corrupt.write(to: url("corrupt.zip"))
    }

    // MARK: Data

    static func data() throws {
        try """
        {"name": "Split", "version": 1.50, "tags": ["local", "café"], "nested": {"empty": null, "ok": true, "big": 12345678901234567890},
         "list": [{"a": 1}, {"a": 2, "b": "x"}]}
        """.write(to: url("data.json"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <catalog lang="en"><book id="1"><title>Café Split</title><price>9.50</price></book><book id="2"><title>Tea</title></book></catalog>
        """.write(to: url("data.xml"), atomically: true, encoding: .utf8)
    }

    // MARK: Odd files for error handling

    static func misc() throws {
        FileManager.default.createFile(atPath: url("empty.txt").path, contents: Data())
        try FileManager.default.copyItem(at: url("quadrants.jpg"), to: url("fake.png"))
        try "<!DOCTYPE html><html><body>Page not found</body></html>".write(to: url("page.jpg"), atomically: true, encoding: .utf8)
        let truncated = try Data(contentsOf: url("clip.mp4")).prefix(3000)
        try truncated.write(to: url("broken.mp4"))
        try FileManager.default.createDirectory(at: url("A folder"), withIntermediateDirectories: true)
        try "?".write(to: url("mystery.xyz"), atomically: true, encoding: .utf8)
    }

    // MARK: PowerPoint (only for the opt-in Office tests)

    static func pptx(_ out: URL) throws {
        let dir = root.appendingPathComponent("_pptx")
        try? FileManager.default.removeItem(at: dir)
        let ns = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""
        let emptyTree = "<p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>"
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        func colors() -> String {
            let pairs = [("dk1", "000000"), ("lt1", "FFFFFF"), ("dk2", "1F2937"), ("lt2", "F3F4F6"), ("accent1", "FF9500"), ("accent2", "2E8BFF"),
                         ("accent3", "43E97B"), ("accent4", "FA709A"), ("accent5", "A18CD1"), ("accent6", "FEE140"), ("hlink", "0563C1"), ("folHlink", "954F72")]
            return pairs.map { "<a:\($0.0)><a:srgbClr val=\"\($0.1)\"/></a:\($0.0)>" }.joined()
        }
        let fill = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        let line = "<a:ln w=\"9525\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln>"
        let theme = "\(header)<a:theme xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" name=\"Split\"><a:themeElements><a:clrScheme name=\"C\">\(colors())</a:clrScheme><a:fontScheme name=\"C\"><a:majorFont><a:latin typeface=\"Helvetica\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:majorFont><a:minorFont><a:latin typeface=\"Helvetica\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:minorFont></a:fontScheme><a:fmtScheme name=\"C\"><a:fillStyleLst>\(fill)\(fill)\(fill)</a:fillStyleLst><a:lnStyleLst>\(line)\(line)\(line)</a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst>\(fill)\(fill)\(fill)</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>"
        let files: [String: String] = [
            "[Content_Types].xml": "\(header)<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/><Override PartName=\"/ppt/slides/slide1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/><Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml\"/><Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml\"/><Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/></Types>",
            "_rels/.rels": "\(header)<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(rel)/officeDocument\" Target=\"ppt/presentation.xml\"/></Relationships>",
            "ppt/presentation.xml": "\(header)<p:presentation \(ns)><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst><p:sldIdLst><p:sldId id=\"256\" r:id=\"rId2\"/></p:sldIdLst><p:sldSz cx=\"9144000\" cy=\"6858000\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>",
            "ppt/_rels/presentation.xml.rels": "\(header)<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(rel)/slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/><Relationship Id=\"rId2\" Type=\"\(rel)/slide\" Target=\"slides/slide1.xml\"/><Relationship Id=\"rId3\" Type=\"\(rel)/theme\" Target=\"theme/theme1.xml\"/></Relationships>",
            "ppt/slideMasters/slideMaster1.xml": "\(header)<p:sldMaster \(ns)><p:cSld>\(emptyTree)</p:spTree></p:cSld><p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/><p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst></p:sldMaster>",
            "ppt/slideMasters/_rels/slideMaster1.xml.rels": "\(header)<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(rel)/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/><Relationship Id=\"rId2\" Type=\"\(rel)/theme\" Target=\"../theme/theme1.xml\"/></Relationships>",
            "ppt/slideLayouts/slideLayout1.xml": "\(header)<p:sldLayout \(ns) type=\"blank\"><p:cSld name=\"Blank\">\(emptyTree)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>",
            "ppt/slideLayouts/_rels/slideLayout1.xml.rels": "\(header)<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(rel)/slideMaster\" Target=\"../slideMasters/slideMaster1.xml\"/></Relationships>",
            "ppt/slides/slide1.xml": "\(header)<p:sld \(ns)><p:cSld>\(emptyTree)<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"Text\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"914400\" y=\"914400\"/><a:ext cx=\"7315200\" cy=\"1371600\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang=\"en-US\" sz=\"4000\"/><a:t>Hello Split</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>",
            "ppt/slides/_rels/slide1.xml.rels": "\(header)<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(rel)/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/></Relationships>",
            "ppt/theme/theme1.xml": theme,
        ]
        for (path, content) in files {
            let file = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: file, atomically: true, encoding: .utf8)
        }
        try runChecked("/usr/bin/zip", ["-X", "-r", "-q", out.path, "[Content_Types].xml", "_rels", "ppt"], cwd: dir, what: "Test PPTX")
        try FileManager.default.removeItem(at: dir)
    }
}
