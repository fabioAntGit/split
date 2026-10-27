import AppKit

/// An error the user can act on: what failed and why (`message`), what to do next
/// (`suggestion`) and the raw tool output for the "Details" view (`technical`).
struct Problem: LocalizedError {
    let message: String
    var suggestion: String?
    var technical: String?
    /// The user stopped the job: not a failure, so no error sound and no "Details…".
    var isCancellation = false

    init(_ message: String, suggestion: String? = nil, technical: String? = nil) {
        self.message = message
        self.suggestion = suggestion
        self.technical = technical
    }

    static var cancelled: Problem {
        var problem = Problem(L("Canceled."), suggestion: L("Nothing was saved for this file."))
        problem.isCancellation = true
        return problem
    }

    var errorDescription: String? { message }
    var recoverySuggestion: String? { suggestion }

    /// Message and suggestion as one paragraph (CLI and compact views).
    var fullText: String {
        guard let suggestion, !suggestion.isEmpty else { return message }
        return message + " " + suggestion
    }
}

/// A file that failed, with the explanation shown in "Details…" and in the activity list.
struct JobFailure {
    let file: String
    let error: Problem
}

// MARK: - Checks before a job starts

enum FileCheck {
    /// Problems that would make any job fail, explained before an engine runs.
    static func preflight(_ url: URL, allowFolders: Bool = false, waitForDownload: Bool = true) throws {
        let fm = FileManager.default
        let name = url.lastPathComponent
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw Problem(L("“%@” is no longer where it was.", name),
                          suggestion: L("It was moved, renamed or deleted after you chose it. Drag it again from where it is now."))
        }
        if isDirectory.boolValue && !allowFolders && !isPackage(url) {
            throw Problem(L("“%@” is a folder, not a file.", name),
                          suggestion: L("Folders can’t be converted. To compress one, use “Create ZIP” in the tools wheel."))
        }
        if waitForDownload { try requireLocalCopy(url) }
        guard fm.isReadableFile(atPath: url.path) else {
            throw Problem(L("macOS doesn’t let Split read “%@”.", name), suggestion: privacyHint(for: url))
        }
        if !isDirectory.boolValue && size(url) == 0 {
            throw Problem(L("“%@” is empty (0 bytes): there is nothing to process.", name),
                          suggestion: L("The download or export probably failed. Download or export the file again."))
        }
        let folder = url.deletingLastPathComponent()
        try checkWritable(folder)
        try checkSpace(in: folder, needed: size(url))
    }

    static func isPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }

    static func size(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// iCloud placeholders are downloaded first; nothing can read them otherwise.
    static func requireLocalCopy(_ url: URL) throws {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        func isLocal() -> Bool {
            var fresh = url
            fresh.removeAllCachedResourceValues()
            guard let values = try? fresh.resourceValues(forKeys: keys), values.isUbiquitousItem == true else { return true }
            return values.ubiquitousItemDownloadingStatus == .current
        }
        guard !isLocal() else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            usleep(500_000)
            if isLocal() { return }
        }
        throw Problem(L("“%@” is in iCloud Drive and hasn’t been downloaded to this Mac yet.", url.lastPathComponent),
                      suggestion: L("The download was requested but took more than a minute. Wait until the cloud disappears from its icon in Finder and try again."))
    }

    static func checkWritable(_ folder: URL) throws {
        guard !FileManager.default.isWritableFile(atPath: folder.path) else { return }
        let values = try? folder.resourceValues(forKeys: [.volumeIsReadOnlyKey, .volumeNameKey])
        if values?.volumeIsReadOnly == true {
            throw Problem(L("The folder “%@” is on a read-only disk (%@).", folder.lastPathComponent, values?.volumeName ?? L("external disk")),
                          suggestion: L("Disks formatted as NTFS, CDs and mounted disk images can only be read. Copy the file to the Mac and use the copy."))
        }
        throw Problem(L("Split isn’t allowed to save in the folder “%@”, where the result would go.", folder.lastPathComponent),
                      suggestion: privacyHint(for: folder) + " " + L("Or copy the file to another folder, such as Downloads."))
    }

    static func checkSpace(in folder: URL, needed: Int64) throws {
        guard let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeNameKey]),
              let available = values.volumeAvailableCapacityForImportantUsage, available > 0 else { return }
        let margin: Int64 = 50_000_000
        guard available < needed + margin else { return }
        let formatter = ByteCountFormatter()
        throw Problem(L("There isn’t enough space on “%@”: %@ left, and the result may need about %@.", values.volumeName ?? L("disk"),
                        formatter.string(fromByteCount: available), formatter.string(fromByteCount: needed)),
                      suggestion: L("Free some space (for example, empty the Trash) and try again."))
    }

    /// Where to grant access, depending on the kind of folder macOS is protecting.
    static func privacyHint(for url: URL) -> String {
        let path = url.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let protected = [("Desktop", L("Desktop Folder")), ("Documents", L("Documents Folder")), ("Downloads", L("Downloads Folder"))]
        for (folder, label) in protected where path.hasPrefix("\(home)/\(folder)") {
            return L("macOS protects this folder. Open System Settings › Privacy & Security › Files and Folders and turn on “%@” for Split.", label)
        }
        if path.hasPrefix("/Volumes/") {
            return L("macOS protects external and network disks. Open System Settings › Privacy & Security › Files and Folders and turn on “Removable Volumes” for Split.")
        }
        if path.contains("/Library/Mobile Documents/") || path.contains("/Library/CloudStorage/") {
            return L("macOS protects iCloud Drive and other cloud services. Open System Settings › Privacy & Security › Files and Folders and give Split access.")
        }
        return L("Check in Finder (Get Info › Sharing & Permissions) that you can read and write it, or give Split Full Disk Access in System Settings › Privacy & Security.")
    }

    // MARK: Content sniffing

    /// The real content type, from the first bytes (independent of the extension).
    static func sniff(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let bytes = [UInt8]((try? handle.read(upToCount: 512)) ?? Data())
        guard bytes.count >= 4 else { return nil }
        func has(_ signature: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + signature.count && Array(bytes[offset..<offset + signature.count]) == signature
        }
        func ascii(_ text: String, at offset: Int = 0) -> Bool { has(Array(text.utf8), at: offset) }

        if has([0xFF, 0xD8, 0xFF]) { return "JPEG" }
        if has([0x89, 0x50, 0x4E, 0x47]) { return "PNG" }
        if ascii("GIF8") { return "GIF" }
        if ascii("%PDF") { return "PDF" }
        if ascii("RIFF") && ascii("WEBP", at: 8) { return "WebP" }
        if ascii("RIFF") && ascii("WAVE", at: 8) { return "WAV" }
        if ascii("RIFF") && ascii("AVI ", at: 8) { return "AVI" }
        if ascii("FORM") && (ascii("AIFF", at: 8) || ascii("AIFC", at: 8)) { return "AIFF" }
        if ascii("ftyp", at: 4), bytes.count >= 12 {
            let brand = String(decoding: bytes[8..<12], as: UTF8.self)
            if ["heic", "heix", "hevc", "mif1", "msf1"].contains(brand) { return "HEIC" }
            if brand.hasPrefix("avi") { return "AVIF" }
            if brand.hasPrefix("M4A") || brand.hasPrefix("M4B") { return "M4A" }
            if brand == "qt  " { return "MOV" }
            return "MP4"
        }
        if has([0x50, 0x4B, 0x03, 0x04]) || has([0x50, 0x4B, 0x05, 0x06]) { return "ZIP" }
        if ascii("ID3") { return "MP3" }
        if ascii("fLaC") { return "FLAC" }
        if ascii("OggS") { return "OGG" }
        if has([0x1A, 0x45, 0xDF, 0xA3]) { return "MKV/WebM" }
        if has([0x30, 0x26, 0xB2, 0x75]) { return "WMA/WMV" }
        if has([0x49, 0x49, 0x2A, 0x00]) || has([0x4D, 0x4D, 0x00, 0x2A]) { return "TIFF" }
        if has([0x00, 0x00, 0x01, 0x00]) { return "ICO" }
        if ascii("Rar!") { return "RAR" }
        if has([0x37, 0x7A, 0xBC, 0xAF]) { return "7z" }
        if has([0x1F, 0x8B]) { return "GZIP" }
        if has([0xD0, 0xCF, 0x11, 0xE0]) { return "DOC/XLS/PPT" }
        if ascii("{\\rtf") { return "RTF" }
        if ascii("BM") && bytes.count > 14 { return "BMP" }
        if bytes[0] == 0xFF && bytes[1] & 0xE0 == 0xE0 { return "MP3" }
        let text = String(decoding: bytes, as: UTF8.self).lowercased()
        if text.contains("<!doctype html") || text.contains("<html") { return "HTML" }
        if text.contains("<svg") { return "SVG" }
        return nil
    }

    private static let expected: [Format: Set<String>] = [
        .jpg: ["JPEG"], .png: ["PNG"], .gif: ["GIF"], .webp: ["WebP"], .heic: ["HEIC", "AVIF"], .avif: ["AVIF", "HEIC"],
        .tiff: ["TIFF"], .bmp: ["BMP"], .ico: ["ICO", "PNG"], .svg: ["SVG"], .pdf: ["PDF"],
        .docx: ["ZIP"], .xlsx: ["ZIP"], .pptx: ["ZIP"], .epub: ["ZIP"], .odt: ["ZIP"], .ods: ["ZIP"], .odp: ["ZIP"],
        .pages: ["ZIP"], .numbers: ["ZIP"], .key: ["ZIP"], .zip: ["ZIP"],
        .doc: ["DOC/XLS/PPT", "RTF"], .xls: ["DOC/XLS/PPT"], .ppt: ["DOC/XLS/PPT"],
        .rtf: ["RTF"], .mp3: ["MP3"], .m4a: ["M4A", "MP4"], .wav: ["WAV"], .flac: ["FLAC"], .ogg: ["OGG"], .opus: ["OGG"],
        .aiff: ["AIFF"], .wma: ["WMA/WMV"], .wmv: ["WMA/WMV"], .mp4: ["MP4", "MOV", "M4A"], .m4v: ["MP4", "MOV"],
        .mov: ["MOV", "MP4"], .mkv: ["MKV/WebM"], .webm: ["MKV/WebM"], .avi: ["AVI"],
        .rar: ["RAR"], .sevenZip: ["7z"], .tgz: ["GZIP"],
    ]

    private static let extensionFor: [String: String] = [
        "JPEG": "jpg", "PNG": "png", "GIF": "gif", "PDF": "pdf", "WebP": "webp", "WAV": "wav", "AVI": "avi", "AIFF": "aiff",
        "HEIC": "heic", "AVIF": "avif", "M4A": "m4a", "MOV": "mov", "MP4": "mp4", "ZIP": "zip", "MP3": "mp3", "FLAC": "flac",
        "OGG": "ogg", "MKV/WebM": "mkv", "TIFF": "tiff", "RAR": "rar", "7z": "7z", "RTF": "rtf", "BMP": "bmp", "HTML": "html", "SVG": "svg",
    ]

    /// "The file is called .png but holds a JPEG" — the most common cause of baffling failures.
    static func mismatch(_ url: URL) -> String? {
        guard let format = Format.detect(url), let actual = sniff(url) else { return nil }
        let textFormats: Set<Format> = [.txt, .md, .html, .csv, .tsv, .srt, .vtt]
        if textFormats.contains(format) {
            guard actual != "HTML", actual != "SVG", actual != "RTF" else { return nil }
        } else if let allowed = expected[format], allowed.contains(actual) {
            return nil
        } else if expected[format] == nil {
            return nil
        }
        var text = L("The file has the extension .%@, but its content is %@.", url.pathExtension.lowercased(), actual)
        if actual == "HTML" && !textFormats.contains(format) {
            text += " " + L("You probably saved the web page instead of the file.")
        }
        if let ext = extensionFor[actual], actual != "HTML" {
            text += " " + L("Change the extension to .%@ and try again.", ext)
        }
        return text
    }
}

