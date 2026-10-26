import AppKit

/// Every failure must say what went wrong, why, and what to do.
func registerErrorTests() {
    test("Errors", "Missing file, empty file, folder, unknown type") {
        expectError("a file that doesn’t exist", contains: ["no longer where it was", "Drag it again"]) {
            _ = try Conversions.convert(Fixtures.url("does-not-exist.png"), to: .jpg)
        }
        expectError("an empty file", contains: ["empty (0 bytes)"]) { _ = try Conversions.convert(Fixtures.url("empty.txt"), to: .pdf) }
        expectError("a folder", contains: ["is a folder", "Create ZIP"]) { _ = try Conversions.convert(Fixtures.url("A folder"), to: .zip) }
        expectError("an unknown extension", contains: ["doesn’t recognize", ".xyz"]) { _ = try Conversions.convert(Fixtures.url("mystery.xyz"), to: .pdf) }
        expectError("an impossible target", contains: ["doesn’t convert JPG to MP3", "it can make"]) {
            _ = try Conversions.convert(Fixtures.url("quadrants.jpg"), to: .mp3)
        }
    }

    test("Errors", "A folder without write permission") {
        let folder = Fixtures.root.appendingPathComponent("_readonly")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("photo.jpg")
        if !FileManager.default.fileExists(atPath: file.path) { try FileManager.default.copyItem(at: Fixtures.url("quadrants.jpg"), to: file) }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        expectError("a read-only folder", contains: ["isn’t allowed to save", "Downloads"]) { _ = try Conversions.convert(file, to: .png) }
    }

    test("Errors", "Content that doesn’t match the extension") {
        let mismatch = FileCheck.mismatch(Fixtures.url("fake.png"))
        check(mismatch?.contains("its content is JPEG") == true, "fake.png: \(mismatch ?? "nil")")
        check(mismatch?.contains("Change the extension to .jpg") == true, "it should suggest .jpg")
        check(FileCheck.mismatch(Fixtures.url("quadrants.jpg")) == nil, "a real JPG is fine")
        expectError("a web page saved as .jpg", contains: ["HTML", "web page"]) { _ = try Conversions.convert(Fixtures.url("page.jpg"), to: .png) }
    }

    test("Errors", "The real content is recognized (signatures)") {
        let expected: [String: String] = [
            "quadrants.png": "PNG", "quadrants.jpg": "JPEG", "animated.gif": "GIF", "report.pdf": "PDF", "quadrants.webp": "WebP",
            "tone.wav": "WAV", "clip.mp4": "MP4", "letter.docx": "ZIP", "clip.mkv": "MKV/WebM", "clip.webm": "MKV/WebM",
            "tone.flac": "FLAC", "tone.ogg": "OGG", "tone.mp3": "MP3", "quadrants.tiff": "TIFF", "quadrants.bmp": "BMP",
            "icon.ico": "ICO", "letter.rtf": "RTF", "page.html": "HTML", "drawing.svg": "SVG", "quadrants.heic": "HEIC",
            "clip.avi": "AVI", "tone.aiff": "AIFF", "clip.wmv": "WMA/WMV", "folder.tar.gz": "GZIP", "clip.mov": "MOV",
            "letter.doc": "DOC/XLS/PPT",
        ]
        for (name, type) in expected {
            check(FileCheck.sniff(Fixtures.url(name)) == type, "\(name): \(FileCheck.sniff(Fixtures.url(name)) ?? "nil") instead of \(type)")
        }
    }

    test("Errors", "Damaged or protected files") {
        expectError("a password-protected PDF", contains: ["password", "Export as PDF"]) { _ = try Conversions.convert(Fixtures.url("locked.pdf"), to: .txt) }
        let corrupt = try Fixtures.isolated("corrupt.zip", in: "corrupt")
        expectError("a damaged ZIP", contains: ["damaged"]) { _ = try ArchiveTools.extract(corrupt) }
        let broken = try Fixtures.isolated("broken.mp4", in: "broken")
        expectError("a video cut off halfway", contains: ["incomplete"]) { _ = try Conversions.convert(broken, to: .mp3) }
        let silent = try Fixtures.isolated("silent.mp4", in: "silent")
        expectError("a silent video to MP3", contains: ["has no sound"]) { _ = try Conversions.convert(silent, to: .mp3) }
        expectError("normalizing without sound", contains: ["has no sound"]) { _ = try Tools.normalize(silent) }
    }

    test("Errors", "Engine failures are explained in plain words") {
        func explain(_ stderr: String, app: String = "") -> String {
            Explain.toolFailure(what: "The conversion", tool: "ffmpeg", stderr: stderr, status: 1, app: app).fullText
        }
        check(explain("[mov,mp4] moov atom not found\nInvalid data").contains("incomplete"), "moov atom")
        check(explain("x.mp4: Permission denied").contains("blocked access"), "permission")
        check(explain("Unknown encoder 'libfdk_aac'").contains("brew reinstall ffmpeg"), "missing encoder")
        check(explain("Could not find tag for codec pcm_s16le in stream #1, codec not currently supported in container").contains("MP4 or MKV"), "codec/container")
        check(explain("No space left on device").contains("disk is full"), "full disk")
        let automation = explain("execution error: Not authorized to send Apple events to Microsoft PowerPoint. (-1743)", app: "PowerPoint")
        check(automation.contains("Automation") && automation.contains("PowerPoint"), "automation: \(automation)")
        check(explain("execution error: AppleEvent timed out. (-1712)", app: "Word").contains("didn’t respond"), "timeout")
        let unknown = Explain.toolFailure(what: "The conversion", tool: "ffmpeg", stderr: "line 1\nsomething odd happened", status: 1)
        check(unknown.message.contains("something odd happened") && unknown.technical?.contains("code 1") == true, "an unknown error keeps its detail")
    }

    test("Errors", "System errors (Cocoa/POSIX) are explained") {
        let file = URL(fileURLWithPath: "/tmp/x.pdf")
        check(Explain.error(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError), file: file).message.contains("disk filled up"), "no space")
        check(Explain.error(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError), file: file).message.contains("blocked access to “x.pdf”"), "permission")
        check(Explain.error(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)), file: file).message.contains("no longer where it was"), "ENOENT")
        check(Explain.error(NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError), file: file).message.contains("damaged"), "corrupt")
        check(Explain.error(NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError), file: nil).message.contains("the file"), "without a file name")
        let generic = Explain.error(NSError(domain: "Other", code: 7, userInfo: [NSLocalizedDescriptionKey: "X failed"]))
        check(generic.message.contains("X failed") && generic.technical?.contains("Other 7") == true, "a generic error keeps its detail")
    }

    test("Errors", "Why a wheel has no options") {
        let mixed = Explain.noTargets([Fixtures.url("quadrants.jpg"), Fixtures.url("clip.mp4")], tools: false).message
        check(mixed.contains("different kinds") && mixed.contains("images") && mixed.contains("video"), "mixed kinds: \(mixed)")
        check(Explain.noTargets([Fixtures.url("A folder")], tools: false).message.contains("can’t be converted"), "folder")
        check(Explain.noTargets([Fixtures.url("mystery.xyz")], tools: false).message.contains(".xyz"), "extension")
        check(Explain.noTargets([URL(fileURLWithPath: "/tmp/a.pptx")], tools: false).message.contains("PowerPoint"), "a presentation without an app")
        check(Explain.noTargets([URL(fileURLWithPath: "/tmp/a.numbers")], tools: false).message.contains("Numbers"), "a spreadsheet without an app")
        let tools = Explain.noTargets([Fixtures.url("notes.txt")], tools: true)
        check(tools.message.contains("No tool applies") && tools.suggestion != nil, "tools")
    }

    test("Errors", "A missing engine gives the install command") {
        expectError("a missing program", contains: ["isn’t installed", "brew install package-x"]) {
            _ = try Engines.require("program-that-doesnt-exist", brew: "package-x")
        }
    }

    test("Errors", "Every message seen in these tests explains itself") {
        for error in ErrorLog.seen {
            check(!error.message.contains("Error Domain="), "raw system message: \(error.message)")
            check(error.fullText.count >= 25, "message too short: \(error.fullText)")
            check(!error.message.lowercased().contains("the operation couldn"), "raw Cocoa message: \(error.message)")
        }
        check(ErrorLog.seen.count >= 15, "too few errors checked (\(ErrorLog.seen.count))")
    }
}
