import AppKit
import PDFKit

/// The full conversion matrix: every sample × every target the wheel offers,
/// each result checked for its real content, not just its extension.
func registerConversionTests() {
    let samples = [
        "quadrants.png", "quadrants.jpg", "quadrants.heic", "quadrants.tiff", "quadrants.bmp", "quadrants.webp", "icon.ico",
        "animated.gif", "drawing.svg", "quadrants.avif",
        "tone.wav", "tone.mp3", "tone.flac", "tone.m4a", "tone.opus", "tone.ogg", "tone.aiff", "tone.wma",
        "clip.mp4", "clip.mov", "clip.m4v", "clip.mkv", "clip.webm", "clip.avi", "clip.wmv",
        "notes.txt", "readme.md", "page.html", "letter.rtf", "letter.docx", "letter.odt", "letter.doc", "book.epub", "report.pdf",
        "prices.csv", "people.tsv", "sales.xlsx", "subs.srt", "subs.vtt", "folder.zip", "folder.tar", "folder.tar.gz",
        "data.json", "data.xml",
    ]
    for name in samples {
        test("Conversion", "\(name) → every format on the wheel") {
            guard FileManager.default.fileExists(atPath: Fixtures.url(name).path) else {
                if name.hasSuffix(".avif") { return } // this Mac's ImageIO can't write AVIF samples
                throw TestFailure("The sample \(name) is missing")
            }
            let source = try Fixtures.isolated(name, in: "matrix-\(name)")
            let format = try requireFormat(source)
            let targets = Conversions.targets(for: format).filter { $0 != .pages }
            try require(!targets.isEmpty, "\(name) has no targets on the wheel")
            let before = Files.sha(source)
            for target in targets {
                do {
                    let outputs = try Conversions.convert(source, to: target)
                    check(!outputs.isEmpty, "\(name) → \(target.label): no result")
                    for output in outputs { validate(output, target: target, from: source, format: format) }
                } catch {
                    check(false, "\(name) → \(target.label) failed: \(Explain.error(error, file: source).fullText)")
                }
            }
            check(Files.sha(source) == before, "\(name): the original was changed")
            let leftovers = Files.list(source.deletingLastPathComponent()).filter { $0.lastPathComponent.contains(".split-") }
            check(leftovers.isEmpty, "\(name): temporary files were left: \(leftovers.map(\.lastPathComponent))")
        }
    }

    test("Conversion", "The EXIF orientation is applied (300×200 rotated → 200×300)") {
        let source = try Fixtures.isolated("rotated.jpg", in: "orientation")
        let out = try Conversions.convert(source, to: .png)[0]
        let info = try requireInfo(out)
        check(info.width == 200 && info.height == 300, "expected 200×300, got \(info.width)×\(info.height)")
        let image = Pixels.load(out)!
        // Rotating 90° clockwise puts the old bottom-left (green) at the top-left.
        check(Pixels.close(Pixels.at(image, 20, 20), [0, 204, 0]), "the top-left corner should be green: \(Pixels.at(image, 20, 20))")
    }

    test("Conversion", "Transparency: PNG→JPG gets a white background, PNG→WebP keeps alpha") {
        let source = try Fixtures.isolated("quadrants.png", in: "alpha")
        let jpg = try Conversions.convert(source, to: .jpg)[0]
        let centre = Pixels.at(Pixels.load(jpg)!, 300, 200)
        check(Pixels.close(centre, [255, 255, 255], 12), "the transparent centre should be white in the JPG: \(centre)")
        let webp = try Conversions.convert(source, to: .webp)[0]
        check(try requireInfo(webp).hasAlpha, "the WebP should keep the transparency")
    }

    test("Conversion", "Metadata: GPS kept by default and removed when turned off") {
        let source = try Fixtures.isolated("quadrants.jpg", in: "metadata")
        Settings.keepsMetadata = true
        let kept = try Conversions.convert(source, to: .heic)[0]
        check(try requireInfo(kept).properties[kCGImagePropertyGPSDictionary] != nil, "the GPS should be kept")
        Settings.keepsMetadata = false
        defer { Settings.keepsMetadata = true }
        let dropped = try Conversions.convert(source, to: .png)[0]
        check(try requireInfo(dropped).properties[kCGImagePropertyGPSDictionary] == nil, "the GPS should be removed")
    }

    test("Conversion", "ICO is a 256×256 square and the animated GIF keeps its frames") {
        let source = try Fixtures.isolated("quadrants.png", in: "ico")
        let ico = try requireInfo(try Conversions.convert(source, to: .ico)[0])
        check(ico.width == 256 && ico.height == 256, "ICO \(ico.width)×\(ico.height)")
        let gif = try Fixtures.isolated("animated.gif", in: "gif-frames")
        let tiff = try requireInfo(try Conversions.convert(gif, to: .tiff)[0])
        check(tiff.width == 120 && tiff.frames == 3, "TIFF from the GIF: \(tiff.width) px, \(tiff.frames) pages")
        let webp = try Conversions.convert(gif, to: .webp)[0]
        check(Files.text(webp).isEmpty && Files.size(webp) > 0, "animated WebP created")
        let mp4 = try Conversions.convert(gif, to: .mp4)[0]
        check(Probe.codecs(mp4, type: "video") == ["h264"], "GIF → MP4 should be H.264")
    }

    test("Conversion", "Audio: the right codecs and the same length") {
        let source = try Fixtures.isolated("tone.wav", in: "audio-codecs")
        let expected: [Format: String] = [.mp3: "mp3", .m4a: "aac", .flac: "flac", .ogg: "vorbis", .opus: "opus", .aiff: "pcm_s16be", .wma: "wmav2"]
        for (target, codec) in expected {
            let out = try Conversions.convert(source, to: target)[0]
            check(Probe.codecs(out, type: "audio") == [codec], "\(target.label): codec \(Probe.codecs(out, type: "audio")) instead of \(codec)")
            check(near(Probe.duration(out), 3, 0.15), "\(target.label): length \(Probe.duration(out))")
        }
    }

    test("Conversion", "Video: MP4→MOV/MKV without re-encoding; WebM is VP9+Opus") {
        let source = try Fixtures.isolated("clip.mp4", in: "video-codecs")
        let mov = try Conversions.convert(source, to: .mov)[0]
        check(Probe.codecs(mov, type: "video") == ["h264"], "MOV should keep H.264")
        let webm = try Conversions.convert(source, to: .webm)[0]
        check(Probe.codecs(webm, type: "video") == ["vp9"] && Probe.codecs(webm, type: "audio") == ["opus"], "WebM: \(Probe.codecs(webm, type: "video")) \(Probe.codecs(webm, type: "audio"))")
        let gif = try Conversions.convert(source, to: .gif)[0]
        check(try requireInfo(gif).frames > 10, "the GIF from the video should be animated")
        let portrait = try Fixtures.isolated("portrait.mp4", in: "video-rotation")
        let upright = try Conversions.convert(portrait, to: .webm)[0]
        let size = Probe.videoSize(upright)
        check(size.height > size.width, "a portrait video should stay portrait: \(size)")
    }

    test("Conversion", "Documents: text and accents survive every round trip") {
        let source = try Fixtures.isolated("readme.md", in: "doc-roundtrip")
        let html = try Conversions.convert(source, to: .html)[0]
        check(Files.text(html).contains("<h1>Report</h1>"), "Markdown → HTML without its heading")
        let epub = try Conversions.convert(source, to: .epub)[0]
        let back = try Conversions.convert(epub, to: .txt)[0]
        check(Files.text(back).contains("Hello Split — café, crème brûlée, São Paulo"), "EPUB → TXT lost the text or the accents: \(Files.text(back).prefix(120))")
        let docx = try Conversions.convert(source, to: .docx)[0]
        let pdf = try Conversions.convert(docx, to: .pdf)[0]
        check(Files.pdfText(pdf).contains("Split"), "DOCX → PDF without the text")
    }

    test("Conversion", "PDF: pages to PNG in a folder, and OCR on scans") {
        let source = try Fixtures.isolated("report.pdf", in: "pdf-pages")
        let folder = try Conversions.convert(source, to: .png)[0]
        check(Files.list(folder).count == 3, "3 pages → \(Files.list(folder).count) PNG")
        let scanned = try Fixtures.isolated("scanned.pdf", in: "pdf-ocr")
        let text = try Conversions.convert(scanned, to: .txt)[0]
        check(Files.text(text).contains("2024"), "OCR should read “Invoice number 2024”: \(Files.text(text).prefix(80))")
    }

    test("Conversion", "SRT ↔ VTT subtitles keep the text and timing") {
        let source = try Fixtures.isolated("subs.srt", in: "subtitles")
        let vtt = Files.text(try Conversions.convert(source, to: .vtt)[0])
        check(vtt.hasPrefix("WEBVTT") && vtt.contains("00:00.500") && vtt.contains("Hello Split"), "VTT: \(vtt.prefix(100))")
    }

    test("Conversion", "Archives: ZIP → TAR keeps the files") {
        let source = try Fixtures.isolated("folder.zip", in: "archive-convert")
        let tar = try Conversions.convert(source, to: .tar)[0]
        let listing = try runProcess("/usr/bin/tar", ["-tf", tar.path]).stdout
        check(listing.contains("Folder/one.txt") && listing.contains("Folder/two.txt"), "TAR: \(listing)")
    }

    test("Conversion", "Several files in parallel get distinct, valid names") {
        let folder = Fixtures.root.appendingPathComponent("_parallel")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var sources: [URL] = []
        for index in 0..<8 {
            let copy = folder.appendingPathComponent(index % 2 == 0 ? "photo \(index).jpg" : "photo \(index - 1).heic")
            if !FileManager.default.fileExists(atPath: copy.path) {
                try FileManager.default.copyItem(at: Fixtures.url(index % 2 == 0 ? "quadrants.jpg" : "quadrants.heic"), to: copy)
            }
            sources.append(copy)
        }
        var outputs = [[URL]](repeating: [], count: sources.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: sources.count) { index in
            let result = (try? Conversions.convert(sources[index], to: .png)) ?? []
            lock.lock(); outputs[index] = result; lock.unlock()
        }
        let flat = outputs.flatMap { $0 }
        check(flat.count == sources.count, "\(flat.count) of \(sources.count) parallel conversions")
        check(Set(flat.map(\.path)).count == flat.count, "two conversions wrote to the same file")
        check(flat.allSatisfy { Pixels.info($0)?.width == 600 }, "a PNG came out invalid")
    }

    test("Conversion", "Real progress while ffmpeg runs") {
        let source = try Fixtures.isolated("long.mp4", in: "progress")
        var fractions: [Double] = []
        _ = try JobProgress.run({ fractions.append($0) }) { try Conversions.convert(source, to: .webm) }
        check(!fractions.isEmpty, "no progress update")
        check(fractions.allSatisfy { $0 >= 0 && $0 <= 1 }, "fractions outside 0…1: \(fractions)")
        check(fractions == fractions.sorted(), "progress went backwards: \(fractions)")
    }

    test("Spreadsheets", "European CSV → XLSX: numbers, dates, percentages, formulas, header") {
        let source = try Fixtures.isolated("prices.csv", in: "xlsx-write")
        let xlsx = try Conversions.convert(source, to: .xlsx)[0]
        let sheet = String(decoding: try XLSX.entry(xlsx, "xl/worksheets/sheet1.xml") ?? Data(), as: UTF8.self)
        check(sheet.contains("<c r=\"B2\"><v>1.25</v></c>"), "1,25 should be the number 1.25")
        check(sheet.contains("<c r=\"C2\" s=\"2\"><v>45382"), "31/03/2024 should be the date 45382 with a date style")
        check(sheet.contains("<c r=\"D2\" s=\"4\"><v>0.1</v>"), "10% should be 0.1 with a percent style")
        check(sheet.contains("<f>B2*0.9</f>"), "=B2*0.9 should be a formula")
        check(sheet.contains("<c r=\"A1\" s=\"1\""), "the header should be bold")
        check(sheet.contains("<pane ySplit=\"1\""), "the header should be frozen")
        check(sheet.contains("<cols>"), "the column widths are missing")
        let workbook = String(decoding: try XLSX.entry(xlsx, "xl/workbook.xml") ?? Data(), as: UTF8.self)
        check(workbook.contains("fullCalcOnLoad=\"1\""), "formulas wouldn’t be calculated on opening")
        let rows = try SpreadsheetConverter.read(xlsx, from: .xlsx)[0].rows
        check(rows[1][2] == "2024-03-31", "the date comes back as \(rows[1][2])")
        check(rows[1][3] == "10%", "the percentage comes back as \(rows[1][3])")
    }

    test("Spreadsheets", "XLSX from Excel: dates, date-times, %, booleans and the 1904 system") {
        for name in ["dates.xlsx", "dates1904.xlsx"] {
            let rows = try SpreadsheetConverter.read(Fixtures.url(name), from: .xlsx)[0].rows
            try require(rows.count == 2, "\(name): \(rows.count) rows")
            check(rows[0] == ["Date", "When", "Rate", "Sum"], "\(name): header \(rows[0])")
            check(rows[1][0] == "2023-04-01", "\(name): date \(rows[1][0])")
            check(rows[1][1] == "2023-04-01 12:00", "\(name): date-time \(rows[1][1])")
            check(rows[1][2] == "12.5%", "\(name): percentage \(rows[1][2])")
            check(rows[1][3] == "2", "\(name): a formula should show its cached value: \(rows[1][3])")
            check(rows[1][4] == "TRUE", "\(name): boolean \(rows[1][4])")
        }
    }

    test("Spreadsheets", "Number format detection (ECMA-376)") {
        check(XLSX.kind(numFmtID: 14, code: nil) == .date, "14 is a date")
        check(XLSX.kind(numFmtID: 22, code: nil) == .dateTime, "22 is a date-time")
        check(XLSX.kind(numFmtID: 10, code: nil) == .percent, "10 is a percentage")
        check(XLSX.kind(numFmtID: 170, code: "[$-816]dd/mm/yyyy;@") == .date, "custom date code")
        check(XLSX.kind(numFmtID: 171, code: "#,##0.00\" €\"") == .general, "currency isn’t a date")
        check(XLSX.kind(numFmtID: 172, code: "[Red]0.00") == .general, "[Red] isn’t a date")
        check(XLSX.kind(numFmtID: 173, code: "hh:mm") == .time, "hh:mm is a time")
        check(XLSX.parseDate("31/02/2024") == nil, "31/02 isn’t a valid date")
        check(XLSX.parseDate("12345678") == nil, "a number isn’t a date")
    }
}