// MARK: - Turning raw failures into explanations

enum Explain {
    /// Any error → what failed, why, and what to do. Adds the content/extension mismatch when there is one.
    static func error(_ error: Error, file: URL? = nil) -> Problem {
        var result = (error as? Problem) ?? cocoa(error as NSError, file: file)
        if let file, let mismatch = FileCheck.mismatch(file), result.suggestion?.contains(mismatch) != true {
            result.suggestion = L("Likely cause: %@", mismatch.prefix(1).lowercased() + mismatch.dropFirst())
        }
        return result
    }

    /// Foundation/Cocoa errors (file system, text import, printing).
    static func cocoa(_ error: NSError, file: URL?) -> Problem {
        let name = file?.lastPathComponent
        /// The sentence that names the file, or the one that doesn't when there is none.
        func say(_ named: (String) -> String, _ unnamed: String) -> String { name.map(named) ?? unnamed }
        let path = (error.userInfo[NSFilePathErrorKey] as? String).map { URL(fileURLWithPath: $0) } ?? file
        let technical = "\(error.domain) \(error.code): \(error.localizedDescription)"
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        let posix = error.domain == NSPOSIXErrorDomain ? error.code : (underlying?.domain == NSPOSIXErrorDomain ? underlying!.code : nil)
        let missing = say({ L("“%@” is no longer where it was.", $0) }, L("The file is no longer where it was."))
        let blocked = say({ L("macOS blocked access to “%@”.", $0) }, L("macOS blocked access to the file."))
        let privacy = FileCheck.privacyHint(for: path ?? URL(fileURLWithPath: "/"))

        if error.domain == NSCocoaErrorDomain {
            switch error.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return Problem(missing, suggestion: L("It was moved or deleted while it was being processed. Drag it again."), technical: technical)
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return Problem(blocked, suggestion: privacy, technical: technical)
            case NSFileWriteOutOfSpaceError:
                return Problem(L("The disk filled up while working."), suggestion: L("Free some space and try again."), technical: technical)
            case NSFileWriteVolumeReadOnlyError:
                return Problem(say({ L("The disk holding “%@” is read-only.", $0) }, L("The disk is read-only.")),
                               suggestion: L("Copy the file to the Mac and use the copy."), technical: technical)
            case NSFileReadCorruptFileError:
                return Problem(say({ L("macOS couldn’t read “%@”: it is damaged or not in the format its extension says.", $0) },
                                   L("macOS couldn’t read the file: it is damaged or not in the format its extension says.")),
                               suggestion: L("Open it in the app it came from to check it, and export it again."), technical: technical)
            case NSFileReadUnknownStringEncodingError, NSFileReadInapplicableStringEncodingError:
                return Problem(say({ L("The text of “%@” uses a character encoding Split doesn’t recognize.", $0) },
                                   L("The text uses a character encoding Split doesn’t recognize.")),
                               suggestion: L("Open it in TextEdit and save it as UTF-8."), technical: technical)
            case NSFileReadTooLargeError:
                return Problem(say({ L("“%@” is too large to read in one go.", $0) }, L("The file is too large to read in one go.")),
                               suggestion: L("Split it into smaller parts."), technical: technical)
            case NSFileReadUnknownError:
                return Problem(say({ L("The macOS text converter couldn’t open “%@”.", $0) }, L("The macOS text converter couldn’t open the file.")),
                               suggestion: L("It may be damaged, password-protected or from a very old version. Open it in Word or Pages and save it again."),
                               technical: technical)
            default:
                break
            }
        }
        switch posix {
        case Int(ENOSPC):
            return Problem(L("The disk filled up while working."), suggestion: L("Free some space and try again."), technical: technical)
        case Int(EACCES), Int(EPERM):
            return Problem(blocked, suggestion: privacy, technical: technical)
        case Int(EROFS):
            return Problem(L("The disk is read-only."), suggestion: L("Copy the file to the Mac and use the copy."), technical: technical)
        case Int(ENOENT):
            return Problem(missing, suggestion: L("Drag it again from where it is now."), technical: technical)
        default:
            break
        }
        return Problem(L("Couldn’t finish: %@", error.localizedDescription), suggestion: error.localizedRecoverySuggestion, technical: technical)
    }

    private struct Rule {
        let patterns: [String]
        /// Why it failed, given the app involved (empty when none).
        let reason: (String) -> String
        let suggestion: () -> String
    }

    // Ordered: the first match explains the failure. Patterns match engine output, which is in English.
    private static let rules: [Rule] = [
        Rule(patterns: ["no space left on device"], reason: { _ in L("the disk is full") },
             suggestion: { L("Free some space (for example, empty the Trash) and try again.") }),
        Rule(patterns: ["operation not permitted", "permission denied", "not authorized to access"],
             reason: { _ in L("macOS blocked access to the file or folder") },
             suggestion: { L("Give Split access in System Settings › Privacy & Security › Files and Folders, or copy the file to another folder.") }),
        Rule(patterns: ["no such file or directory", "file wasn’t found", "file wasn't found", "(-43)"],
             reason: { _ in L("the file is no longer where it was (moved, deleted, or its disk was disconnected)") },
             suggestion: { L("Drag it again from where it is now.") }),
        Rule(patterns: ["not authorized to send apple events", "(-1743)", "não tem autorização para enviar"],
             reason: { app in app.isEmpty ? L("macOS didn’t allow Split to control the app it needs") : L("macOS didn’t allow Split to control %@", app) },
             suggestion: { L("Open System Settings › Privacy & Security › Automation, find Split and turn on the app in question. Then try again.") }),
        Rule(patterns: ["apple event timed out", "(-1712)"],
             reason: { app in app.isEmpty ? L("the app didn’t respond in time") : L("%@ didn’t respond in time", app) },
             suggestion: { L("There is usually a window waiting for an answer (for example, asking to convert or update the document). Open the app, close that dialog and try again.") }),
        Rule(patterns: ["application isn’t running", "application isn't running", "(-600)", "connection is invalid", "(-609)"],
             reason: { app in app.isEmpty ? L("the app quit or froze during the export") : L("%@ quit or froze during the export", app) },
             suggestion: { L("Open the app yourself, check that the document opens without errors and try again.") }),
        Rule(patterns: ["(-10004)", "(-10000)", "privilege violation", "sandbox"],
             reason: { app in app.isEmpty ? L("the app isn’t allowed to save the result") : L("%@ isn’t allowed to save the result", app) },
             suggestion: { L("Open the app once, give it access to files when macOS asks, and try again.") }),
        Rule(patterns: ["password", "encrypted", "passphrase", "is protected"],
             reason: { _ in L("the file is password-protected") },
             suggestion: { L("Remove the password in the app it came from (or use The Unarchiver or Keka for archives) and try again.") }),
        Rule(patterns: ["path contains '..'", "cannot extract through symlink", "illegal path", "path is absolute"],
             reason: { _ in L("the archive tries to write files outside the destination folder (a trick used by malicious archives), so the extraction was blocked") },
             suggestion: { L("Don’t open this archive unless you trust whoever sent it. If you do, ask them to create it again.") }),
        Rule(patterns: ["moov atom not found"],
             reason: { _ in L("the video is incomplete: the recording was interrupted or the download didn’t finish") },
             suggestion: { L("Download or copy the video again. If it comes from a recording that stopped halfway, it may not be recoverable.") }),
        Rule(patterns: ["unknown encoder", "encoder not found", "unrecognized option"],
             reason: { _ in L("the installed ffmpeg doesn’t have the encoder it needs") },
             suggestion: { L("Reinstall the full ffmpeg with: brew reinstall ffmpeg") }),
        Rule(patterns: ["could not find tag for codec", "not currently supported in container", "codec not currently supported"],
             reason: { _ in L("the target format doesn’t accept this file’s codec") },
             suggestion: { L("Choose MP4 or MKV, which accept almost every codec.") }),
        Rule(patterns: ["does not contain any stream", "matches no streams", "output file is empty", "stream specifier"],
             reason: { _ in L("the file doesn’t have the track it needs (for example, a video without sound or audio without a picture)") },
             suggestion: { L("Check in QuickTime that the file has the track you want to use.") }),
        Rule(patterns: ["decoder (codec", "unsupported codec", "no decoder", "could not find codec parameters", "unknown codec"],
             reason: { _ in L("the file uses a codec ffmpeg can’t read") },
             suggestion: { L("It may come from a camera or app with its own format. Export it to MP4 (H.264) in that app first.") }),
        Rule(patterns: ["invalid data found when processing input", "end of file", "invalid nal", "error while decoding", "corrupt",
                        "truncated", "damaged", "unexpected end", "not a valid", "file format error", "end-of-central-directory",
                        "unrecognized archive format", "couldn't read pkzip", "bad zipfile", "zipfile is empty", "could not process file", "unsupported image format", "unsupported color conversion"],
             reason: { _ in L("the file is damaged, incomplete or not the type its extension says") },
             suggestion: { L("Open it in its usual app to check it. If it came from the Internet, download it again.") }),
        Rule(patterns: ["not divisible by 2"],
             reason: { _ in L("the video has odd dimensions and the encoder needs even ones") },
             suggestion: { L("Crop 1 pixel off in the video editor (Crop) and try again.") }),
        Rule(patterns: ["cannot allocate memory", "out of memory", "killed: 9"],
             reason: { _ in L("the Mac ran out of memory") },
             suggestion: { L("Close other apps or process fewer files at a time.") }),
    ]

    /// A command-line engine failed: map its stderr to a reason the user understands.
    /// `what` names the work as the subject of a sentence ("Converting to WebP").
    static func toolFailure(what: String, tool: String, stderr: String, status: Int32, app: String = "") -> Problem {
        let lines = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let technical = ([L("%@ ended with code %@", tool, String(status))] + lines.suffix(8)).joined(separator: "\n")
        let lower = stderr.lowercased()
        if let rule = rules.first(where: { rule in rule.patterns.contains { lower.contains($0) } }) {
            return Problem(L("%@ failed: %@.", what, rule.reason(app)), suggestion: rule.suggestion(), technical: technical)
        }
        if status == 9 || status == 15 || status == 137 {
            return Problem(L("%@ was stopped by the system.", what), suggestion: L("It may have run out of memory. Close other apps and try again."), technical: technical)
        }
        let message = lines.last.map { L("%@ failed: %@", what, String($0.prefix(160))) } ?? L("%@ failed.", what)
        return Problem(message, suggestion: L("Try another target format. If it happens again, look at the technical details."), technical: technical)
    }

    /// Why a wheel would be empty for these files.
    static func noTargets(_ urls: [URL], tools: Bool) -> Problem {
        let folders = urls.filter { $0.hasDirectoryPath && !FileCheck.isPackage($0) }
        if !folders.isEmpty && !tools {
            return Problem(folders.count == urls.count ? L("Folders can’t be converted.") : L("Some of these are folders, and folders can’t be converted."),
                           suggestion: L("To compress a folder, use “Create ZIP” in the tools wheel."))
        }
        let unknown = urls.filter { Format.detect($0) == nil && !$0.hasDirectoryPath }
        if let first = unknown.first {
            if first.pathExtension.isEmpty {
                return Problem(L("Split doesn’t recognize files without an extension (“%@”).", first.lastPathComponent),
                               suggestion: L("Add the right extension to the name (for example .jpg or .pdf)."))
            }
            return Problem(L("Split doesn’t recognize .%@ files (“%@”).", first.pathExtension.lowercased(), first.lastPathComponent),
                           suggestion: L("This format isn’t supported yet."))
        }
        let formats = urls.compactMap(Format.detect)
        let groups = Set(formats.map(\.group))
        if groups.count > 1 {
            let names = listed(groups.map(groupName).sorted())
            return Problem(tools ? L("The files are of different kinds (%@) and no tool works for all of them.", names)
                                 : L("The files are of different kinds (%@) and no format works for all of them.", names),
                           suggestion: L("Drag files of one kind at a time."))
        }
        if let format = formats.first, !tools {
            switch format.group {
            case .presentation:
                return Problem(L("Converting %@ needs Keynote, PowerPoint or LibreOffice, and none of them is installed.", format.label),
                               suggestion: L("Install Keynote (free on the App Store) or LibreOffice: brew install --cask libreoffice"))
            case .spreadsheet:
                return Problem(L("Reading %@ needs Numbers, Excel or LibreOffice, and none of them is installed.", format.label),
                               suggestion: L("Install Numbers (free on the App Store) or LibreOffice: brew install --cask libreoffice"))
            case .document where format == .pages:
                return Problem(L("Converting Pages files needs Pages to be installed."), suggestion: L("Install it for free from the App Store."))
            default:
                break
            }
        }
        if tools {
            return Problem(urls.count == 1 ? L("No tool applies to this file.") : L("No tool applies to this combination of files."),
                           suggestion: L("For example, “Join Videos” needs at least two videos, and “Split PDF” only takes PDFs."))
        }
        return Problem(L("There are no conversions for these files."), suggestion: L("Try the tools wheel."))
    }

    /// The wheel has slices for these files, but the user hid every one of them.
    static func allHidden(wheel: String) -> Problem {
        Problem(L("Everything the “%@” wheel offers for these files is hidden.", wheel),
                suggestion: L("Show the slices again in Settings › Wheels."))
    }

    static func groupName(_ group: FormatGroup) -> String {
        switch group {
        case .image: return L("images")
        case .document: return L("documents")
        case .spreadsheet: return L("spreadsheets")
        case .presentation: return L("presentations")
        case .audio: return L("audio")
        case .video: return L("video")
        case .subtitle: return L("subtitles")
        case .archive: return L("archives")
        case .data: return L("data")
        }
    }
}
