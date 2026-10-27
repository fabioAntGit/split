import Foundation

enum FormatGroup {
    case image, document, spreadsheet, presentation, audio, video, subtitle, archive, data
}

// Every format the app reads or writes. Some are inputs only (doc, odt, md, m4v...),
// because macOS can read them but there is no good reason to produce them.
enum Format: String, CaseIterable {
    case jpg, png, webp, jxl, heic, avif, tiff, bmp, gif, ico, svg
    case pdf, docx, doc, odt, rtf, rtfd, txt, html, md, epub, pages
    case xlsx, xls, ods, numbers, csv, tsv
    case pptx, ppt, odp, key
    case mp3, m4a, wav, flac, ogg, opus, aiff, wma
    case mp4, mov, m4v, mkv, webm, avi, wmv
    case srt, vtt
    case zip, tar, tgz, rar, sevenZip = "7z"
    case json, xml, yaml

    var ext: String {
        switch self {
        case .tgz: return "tar.gz"
        default: return rawValue
        }
    }

    var label: String {
        switch self {
        case .tgz: return "TAR.GZ"
        case .md: return "Markdown"
        case .pages: return "Pages"
        case .numbers: return "Numbers"
        case .key: return "Keynote"
        case .jxl: return "JPEG XL"
        case .webp: return "WebP"
        default: return rawValue.uppercased()
        }
    }

    /// What the format is good for, in a few words.
    var summary: String {
        switch self {
        case .jpg: return L("Photos. Small files, without transparency.")
        case .png: return L("Screenshots and graphics. Lossless, with transparency.")
        case .webp: return L("Pictures for the web, smaller than JPG and PNG.")
        case .jxl: return L("The newest picture format: very small, lossless when needed.")
        case .heic: return L("iPhone photos, about half the size of JPG.")
        case .avif: return L("Very small pictures for the web.")
        case .tiff: return L("Printing and archiving. Lossless, large files.")
        case .bmp: return L("Uncompressed pictures for older programs.")
        case .gif: return L("Short animations with 256 colours.")
        case .ico: return L("Icons for Windows and websites.")
        case .svg: return L("Drawings that stay sharp at any size.")
        case .pdf: return L("Looks the same everywhere. Ready to share and print.")
        case .docx: return L("Word documents, ready to edit.")
        case .doc: return L("Documents from older versions of Word.")
        case .odt: return L("LibreOffice documents.")
        case .rtf: return L("Formatted text almost any editor opens.")
        case .rtfd: return L("TextEdit documents with pictures.")
        case .txt: return L("Plain text, without formatting.")
        case .html: return L("A web page that opens in any browser.")
        case .md: return L("Plain text with simple formatting marks.")
        case .epub: return L("E-books for Books and e-readers.")
        case .pages: return L("Pages documents.")
        case .xlsx: return L("Excel workbooks, with formulas.")
        case .xls: return L("Workbooks from older versions of Excel.")
        case .ods: return L("LibreOffice spreadsheets.")
        case .numbers: return L("Numbers spreadsheets.")
        case .csv: return L("A table as plain text, for any app or database.")
        case .tsv: return L("A table as plain text, with tabs between columns.")
        case .pptx: return L("PowerPoint presentations.")
        case .ppt: return L("Presentations from older versions of PowerPoint.")
        case .odp: return L("LibreOffice presentations.")
        case .key: return L("Keynote presentations.")
        case .mp3: return L("Music and sound that play everywhere.")
        case .m4a: return L("Apple’s audio: small, good quality.")
        case .wav: return L("Uncompressed sound, for editing.")
        case .flac: return L("Lossless music, about half the size of WAV.")
        case .ogg: return L("Open audio format, common in games and Linux.")
        case .opus: return L("Very small voice and music files.")
        case .aiff: return L("Uncompressed sound, the Mac’s own WAV.")
        case .wma: return L("Windows Media audio.")
        case .mp4: return L("Video that plays everywhere.")
        case .mov: return L("QuickTime video, for Apple apps and editing.")
        case .m4v: return L("Video from the iTunes Store and older Apple apps.")
        case .mkv: return L("Video with several audio tracks and subtitles.")
        case .webm: return L("Video for web pages.")
        case .avi: return L("Video for older Windows programs.")
        case .wmv: return L("Windows Media video.")
        case .srt: return L("Subtitles almost every player reads.")
        case .vtt: return L("Subtitles for video on the web.")
        case .zip: return L("A compressed folder that opens everywhere.")
        case .tar: return L("An uncompressed archive, common on Linux.")
        case .tgz: return L("A compressed archive, common on Linux.")
        case .rar: return L("An archive made with WinRAR.")
        case .sevenZip: return L("An archive made with 7-Zip.")
        case .json: return L("Structured data for apps and the web.")
        case .xml: return L("Structured data in tags.")
        case .yaml: return L("Easy-to-read data, common in settings files.")
        }
    }

    var group: FormatGroup {
        switch self {
        case .jpg, .png, .webp, .jxl, .heic, .avif, .tiff, .bmp, .gif, .ico, .svg: return .image
        case .pdf, .docx, .doc, .odt, .rtf, .rtfd, .txt, .html, .md, .epub, .pages: return .document
        case .xlsx, .xls, .ods, .numbers, .csv, .tsv: return .spreadsheet
        case .pptx, .ppt, .odp, .key: return .presentation
        case .mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma: return .audio
        case .mp4, .mov, .m4v, .mkv, .webm, .avi, .wmv: return .video
        case .srt, .vtt: return .subtitle
        case .zip, .tar, .tgz, .rar, .sevenZip: return .archive
        case .json, .xml, .yaml: return .data
        }
    }

    private static let aliases: [String: Format] = [
        "jpeg": .jpg, "jpe": .jpg, "tif": .tiff, "heif": .heic, "htm": .html, "xhtml": .html,
        "markdown": .md, "text": .txt, "aif": .aiff, "oga": .ogg, "qt": .mov, "tgz": .tgz,
        "mpeg": .mp4, "mpg": .mp4, "3gp": .mp4, "aac": .m4a, "caf": .m4a, "yml": .yaml, "geojson": .json,
        // Saved by browsers and social sites: JFIF is plain JPEG, the "_large"/"_orig" names
        // come from downloading full-size pictures.
        "jfif": .jpg, "pjpeg": .jpg, "jpg_large": .jpg, "jpeg_large": .jpg, "jpg_orig": .jpg, "png_large": .png,
    ]

    static func detect(_ url: URL) -> Format? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") { return .tgz }
        let ext = url.pathExtension.lowercased()
        return Format(rawValue: ext) ?? aliases[ext]
    }

    static func parse(_ text: String) -> Format? {
        let key = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if key == "tar.gz" { return .tgz }
        return Format(rawValue: key) ?? aliases[key]
    }
}