// MARK: - Validation of one output

private func requireFormat(_ url: URL) throws -> Format {
    guard let format = Format.detect(url) else { throw TestFailure("format of \(url.lastPathComponent)") }
    return format
}

func requireInfo(_ url: URL) throws -> ImageInfo {
    guard let info = Pixels.info(url) else { throw TestFailure("\(url.lastPathComponent) doesn’t open as an image") }
    return info
}

private func validate(_ output: URL, target: Format, from source: URL, format: Format) {
    let label = "\(source.lastPathComponent) → \(target.label)"
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: output.path, isDirectory: &isDirectory) else {
        check(false, "\(label): the output file doesn’t exist")
        return
    }
    check(output.deletingLastPathComponent().path.hasPrefix(source.deletingLastPathComponent().path), "\(label): result outside the original’s folder")
    if isDirectory.boolValue {
        let items = Files.list(output)
        check(!items.isEmpty, "\(label): empty folder")
        items.forEach { validate($0, target: target, from: source, format: format) }
        return
    }
    check(Files.size(output) > 0, "\(label): empty file")
    switch target.group {
    case .image:
        if target == .pdf {
            check((PDFDocument(url: output)?.pageCount ?? 0) >= 1, "\(label): PDF without pages")
        } else if target == .webp {
            check(FileCheck.sniff(output) == "WebP", "\(label): not WebP (\(FileCheck.sniff(output) ?? "?"))")
        } else if let info = Pixels.info(output) {
            check(info.width > 0 && info.height > 0, "\(label): image without dimensions")
        } else if target == .mp4 || target == .webm {
            check(!Probe.codecs(output, type: "video").isEmpty, "\(label): video without a picture")
        } else {
            check(false, "\(label): doesn’t open as an image (\(FileCheck.sniff(output) ?? "?"))")
        }
    case .audio:
        check(!Probe.codecs(output, type: "audio").isEmpty, "\(label): no audio track")
        check(Probe.codecs(output, type: "video").isEmpty, "\(label): the audio has an extra picture")
        if format.group == .audio || format.group == .video {
            let expected = Probe.duration(source)
            check(near(Probe.duration(output), expected, 0.25), "\(label): length \(Probe.duration(output)) ≠ \(expected)")
        }
    case .video:
        check(!Probe.codecs(output, type: "video").isEmpty, "\(label): no picture")
        if format.group == .video {
            check(near(Probe.duration(output), Probe.duration(source), 0.3), "\(label): length \(Probe.duration(output))")
            check(!Probe.codecs(output, type: "audio").isEmpty, "\(label): lost the sound")
        }
    case .document:
        switch target {
        case .pdf:
            check((PDFDocument(url: output)?.pageCount ?? 0) >= 1, "\(label): invalid PDF")
            if [.txt, .md, .html, .rtf, .docx, .odt, .doc, .epub].contains(format) {
                check(Files.pdfText(output).contains("Split"), "\(label): the PDF doesn’t have the text")
            }
        case .png, .jpg:
            check(Pixels.info(output) != nil, "\(label): the page isn’t an image")
        case .txt, .html:
            check(Files.text(output).contains("Split") || format == .csv || format == .tsv || format == .xlsx,
                  "\(label): text missing or in the wrong encoding")
        case .docx, .odt, .epub:
            check(FileCheck.sniff(output) == "ZIP", "\(label): not a ZIP package")
            if target != .epub, let text = try? NSAttributedString(url: output, options: [:], documentAttributes: nil).string {
                check(text.contains("Split"), "\(label): the document lost its text")
            }
        case .rtf:
            check(FileCheck.sniff(output) == "RTF", "\(label): not RTF")
        default:
            break
        }
    case .spreadsheet:
        if target == .xlsx { check(FileCheck.sniff(output) == "ZIP", "\(label): invalid XLSX") }
        if target == .csv || target == .tsv { check(!Files.text(output).isEmpty, "\(label): empty CSV") }
    case .subtitle:
        check(Files.text(output).contains("Split"), "\(label): subtitles without text")
    case .archive:
        let listing = (try? runProcess("/usr/bin/tar", ["-tf", output.path]).stdout) ?? ""
        check(listing.contains("one.txt"), "\(label): archive without the files: \(listing)")
    case .presentation:
        break
    case .data:
        let text = Files.text(output)
        check(!text.isEmpty, "\(label): empty data file")
        if target == .json { check((try? JSONParser.parse(Data(text.utf8))) != nil, "\(label): invalid JSON") }
        if target == .xml { check(XMLParser(data: Data(text.utf8)).parse(), "\(label): invalid XML") }
    }
}
