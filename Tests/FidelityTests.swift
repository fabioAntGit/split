import AppKit
import ImageIO
import PDFKit

/// Converting must never drop content in silence: what the target can hold is kept, and what
/// it can't is reported as a note (shown in the HUD, the activity list and the CLI).
func registerFidelityTests() {
    func folder(_ name: String) throws -> URL { try Hostile.folder("fidelity-\(name)") }
    func ffmpeg(_ arguments: [String]) throws { try Fixtures.ffmpeg(arguments) }

    test("Fidelity", "Animations and pages: kept where the format can, said where it can’t") {
        let gif = try Fixtures.isolated("animated.gif", in: "fidelity-gif")
        let (apng, apngNotes) = try Fidelity.collect { try Conversions.convert(gif, to: .png)[0] }
        check(try requireInfo(apng).frames == 3 && apngNotes.isEmpty, "GIF → PNG is an animated PNG with 3 frames")
        let (jpg, jpgNotes) = try Fidelity.collect { try Conversions.convert(gif, to: .jpg)[0] }
        check(try requireInfo(jpg).frames == 1 && jpgNotes.contains { $0.contains("first of the 3 frames") }, "GIF → JPG says it kept one frame: \(jpgNotes)")
        let (_, tiffNotes) = try Fidelity.collect { try Conversions.convert(gif, to: .tiff) }
        check(tiffNotes.contains { $0.contains("timing") }, "GIF → TIFF says the timing is lost: \(tiffNotes)")

        let pages = try folder("pages").appendingPathComponent("scan.tiff")
        let destination = CGImageDestinationCreateWithURL(pages as CFURL, "public.tiff" as CFString, 3, nil)!
        for gray in [0.2, 0.5, 0.8] { CGImageDestinationAddImage(destination, Pixels.solid(200, 300, CGColor(gray: gray, alpha: 1)), nil) }
        try require(CGImageDestinationFinalize(destination), "multi-page TIFF")
        let split = try Conversions.convert(pages, to: .png)
        check(split.count == 1 && Files.list(split[0]).count == 3, "3 pages → a folder of 3 PNG files: \(split.map(\.lastPathComponent))")
        let pdf = try Conversions.convert(pages, to: .pdf)[0]
        check(PDFDocument(url: pdf)?.pageCount == 3, "3 pages → a 3-page PDF")
    }

    test("Fidelity", "Transparency, orientation and metadata") {
        let png = try Fixtures.isolated("quadrants.png", in: "fidelity-alpha")
        let (_, notes) = try Fidelity.collect { try Conversions.convert(png, to: .jpg) }
        check(notes.contains { $0.contains("transparency") }, "PNG → JPG says the transparency became white: \(notes)")
        let (_, bmp) = try Fidelity.collect { try Conversions.convert(png, to: .bmp) }
        check(bmp.isEmpty, "BMP keeps the alpha, so there is nothing to say: \(bmp)")
        let jpg = try Fixtures.isolated("quadrants.jpg", in: "fidelity-metadata")
        let (_, opaque) = try Fidelity.collect { try Conversions.convert(jpg, to: .png) }
        check(opaque.isEmpty, "an opaque JPG → PNG has nothing to report: \(opaque)")
        let heic = try requireInfo(try Conversions.convert(jpg, to: .heic)[0])
        let exif = heic.properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        check(heic.properties[kCGImagePropertyGPSDictionary] != nil && exif?[kCGImagePropertyExifUserComment] as? String == "test", "HEIC keeps GPS and EXIF")
        let rotated = try Fixtures.isolated("rotated.jpg", in: "fidelity-orientation")
        let tiff = try requireInfo(try Conversions.convert(rotated, to: .tiff)[0])
        check(tiff.properties[kCGImagePropertyOrientation] as? Int == 6 && tiff.width == 300, "the orientation stays a tag (the pixels aren’t re-rotated)")
    }

    test("Fidelity", "JPEG XL: a JPEG goes in losslessly and comes back byte for byte") {
        guard let djxl = Engines.path("djxl"), Engines.path("cjxl") != nil else { return }
        let jpg = try Fixtures.isolated("quadrants.jpg", in: "fidelity-jxl")
        let jxl = try Conversions.convert(jpg, to: .jxl)[0]
        check(Files.size(jxl) < Files.size(jpg), "the JXL is smaller: \(Files.size(jxl)) vs \(Files.size(jpg))")
        let restored = jxl.deletingLastPathComponent().appendingPathComponent("restored.jpg")
        _ = try runProcess(djxl, [jxl.path, restored.path, "--quiet"])
        check(Files.sha(restored) == Files.sha(jpg), "djxl gives back the original JPEG exactly")
        let gif = try Fixtures.isolated("animated.gif", in: "fidelity-jxl-anim")
        check(Files.size(try Conversions.convert(gif, to: .jxl)[0]) > 0, "an animation becomes an animated JXL")
        // macOS 13 can't read JPEG XL; djxl stands in for it.
        let source = try ImageConverter.decodeJXL(jxl)
        let image = try ImageConverter.orientedImage(source)
        check(image.width == 600 && image.height == 400, "decoded with djxl: \(image.width)×\(image.height)")
        let back = try Conversions.convert(jxl, to: .png)[0]
        check(try requireInfo(back).width == 600, "JXL → PNG")
    }

    test("Fidelity", "Audio: cover art, tags, channels and bit depth") {
        let dir = try folder("audio")
        let cover = dir.appendingPathComponent("cover.png")
        try Fixtures.write(Fixtures.quadrants(300, 300), "_fidelity-audio-cover.png", type: "public.png")
        try? FileManager.default.removeItem(at: cover)
        try FileManager.default.moveItem(at: Fixtures.url("_fidelity-audio-cover.png"), to: cover)
        let mp3 = dir.appendingPathComponent("song.mp3")
        try ffmpeg(["-i", Fixtures.url("tone.wav").path, "-i", cover.path, "-map", "0:a", "-map", "1:v", "-c:a", "libmp3lame", "-c:v", "png",
                    "-disposition:v", "attached_pic", "-id3v2_version", "3", "-metadata", "title=Song", mp3.path])
        for target in [Format.m4a, .flac, .aiff] {
            let out = try Conversions.convert(mp3, to: target)[0]
            let covers = Probe.streams(out).filter { (($0["disposition"] as? [String: Any])?["attached_pic"] as? Int) == 1 }
            check(covers.count == 1, "\(target.label) keeps the cover")
            check((Probe.tags(out)["title"] ?? Probe.tags(out)["TITLE"]) as? String == "Song", "\(target.label) keeps the title: \(Probe.tags(out))")
        }
        let (_, oggNotes) = try Fidelity.collect { try Conversions.convert(mp3, to: .ogg) }
        check(oggNotes.contains { $0.contains("cover") }, "OGG says the cover is left out: \(oggNotes)")

        let surround = dir.appendingPathComponent("surround.wav")
        try ffmpeg(["-f", "lavfi", "-i", "sine=frequency=300:duration=1", "-af", "pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0", surround.path])
        let (stereo, surroundNotes) = try Fidelity.collect { try Conversions.convert(surround, to: .mp3)[0] }
        check(Probe.channels(stereo) == 2 && surroundNotes.contains { $0.contains("stereo") }, "5.1 → MP3 is mixed to stereo and says so")
        check(Probe.channels(try Conversions.convert(surround, to: .flac)[0]) == 6, "FLAC keeps the 6 channels")

        let deep = dir.appendingPathComponent("deep.flac")
        try ffmpeg(["-f", "lavfi", "-i", "sine=frequency=500:duration=1", "-c:a", "flac", "-sample_fmt", "s32", "-bits_per_raw_sample", "24", deep.path])
        let wav = try Conversions.convert(deep, to: .wav)[0]
        let codec = Probe.codecs(wav, type: "audio").first ?? ""
        check(codec == "pcm_s24le" || codec == "pcm_s32le", "24-bit FLAC → WAV keeps the depth: \(codec)")
    }

    test("Fidelity", "Video: every audio track, subtitles and chapters, or a note") {
        let dir = try folder("video")
        let srt = dir.appendingPathComponent("subs.srt")
        try FileManager.default.copyItem(at: Fixtures.url("subs.srt"), to: srt)
        let chapters = dir.appendingPathComponent("chapters.txt")
        try ";FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=1000\ntitle=One\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=1000\nEND=2000\ntitle=Two\n"
            .write(to: chapters, atomically: true, encoding: .utf8)
        let mkv = dir.appendingPathComponent("movie.mkv")
        try ffmpeg(["-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=2", "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
                    "-f", "lavfi", "-i", "sine=frequency=880:duration=2", "-i", srt.path, "-i", chapters.path,
                    "-map", "0", "-map", "1", "-map", "2", "-map", "3", "-map_metadata", "4", "-map_chapters", "4",
                    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-c:s", "srt", "-shortest", mkv.path])
        let (mp4, mp4Notes) = try Fidelity.collect { try Conversions.convert(mkv, to: .mp4)[0] }
        check(Probe.codecs(mp4, type: "audio").count == 2, "MP4 keeps both audio tracks: \(Probe.codecs(mp4, type: "audio"))")
        check(Probe.codecs(mp4, type: "subtitle") == ["mov_text"], "MP4 keeps the subtitles as mov_text: \(Probe.codecs(mp4, type: "subtitle"))")
        check(Probe.chapters(mp4) == 2 && mp4Notes.isEmpty, "MP4 keeps both chapters, nothing to report: \(mp4Notes)")
        let webm = try Conversions.convert(mkv, to: .webm)[0]
        check(Probe.codecs(webm, type: "subtitle") == ["webvtt"] && Probe.codecs(webm, type: "audio").count == 2, "WebM: WebVTT and both tracks")
        let (_, aviNotes) = try Fidelity.collect { try Conversions.convert(mkv, to: .avi) }
        check(aviNotes.contains { $0.contains("subtitle") } && aviNotes.contains { $0.contains("chapter") }, "AVI says what it can’t keep: \(aviNotes)")
        let (_, audioNotes) = try Fidelity.collect { try Conversions.convert(mkv, to: .mp3) }
        check(audioNotes.contains { $0.contains("audio track") }, "MP3 says only one track was kept: \(audioNotes)")
    }

    test("Fidelity", "Documents keep pictures, links and tables, or say they can’t") {
        let dir = try folder("documents")
        let picture = NSTextAttachment(fileWrapper: FileWrapper(regularFileWithContents: try Data(contentsOf: Fixtures.url("quadrants.png"))))
        picture.fileWrapper?.preferredFilename = "picture.png"
        let text = NSMutableAttributedString(string: "Hello Split — café.\n")
        text.append(NSAttributedString(string: "A link", attributes: [.link: URL(string: "https://example.com/page")!]))
        text.append(NSAttributedString(string: "\n"))
        text.append(NSAttributedString(attachment: picture))
        text.append(NSAttributedString(string: "\nThe end.\n"))
        let rtfd = dir.appendingPathComponent("notes.rtfd")
        try? FileManager.default.removeItem(at: rtfd)
        try DocumentPipeline.save(text, as: .rtfd, to: rtfd)

        let docx = try Conversions.convert(rtfd, to: .docx)[0]
        let listing = try runProcess("/usr/bin/unzip", ["-Z1", docx.path]).stdout
        check(listing.contains("word/media/"), "DOCX keeps the picture: \(listing)")
        let xml = try runProcess("/usr/bin/unzip", ["-p", docx.path, "word/document.xml"]).stdout
        check(xml.contains("<w:hyperlink") && xml.contains("<w:drawing>"), "DOCX keeps the link and draws the picture")
        let rels = try runProcess("/usr/bin/unzip", ["-p", docx.path, "word/_rels/document.xml.rels"]).stdout
        check(rels.contains("https://example.com/page"), "the link points where it did")

        let (_, odtNotes) = try Fidelity.collect { try Conversions.convert(rtfd, to: .odt) }
        check(odtNotes.contains { $0.contains("can’t hold pictures") }, "ODT says the picture is left out: \(odtNotes)")
        let (_, txtNotes) = try Fidelity.collect { try Conversions.convert(rtfd, to: .txt) }
        check(txtNotes.contains { $0.contains("only text") }, "TXT says the picture is left out: \(txtNotes)")
        let html = Files.text(try Conversions.convert(rtfd, to: .html)[0])
        check(html.contains("data:image/") && !html.contains("file://"), "HTML embeds the picture instead of a broken file:// link")
        let epub = try Conversions.convert(rtfd, to: .epub)[0]
        check(try runProcess("/usr/bin/unzip", ["-Z1", epub.path]).stdout.contains("OEBPS/images/"), "EPUB packs the picture")

        let table = try Hostile.file("table.html", in: "fidelity-documents", "<table><tr><th>Month</th><th>Value</th></tr><tr><td>March</td><td>42</td></tr></table>")
        let tableDocx = try Conversions.convert(table, to: .docx)[0]
        check(try runProcess("/usr/bin/unzip", ["-p", tableDocx.path, "word/document.xml"]).stdout.contains("<w:tbl>"), "DOCX keeps the table")
        let (_, pdfNotes) = try Fidelity.collect { try Conversions.convert(Fixtures.isolated("report.pdf", in: "fidelity-pdf"), to: .docx) }
        check(pdfNotes.contains { $0.contains("only the text") }, "PDF → DOCX says only the text comes across: \(pdfNotes)")
    }

    test("Fidelity", "Spreadsheets: formulas and sheets") {
        let sales = try Fixtures.isolated("sales.xlsx", in: "fidelity-sheets")
        let (csv, notes) = try Fidelity.collect { try Conversions.convert(sales, to: .csv) }
        check(csv.count == 2 && notes.contains { $0.contains("one sheet per file") }, "two sheets → two CSV files, and it says so: \(csv.map(\.lastPathComponent)) \(notes)")
        let prices = try Fixtures.isolated("prices.csv", in: "fidelity-formulas")
        let xlsx = try Conversions.convert(prices, to: .xlsx)[0]
        let (_, formulaNotes) = try Fidelity.collect { try Conversions.convert(xlsx, to: .tsv) }
        check(formulaNotes.contains { $0.contains("formulas") }, "XLSX → TSV says the formulas became values: \(formulaNotes)")
    }

    test("Fidelity", "Finder aliases and symbolic links are followed to the real file") {
        let dir = try folder("aliases")
        let target = dir.appendingPathComponent("real.png")
        if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: Fixtures.url("quadrants.png"), to: target) }
        let link = dir.appendingPathComponent("link.png")
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let alias = dir.appendingPathComponent("real.png alias")
        try? FileManager.default.removeItem(at: alias)
        try URL.writeBookmarkData(try target.bookmarkData(options: .suitableForBookmarkFile), to: alias)
        check(Intake.resolve(link) == target.standardizedFileURL, "a symbolic link → \(Intake.resolve(link).path)")
        check(Intake.resolve(alias) == target.standardizedFileURL, "a Finder alias → \(Intake.resolve(alias).path)")
        check(Intake.resolve([link, alias, target]) == [target.standardizedFileURL], "the same file reached three ways is handled once")
        let dangling = dir.appendingPathComponent("dangling.png")
        try? FileManager.default.removeItem(at: dangling)
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: dir.appendingPathComponent("gone.png"))
        check(Intake.resolve(dangling) == dangling.standardizedFileURL, "a dangling link stays, so the missing file is explained")
        let outputs = try Conversions.convert(Intake.resolve(alias), to: .jpg)
        check(outputs.first?.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL && outputs.first?.lastPathComponent == "real.jpg",
              "the result is made from the real file, next to it: \(outputs)")
    }

    test("Fidelity", "Text from Windows and classic Mac apps keeps its accents") {
        let dir = try folder("encodings")
        let samples: [(String, Data, String)] = [
            ("windows.txt", Data([0x43, 0x61, 0x66, 0xE9, 0x20, 0x96, 0x20, 0x63, 0x6F, 0x72, 0x61, 0xE7, 0xE3, 0x6F]), "Café – coração"),
            ("mac.txt", Data([0x43, 0x61, 0x66, 0x8E, 0x20, 0x63, 0x6F, 0x72, 0x61, 0x8D, 0x8B, 0x6F]), "Café coração"),
            ("utf16.txt", "Café ação".data(using: .utf16LittleEndian)!, "Café ação"),
            ("utf16-bom.txt", Data([0xFF, 0xFE]) + "Café ação".data(using: .utf16LittleEndian)!, "Café ação"),
            ("utf8-bom.txt", Data([0xEF, 0xBB, 0xBF]) + Data("Café ação".utf8), "Café ação"),
        ]
        for (name, data, expected) in samples {
            let file = dir.appendingPathComponent(name)
            try data.write(to: file)
            let read = try DocumentPipeline.readText(file)
            check(read == expected, "\(name): “\(read)” instead of “\(expected)”")
        }
        let srt = dir.appendingPathComponent("windows.srt")
        try (Data("1\r\n00:00:01,000 --> 00:00:02,000\r\n".utf8) + Data([0x4F, 0x6C, 0xE1, 0x20, 0x63, 0x61, 0x66, 0xE9]) + Data("\r\n".utf8)).write(to: srt)
        let vtt = Files.text(try Conversions.convert(srt, to: .vtt)[0])
        check(vtt.contains("Olá café"), "a Windows-1252 subtitle keeps its accents: \(vtt)")
        let json = dir.appendingPathComponent("latin.json")
        try Data([0x7B, 0x22, 0x61, 0x22, 0x3A, 0x22, 0xE9, 0x22, 0x7D]).write(to: json)
        check(try JSONConverter.read(json) == .object([("a", .string("é"))]), "JSON saved as Windows-1252 still reads")
    }

    test("Fidelity", "Pictures saved by browsers and social sites are recognized") {
        let dir = try folder("browser-names")
        for name in ["photo.jfif", "photo.jpg_large", "photo.jpeg_large", "photo.jpg_orig"] {
            let file = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: file.path) { try FileManager.default.copyItem(at: Fixtures.url("quadrants.jpg"), to: file) }
            check(Format.detect(file) == .jpg, "\(name) is a JPEG")
        }
        let png = dir.appendingPathComponent("graphic.png_large")
        if !FileManager.default.fileExists(atPath: png.path) { try FileManager.default.copyItem(at: Fixtures.url("quadrants.png"), to: png) }
        check(Format.detect(png) == .png, "png_large is a PNG")
        check(try requireInfo(try Conversions.convert(dir.appendingPathComponent("photo.jpg_large"), to: .webp)[0]).width == 600, "and converts")
    }
}
