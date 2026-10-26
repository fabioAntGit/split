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
