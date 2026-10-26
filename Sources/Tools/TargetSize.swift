import AppKit
import ImageIO

/// "Compress To…": the smallest loss that still fits a size the user picks (for e-mail
/// limits, upload forms…). Images search for the best quality and only shrink if they must;
/// audio and video get the exact bitrate the size allows (video in two passes).
enum TargetSize {
    /// Quick choices in the prompt, in bytes.
    static let presets = [500_000, 1_000_000, 2_000_000, 5_000_000, 10_000_000, 25_000_000]
    /// Common upload limits, a little under the real ones so the file passes with room to spare
    /// (e-mail grows attachments by about a third when sending them).
    static var uses: [(title: String, bytes: Int)] {
        [(L("E-mail attachment"), 18_000_000), (L("Discord, free account"), 10_000_000)]
    }

    /// "2MB", "1,5 MB", "800kb", "2 Mo", "300000" → bytes (decimal units, like Finder; French
    /// writes octets: Ko, Mo, Go).
    static func parse(_ text: String) -> Int? {
        let cleaned = text.lowercased().replacingOccurrences(of: ",", with: ".")
            .components(separatedBy: .whitespaces).joined()
        let units: [(String, Double)] = [("gb", 1e9), ("mb", 1e6), ("kb", 1e3), ("go", 1e9), ("mo", 1e6), ("ko", 1e3),
                                         ("g", 1e9), ("m", 1e6), ("k", 1e3), ("b", 1), ("o", 1)]
        for (suffix, factor) in units where cleaned.hasSuffix(suffix) {
            guard let value = Double(cleaned.dropLast(suffix.count)), value > 0 else { return nil }
            return Int(value * factor)
        }
        return Double(cleaned).map { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
    }

    /// "500 KB", "10 MB": what goes in the size field, readable back by `parse` in any language.
    static func plain(_ bytes: Int) -> String {
        if bytes >= 1_000_000 {
            let megabytes = Double(bytes) / 1e6
            return (megabytes == megabytes.rounded() ? String(Int(megabytes)) : String(format: "%.1f", megabytes)) + " MB"
        }
        return "\(bytes / 1000) KB"
    }

    static func describe(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    static func compress(_ url: URL, toFit limit: Int) throws -> URL {
        guard let format = Format.detect(url) else { throw Explain.noTargets([url], tools: true) }
        let size = Int(Tools.fileSize(url))
        if size <= limit {
            throw Problem(L("“%@” is already %@, within the %@ you asked for.", url.lastPathComponent, describe(size), describe(limit)),
                          suggestion: L("Nothing was changed."))
        }
        switch format.group {
        case .image: return try image(url, format: format, limit: limit)
        case .audio: return try audio(url, format: format, limit: limit)
        case .video: return try video(url, limit: limit)
        default: throw Explain.noTargets([url], tools: true)
        }
    }

    // MARK: Images

    private static func image(_ url: URL, format: Format, limit: Int) throws -> URL {
        let source = try ImageConverter.open(url)
        let full = try ImageConverter.orientedImage(source)
        let transparent = ImageConverter.hasTransparency(full)
        // Lossy formats stay as they are; lossless ones need a lossy format to get small.
        let target: Format = [.jpg, .heic, .avif, .webp].contains(format) ? format : (transparent ? .webp : .jpg)
        if target != format {
            Fidelity.note(L("%@ can only get this small as a photo format, so the result is %@.", format.label, target.label))
        }
        let metadata = Settings.keepsMetadata ? CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] : nil
        var scale: CGFloat = 1
        for _ in 0..<14 {
            try JobProgress.checkCancelled()
            let image = scale < 1 ? try ImageConverter.scaled(full, maxSide: Int(CGFloat(max(full.width, full.height)) * scale)) : full
            if let data = try bestEncoding(image, as: target, metadata: metadata, limit: limit) {
                let out = Output.url(for: url, ext: target.ext, suffix: " (" + describe(limit) + ")")
                try data.write(to: out, options: .atomic)
                if scale < 1 {
                    Fidelity.note(L("To fit %@ the image was also reduced to %@×%@ pixels.", describe(limit), String(image.width), String(image.height)))
                }
                return out
            }
            scale *= 0.8
            JobProgress.report(1 - Double(scale))
        }
        throw Problem(L("“%@” can’t get down to %@ without becoming unrecognizable.", url.lastPathComponent, describe(limit)),
                      suggestion: L("Choose a larger size."))
    }

    /// The highest quality whose file fits the limit (binary search), or nil when even the lowest is too big.
    private static func bestEncoding(_ image: CGImage, as format: Format, metadata: [CFString: Any]?, limit: Int) throws -> Data? {
        var low = 0.25
        var high = 0.95
        var best: Data?
        guard let smallest = try encode(image, as: format, quality: low, metadata: metadata), smallest.count <= limit else { return nil }
        best = smallest
        for _ in 0..<7 {
            let middle = (low + high) / 2
            guard let data = try encode(image, as: format, quality: middle, metadata: metadata) else { break }
            if data.count <= limit { best = data; low = middle } else { high = middle }
        }
        return best
    }

    private static func encode(_ image: CGImage, as format: Format, quality: Double, metadata: [CFString: Any]?) throws -> Data? {
        if format == .webp {
            let cwebp = try Engines.require("cwebp", brew: "webp")
            let dir = try Output.scratchDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let png = dir.appendingPathComponent("in.png")
            let webp = dir.appendingPathComponent("out.webp")
            try ImageConverter.write(image, metadata: metadata, to: png, as: .png)
            try runChecked(cwebp, ["-quiet", "-q", String(Int(quality * 100)), "-metadata", Settings.keepsMetadata ? "exif,icc,xmp" : "none",
                                   png.path, "-o", webp.path], what: L("Compressing the WebP"))
            return try Data(contentsOf: webp)
        }
        guard let type = ImageConverter.imageIOTypes[format] else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let value = metadata?[key] { properties[key] = value }
        }
        var flat = image
        if format == .jpg && ImageConverter.hasAlpha(image) { flat = try ImageConverter.flatten(image) }
        CGImageDestinationAddImage(destination, flat, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    // MARK: Audio and video

    /// AAC below this sounds broken; video below this is a slideshow.
    static let minimumAudioKbps = 24
    static let minimumVideoKbps = 90

    private static func audio(_ url: URL, format: Format, limit: Int) throws -> URL {
        let info = try MediaConverter.probe(url)
        guard info.duration > 0 else { throw Problem(L("The length of “%@” is unknown, so the bitrate can’t be worked out.", url.lastPathComponent)) }
        let kbps = Int(Double(limit) * 8 * 0.97 / info.duration / 1000)
        guard kbps >= minimumAudioKbps else {
            throw tooSmall(url, minimum: Int(Double(minimumAudioKbps * 1000) * info.duration / 8 / 0.97))
        }
        let target: Format = [.mp3, .ogg, .opus].contains(format) ? format : .m4a
        let out = Output.url(for: url, ext: target.ext, suffix: " (" + describe(limit) + ")")
        try MediaConverter.encode(url, ["-vn"] + MediaConverter.audioArguments(target, bitrate: "\(min(kbps, 320))k") + ["-map_metadata", "0"],
                                  to: out, what: L("Compressing the audio"), duration: info.duration)
        return out
    }

    private static func video(_ url: URL, limit: Int) throws -> URL {
        let info = try MediaConverter.probe(url)
        guard info.duration > 0 else { throw Problem(L("The length of “%@” is unknown, so the bitrate can’t be worked out.", url.lastPathComponent)) }
        let totalKbps = Double(limit) * 8 * 0.96 / info.duration / 1000
        let audioKbps = info.containsAudio ? (totalKbps > 600 ? 128 : (totalKbps > 250 ? 96 : 48)) : 0
        var videoKbps = Int(totalKbps) - audioKbps
        guard videoKbps >= minimumVideoKbps else {
            throw tooSmall(url, minimum: Int(Double((minimumVideoKbps + 48) * 1000) * info.duration / 8 / 0.96))
        }
        // The lower the bitrate, the smaller the picture that still looks clean.
        let height = videoKbps > 2500 ? 1080 : (videoKbps > 1200 ? 720 : (videoKbps > 500 ? 540 : 360))
        let out = Output.url(for: url, ext: "mp4", suffix: " (" + describe(limit) + ")")
        for attempt in 0..<2 {
            try twoPass(url, info: info, videoKbps: videoKbps, audioKbps: audioKbps, maxHeight: height, to: out)
            let size = Int(Tools.fileSize(out))
            if size <= limit { break }
            // Container overhead on very short clips can overshoot: one corrective pass.
            guard attempt == 0 else { break }
            try? FileManager.default.removeItem(at: out)
            videoKbps = Int(Double(videoKbps) * Double(limit) / Double(size) * 0.95)
        }
        if info.displaySize.height > CGFloat(height) {
            Fidelity.note(L("To fit %@ the video was reduced to %@p.", describe(limit), String(height)))
        }
        return out
    }

    private static func twoPass(_ url: URL, info: MediaConverter.Probe, videoKbps: Int, audioKbps: Int, maxHeight: Int, to out: URL) throws {
        let dir = try Output.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("pass").path
        let picture = ["-vf", "scale=-2:'min(\(maxHeight),ih)'," + MediaConverter.evenDimensions, "-c:v", "libx264", "-preset", "medium",
                       "-b:v", "\(videoKbps)k", "-pix_fmt", "yuv420p", "-passlogfile", log]
        let ffmpeg = try MediaConverter.ffmpeg()
        try runChecked(ffmpeg, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"] + MediaConverter.localInput(url)
                       + ["-map", "0:v:0"] + picture + ["-pass", "1", "-an", "-f", "null", "/dev/null"], cwd: dir, what: L("Analyzing the video"))
        JobProgress.report(0.4)
        let sound = audioKbps > 0 ? ["-map", "0:a:0", "-c:a", "aac", "-b:a", "\(audioKbps)k"] : []
        try MediaConverter.encode(url, ["-map", "0:v:0"] + picture + ["-pass", "2"] + sound + ["-map_metadata", "0", "-movflags", "+faststart"],
                                  to: out, what: L("Compressing the video"), duration: info.duration)
    }

    private static func tooSmall(_ url: URL, minimum: Int) -> Problem {
        Problem(L("“%@” is too long to fit that size without falling apart.", url.lastPathComponent),
                suggestion: L("Choose at least %@, or trim it first in the editor.", describe(minimum)))
    }

    // MARK: Asking

    /// The size, asked in a small native dialog. Nil when cancelled.
    static func ask(for urls: [URL]) -> Int? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("Compress to what size?")
        alert.informativeText = urls.count == 1
            ? L("“%@” is %@. The result will be at most the size you choose.", urls[0].lastPathComponent, describe(Int(Tools.fileSize(urls[0]))))
            : L("Each of the %@ files will be at most the size you choose.", String(urls.count))
        let field = NSTextField(string: Settings.lastTargetSize)
        field.placeholderString = "2 MB"
        field.frame = NSRect(x: 0, y: 30, width: 240, height: 24)
        let presets = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26), pullsDown: true)
        presets.addItem(withTitle: L("Common sizes"))
        for bytes in TargetSize.presets {
            presets.addItem(withTitle: plain(bytes))
            presets.lastItem?.representedObject = bytes
        }
        presets.menu?.addItem(.separator())
        for use in TargetSize.uses {
            presets.addItem(withTitle: "\(use.title) · \(plain(use.bytes))")
            presets.lastItem?.representedObject = use.bytes
        }
        let picker = PresetPicker(field: field)
        presets.target = picker
        presets.action = #selector(PresetPicker.pick(_:))
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 56))
        accessory.addSubview(field)
        accessory.addSubview(presets)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: L("Compress"))
        alert.addButton(withTitle: L("Cancel"))
        while alert.runModal() == .alertFirstButtonReturn {
            if let bytes = parse(field.stringValue), bytes >= 10_000 {
                Settings.lastTargetSize = field.stringValue
                return bytes
            }
            alert.informativeText = L("Write a size like “2 MB” or “800 KB” (at least 10 KB).")
        }
        return nil
    }

    private final class PresetPicker: NSObject {
        let field: NSTextField
        init(field: NSTextField) { self.field = field }
        @objc func pick(_ sender: NSPopUpButton) {
            if let bytes = sender.selectedItem?.representedObject as? Int { field.stringValue = TargetSize.plain(bytes) }
        }
    }
}
