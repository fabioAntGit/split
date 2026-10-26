import AppKit
import PDFKit

func registerToolTests() {
    test("Tools", "Compress: a large image gets smaller, an optimized one is explained") {
        let photo = try Fixtures.isolated("photo.jpg", in: "compress-photo")
        let out = try Tools.compress(photo)
        check(Files.size(out) < Files.size(photo), "\(Files.size(out)) ≥ \(Files.size(photo))")
        check(max(Pixels.info(out)?.width ?? 0, Pixels.info(out)?.height ?? 0) <= 2560, "it should limit to 2560 px")
        let small = try Fixtures.isolated("icon.ico", in: "compress-small")
        do {
            let result = try Tools.compress(small)
            check(Files.size(result) < Files.size(small), "the compressed copy is larger than the original")
        } catch {
            check(Explain.error(error).message.contains("already well compressed"), "message: \(Explain.error(error).message)")
        }
    }

    test("Tools", "Compress video, audio and PDF: smaller or explained") {
        for name in ["clip.mov", "tone.wav", "report.pdf"] {
            let source = try Fixtures.isolated(name, in: "compress-\(name)")
            do {
                let out = try Tools.compress(source)
                check(Files.size(out) < Files.size(source), "\(name): the compressed copy isn’t smaller")
            } catch {
                let message = Explain.error(error).message
                check(message.contains("already well compressed"), "\(name): \(message)")
            }
        }
    }

    test("Tools", "Remove metadata: GPS, title and author go; the orientation stays") {
        let jpg = try Fixtures.isolated("quadrants.jpg", in: "strip")
        let clean = try Tools.stripMetadata(jpg)
        let info = try requireInfo(clean)
        check(info.properties[kCGImagePropertyGPSDictionary] == nil, "the GPS stayed")
        let rotated = try Fixtures.isolated("rotated.jpg", in: "strip-rotated")
        check((try requireInfo(try Tools.stripMetadata(rotated)).properties[kCGImagePropertyOrientation] as? Int) == 6, "the orientation should stay")
        let mp3 = try Fixtures.isolated("tone.mp3", in: "strip-audio")
        let tags = Probe.tags(try Tools.stripMetadata(mp3))
        check(tags["title"] == nil && tags["artist"] == nil, "tags in the MP3: \(tags)")
        let pdf = try Fixtures.isolated("report.pdf", in: "strip-pdf")
        let attributes = PDFDocument(url: try Tools.stripMetadata(pdf))?.documentAttributes ?? [:]
        check(attributes[PDFDocumentAttribute.authorAttribute] == nil, "the author stayed in the PDF")
    }

    test("Tools", "Remove background: a PNG transparent around the subject, or an explanation") {
        guard Tools.canRemoveBackground else { return }
        let source = try Fixtures.isolated("subject.png", in: "remove-bg")
        do {
            let out = try Tools.removeBackground(source)
            let image = try require(Pixels.load(out), "unreadable PNG")
            check(Pixels.at(image, 5, 5)[3] == 0, "the corner should be transparent")
            check(Pixels.at(image, 300, 300)[3] > 200, "the centre (the subject) should be opaque")
        } catch {
            check(Explain.error(error).message.contains("main subject"), "unexpected error: \(Explain.error(error).fullText)")
        }
    }

    test("Tools", "Combine and split PDFs") {
        let report = try Fixtures.isolated("report.pdf", in: "merge")
        let scanned = try Fixtures.isolated("scanned.pdf", in: "merge")
        let image = try Fixtures.isolated("quadrants.png", in: "merge")
        let merged = try Tools.combinePDF([report, scanned, image])
        check(PDFDocument(url: merged)?.pageCount == 5, "3 + 1 + 1 pages → \(PDFDocument(url: merged)?.pageCount ?? 0)")
        let folder = try Tools.splitPages(report)
        check(Files.list(folder).count == 3, "split: \(Files.list(folder).count) files")
        check(Files.list(folder).allSatisfy { PDFDocument(url: $0)?.pageCount == 1 }, "each part should have 1 page")
    }

    test("Tools", "Extract and create a ZIP") {
        let zip = try Fixtures.isolated("folder.zip", in: "extract")
        let extracted = try ArchiveTools.extract(zip)
        check(extracted.count == 1 && extracted[0].lastPathComponent == "Folder", "a single folder comes out as it is: \(extracted)")
        check(Files.list(extracted[0]).count == 2, "the folder should hold 2 files")
        let two = try Fixtures.isolated("two.zip", in: "extract-two")
        let loose = try ArchiveTools.extract(two)
        check(loose.count == 1 && Files.list(loose[0]).count == 2, "loose files go into a new folder")
        let packed = try Tools.zip(Files.list(extracted[0]))
        let listing = try runProcess("/usr/bin/unzip", ["-l", packed.path]).stdout
        check(listing.contains("one.txt") && listing.contains("two.txt"), "ZIP: \(listing)")
    }

    test("Tools", "Normalize the volume to −16 LUFS") {
        let source = try Fixtures.isolated("tone.wav", in: "normalize")
        let before = Probe.loudness(source) ?? 0
        let out = try Tools.normalize(source)
        let after = try require(Probe.loudness(out), "no loudness measurement")
        check(near(after, -16, 2), "loudness \(after) LUFS (before \(before))")
    }

    test("Tools", "Mono, trim silence, remove audio") {
        let wav = try Fixtures.isolated("tone.wav", in: "mono")
        check(Probe.channels(try Tools.mono(wav)) == 1, "a mono WAV should have 1 channel")
        let ogg = try Fixtures.isolated("tone.ogg", in: "mono-ogg")
        check(!Probe.codecs(try Tools.mono(ogg), type: "audio").isEmpty, "mono OGG failed")
        let mp4 = try Fixtures.isolated("clip.mp4", in: "mono-video")
        let monoVideo = try Tools.mono(mp4)
        check(Probe.channels(monoVideo) == 1 && Probe.codecs(monoVideo, type: "video") == ["h264"], "a mono video should keep the picture")

        let trimmed = try Tools.trimSilence(try Fixtures.isolated("tone.wav", in: "silence"))
        check(near(Probe.duration(trimmed), 2, 0.2), "3 s with 1 s of silence → \(Probe.duration(trimmed)) s")
        let flac = try Fixtures.isolated("tone.flac", in: "silence-twice")
        let once = try Tools.trimSilence(flac)
        expectError("trimming silence where there is none", contains: ["has no silence"]) { _ = try Tools.trimSilence(once) }

        let muted = try Tools.mute(try Fixtures.isolated("clip.mp4", in: "mute"))
        check(Probe.codecs(muted, type: "audio").isEmpty && !Probe.codecs(muted, type: "video").isEmpty, "no audio, with the picture")
    }

    test("Tools", "Join videos (one silent), frames, audio to video") {
        let a = try Fixtures.isolated("clip.mp4", in: "join")
        let b = try Fixtures.isolated("silent.mp4", in: "join")
        let joined = try Tools.concatVideos([a, b])
        check(near(Probe.duration(joined), 4, 0.3), "2 s + 2 s → \(Probe.duration(joined))")
        check(!Probe.codecs(joined, type: "audio").isEmpty, "the joined video should have sound")

        let folder = try Tools.snapshots(try Fixtures.isolated("clip.mp4", in: "snapshots"))
        let frames = Files.list(folder)
        check(frames.count == 12, "12 frames → \(frames.count)")
        check(frames.allSatisfy { Pixels.info($0)?.width == 320 }, "frames at 320 px")

        let video = try Tools.waveformVideo(try Fixtures.isolated("tone.mp3", in: "waves"))
        check(Probe.codecs(video, type: "video") == ["h264"] && Probe.codecs(video, type: "audio") == ["aac"], "MP4 H.264 + AAC")
        check(near(Probe.duration(video), 3, 0.3), "length \(Probe.duration(video))")
        check(Probe.videoSize(video) == CGSize(width: 1280, height: 720), "1280×720")
    }

    test("Tools", "Read a QR code in an image and in a PDF") {
        let png = try Fixtures.isolated("qr.png", in: "qr")
        check(try Tools.readQR(png) == ["https://example.com/split"], "QR in a PNG")
        let pdf = try Tools.combinePDF([png])
        check(try Tools.readQR(pdf) == ["https://example.com/split"], "QR in a PDF")
        expectError("an image without a QR code", contains: ["No QR code"]) { _ = try Tools.readQR(Fixtures.url("quadrants.png")) }
    }

    test("Tools", "Each tool only shows for the right files") {
        let image = [Fixtures.url("quadrants.jpg")]
        let video = [Fixtures.url("clip.mp4")]
        let audio = [Fixtures.url("tone.wav")]
        let pdf = [Fixtures.url("report.pdf")]
        check(QuickTool.available(for: image).contains(.compress) && !QuickTool.available(for: image).contains(.mute), "image")
        check(QuickTool.available(for: video).contains(.mute) && QuickTool.available(for: video).contains(.snapshots), "video")
        check(QuickTool.available(for: audio).contains(.trimSilence) && QuickTool.available(for: audio).contains(.waveformVideo), "audio")
        check(QuickTool.available(for: pdf).contains(.splitPages) && !QuickTool.available(for: pdf).contains(.combinePDF), "a single PDF isn’t combined")
        check(!QuickTool.concatVideos.applies(to: video), "joining needs 2 videos")
        check(EditorTool.available(for: image).contains(.crop) && !EditorTool.available(for: image).contains(.collage), "a collage needs 2 images")
        check(EditorTool.available(for: image + image).contains(.collage), "a collage with 2 images")
        check(EditorTool.available(for: video) == [.media], "a video opens the media editor")
        check(EditorTool.available(for: pdf) == [.pdfPages], "a PDF opens the organizer")
        check(ToolCatalog.items(for: image).first?.title == "Crop", "editors come first on the wheel")
        check(QuickTool.available(for: image).contains(.compressToSize) && !QuickTool.compressToSize.applies(to: pdf), "“Compress To…” is for images, audio and video")
    }

    test("Tools", "Compress To…: sizes are read the way people write them") {
        check(TargetSize.parse("2MB") == 2_000_000 && TargetSize.parse("1,5 MB") == 1_500_000 && TargetSize.parse("800kb") == 800_000, "MB/KB")
        check(TargetSize.parse("2 Mo") == 2_000_000 && TargetSize.parse("750 Ko") == 750_000, "French units")
        check(TargetSize.parse("300000") == 300_000 && TargetSize.parse("abc") == nil && TargetSize.parse("-2 MB") == nil, "plain bytes and nonsense")
        check(TargetSize.plain(25_000_000) == "25 MB" && TargetSize.plain(500_000) == "500 KB" && TargetSize.plain(1_500_000) == "1.5 MB", "field text")
        check(TargetSize.uses.allSatisfy { TargetSize.parse(TargetSize.plain($0.bytes)) == $0.bytes }, "presets read back")
    }

    test("Tools", "Compress To…: images, audio and video fit the size chosen") {
        let photo = try Fixtures.isolated("photo.jpg", in: "target-photo")
        let limit = 150_000
        let (small, _) = try Fidelity.collect { try TargetSize.compress(photo, toFit: limit) }
        check(Files.size(small) <= Int64(limit) && Files.size(small) > Int64(limit) / 3, "JPG: \(Files.size(small)) bytes for \(limit)")
        let png = try Fixtures.isolated("quadrants.png", in: "target-png")
        let (fromPNG, notes) = try Fidelity.collect { try TargetSize.compress(png, toFit: 3_000) }
        check(Files.size(fromPNG) <= 3_000 && Format.detect(fromPNG) == .webp, "a transparent PNG becomes WebP: \(fromPNG.lastPathComponent)")
        check(notes.contains { $0.contains("WebP") }, "the change of format is said: \(notes)")
        let wav = try Fixtures.isolated("tone.wav", in: "target-audio")
        let audio = try TargetSize.compress(wav, toFit: 40_000)
        check(Files.size(audio) <= 40_000 && near(Probe.duration(audio), 3, 0.2), "audio: \(Files.size(audio)) bytes")
        let video = try Fixtures.isolated("long.mp4", in: "target-video")
        let budget = Int(Files.size(video) / 3)
        let smaller = try TargetSize.compress(video, toFit: budget)
        check(Files.size(smaller) <= Int64(budget) && near(Probe.duration(smaller), 12, 0.5), "video: \(Files.size(smaller)) bytes for \(budget)")
        expectError("a file already small enough", contains: ["already", "Nothing was changed"]) { _ = try TargetSize.compress(photo, toFit: 50_000_000) }
    }
}

func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw TestFailure(message) }
    return value
}
