import AppKit
import ImageIO

// ImageIO for everything macOS can encode natively, cwebp/gif2webp for WebP
// (ImageIO can read WebP but not write it).
enum ImageConverter: ConversionFamily {
    static let stillTargets: [Format] = [.jpg, .png, .webp, .jxl, .heic, .avif, .tiff, .bmp, .gif, .ico, .pdf]

    static func targets(from source: Format) -> [Format] {
        guard source.group == .image else { return [] }
        return stillTargets + (source == .gif ? [.mp4, .webm] : [])
    }

    static let imageIOTypes: [Format: String] = [
        .jpg: "public.jpeg", .png: "public.png", .heic: "public.heic", .avif: "public.avif",
        .tiff: "public.tiff", .bmp: "com.microsoft.bmp", .gif: "com.compuserve.gif",
        .ico: "com.microsoft.ico", .pdf: "com.adobe.pdf",
    ]

    static func convert(_ url: URL, from source: Format, to target: Format) throws -> [URL] {
        if source == .gif && (target == .mp4 || target == .webm) {
            return try MediaConverter.convert(url, from: source, to: target)
        }
        if source == .svg {
            let out = Output.url(for: url, ext: target.ext)
            try writeAny(try renderSVG(url), metadata: nil, to: out, as: target)
            return [out]
        }
        let imageSource = try open(url)
        let frames = Frames(imageSource)
        if frames.count > 1 {
            return try convertFrames(url, imageSource, frames, from: source, to: target)
        }
        let out = Output.url(for: url, ext: target.ext)
        switch target {
        case .webp: try writeWebP(url, from: source, to: out)
        case .jxl: try writeJXL(url, from: source, to: out)
        default: try writeFaithful(imageSource, index: 0, to: out, as: target)
        }
        return [out]
    }

    /// What a file with several images holds: an animation (frames with timing), the sizes
    /// of an icon, or pages (multi-page TIFF, HEIC collections).
    struct Frames {
        let count: Int
        let animated: Bool
        let isIcon: Bool
        /// The biggest image: what a single picture of an icon should show.
        let largest: Int

        init(_ source: CGImageSource) {
            count = CGImageSourceGetCount(source)
            let type = CGImageSourceGetType(source) as String? ?? ""
            isIcon = type == "com.microsoft.ico" || type == "com.apple.icns"
            var animated = false
            var largest = 0
            var largestArea = 0
            for index in 0..<count {
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
                if properties[kCGImagePropertyGIFDictionary] != nil && count > 1 { animated = true }
                if let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any], png[kCGImagePropertyAPNGDelayTime] != nil { animated = true }
                if let webp = properties[kCGImagePropertyWebPDictionary] as? [CFString: Any], webp[kCGImagePropertyWebPDelayTime] != nil { animated = true }
                let area = (properties[kCGImagePropertyPixelWidth] as? Int ?? 0) * (properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
                if area > largestArea { largestArea = area; largest = index }
            }
            self.animated = animated && !isIcon
            self.largest = largest
        }
    }

    /// Formats that hold an animation with its timing, and formats that hold pages.
    static let animationTargets: Set<Format> = [.gif, .png, .webp, .jxl]
    static let pageTargets: Set<Format> = [.tiff, .pdf]

    private static func convertFrames(_ url: URL, _ source: CGImageSource, _ frames: Frames, from format: Format, to target: Format) throws -> [URL] {
        let out = Output.url(for: url, ext: target.ext)
        if frames.isIcon {
            // An icon's images are one picture at several sizes: keep the biggest.
            try writeAny(try orientedImage(source, index: frames.largest), metadata: nil, to: out, as: target)
            return [out]
        }
        if frames.animated {
            switch target {
            case .gif: try writeAnimation(source, to: out, as: .gif)
            case .png: try writeAnimation(source, to: out, as: .png)
            case .webp where format == .gif: try writeWebP(url, from: format, to: out)
            case .webp: try writeAnimatedWebP(source, to: out)
            case .jxl: try writeAnimatedJXL(url, source, from: format, to: out)
            case .tiff, .pdf:
                try writePages(source, to: out, as: target)
                Fidelity.note(L("%@ keeps every frame of the animation, but not its timing: it doesn’t play.", target.label))
            default:
                try writeFaithful(source, index: 0, to: out, as: target)
                Fidelity.note(L("%@ holds a single picture, so only the first of the %@ frames was kept. GIF, PNG, WebP, JPEG XL or MP4 keep the animation.",
                                target.label, String(frames.count)))
            }
            return [out]
        }
        if pageTargets.contains(target) {
            try writePages(source, to: out, as: target)
            return [out]
        }
        // Pages into a one-picture format: one file per page, in a folder, so none is lost.
        Output.discard(out)
        let folder = Output.folder(for: url, suffix: " (" + L("pages") + ")")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<frames.count {
            try JobProgress.checkCancelled()
            let page = folder.appendingPathComponent("\(Output.baseName(url)) \(index + 1).\(target.ext)")
            switch target {
            case .webp, .jxl:
                try writeAny(try orientedImage(source, index: index), metadata: nil, to: page, as: target)
            default:
                try writeFaithful(source, index: index, to: page, as: target)
            }
            JobProgress.report(Double(index + 1) / Double(frames.count))
        }
        return [folder]
    }

    // MARK: Reading

    static func open(_ url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            // macOS reads JPEG XL from version 14 on; before that, libjxl's decoder does it.
            if Format.detect(url) == .jxl, Engines.path("djxl") != nil { return try decodeJXL(url) }
            throw Problem(L("macOS couldn’t read “%@” as an image.", url.lastPathComponent),
                                  suggestion: FileCheck.mismatch(url)
                                      ?? L("The file seems damaged or incomplete (for example, a download that didn’t finish). Open it in Preview to check."))
        }
        return source
    }

    /// A JPEG XL decoded to PNG (keeping its colour profile and metadata), held in memory so
    /// the temporary file can go straight away.
    static func decodeJXL(_ url: URL) throws -> CGImageSource {
        let djxl = try Engines.require("djxl", brew: "jpeg-xl")
        let dir = try Output.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("decoded.png")
        try runChecked(djxl, [url.path, png.path, "--quiet"], what: L("Reading the JPEG XL image"))
        guard let source = CGImageSourceCreateWithData(try Data(contentsOf: png) as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw Problem(L("“%@” could not be read as a JPEG XL image.", url.lastPathComponent),
                          suggestion: L("The file may be damaged or incomplete."))
        }
        return source
    }

    /// Full-size image with the EXIF orientation already applied.
    static func orientedImage(_ source: CGImageSource, index: Int = 0, maxPixelSize: Int? = nil) throws -> CGImage {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let longest = max(width, height)
        if longest > 0 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: min(longest, maxPixelSize ?? longest),
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) {
                return image
            }
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
            throw Problem(L("The image has damaged data that macOS can’t decode."),
                                  suggestion: L("Open it in Preview: if it doesn’t open there either, the file is broken."))
        }
        return image
    }

    static func loadImage(_ url: URL, maxPixelSize: Int? = nil) throws -> CGImage {
        if Format.detect(url) == .svg { return try renderSVG(url) }
        return try orientedImage(try open(url), maxPixelSize: maxPixelSize)
    }

    static func renderSVG(_ source: URL) throws -> CGImage {
        // Rendered from a copy without remote references, so the SVG can't load anything from the Internet.
        let dir = try Output.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("image.svg")
        try LocalOnly.svg(try DocumentPipeline.readText(source)).write(to: url, atomically: true, encoding: .utf8)
        if let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 {
            let longest = max(image.size.width, image.size.height)
            let scale = max(1, 2048 / longest)
            let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
            if let context = bitmapContext(size), let cg = onMain({ () -> CGImage? in
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                image.draw(in: CGRect(origin: .zero, size: size))
                NSGraphicsContext.restoreGraphicsState()
                return context.makeImage()
            }) {
                return cg
            }
        }
        // Fallback: Quick Look renders SVG through WebKit.
        let thumbnails = dir.appendingPathComponent("thumbs", isDirectory: true)
        try FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)
        try runChecked("/usr/bin/qlmanage", ["-t", "-s", "2048", "-o", thumbnails.path, url.path], what: L("Rendering the SVG"))
        let png = thumbnails.appendingPathComponent(url.lastPathComponent + ".png")
        guard FileManager.default.fileExists(atPath: png.path) else {
            throw Problem(L("macOS couldn’t draw the SVG “%@”.", source.lastPathComponent),
                                  suggestion: L("The file may have syntax errors or use SVG features that aren’t supported. Open it in Safari to check."))
        }
        return try orientedImage(try open(png))
    }

    // MARK: Writing

    /// Formats that store orientation, colour profile and EXIF/XMP/GPS metadata.
    static let metadataTargets: Set<Format> = [.jpg, .png, .heic, .avif, .tiff]

    /// One image re-encoded with everything the target can hold: the pixels as they are
    /// (orientation stays a tag), the colour profile and all metadata. Formats without
    /// metadata, or "Keep metadata" off, get the orientation applied to the pixels instead.
    static func writeFaithful(_ source: CGImageSource, index: Int, to out: URL, as format: Format, quality: Quality = Settings.quality) throws {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        // Many viewers ignore the orientation tag of a PNG, so a rotated photo has its pixels turned instead.
        let rotatedPNG = format == .png && (properties?[kCGImagePropertyOrientation] as? Int ?? 1) != 1
        guard Settings.keepsMetadata, metadataTargets.contains(format), !rotatedPNG, let type = imageIOTypes[format] else {
            try write(try orientedImage(source, index: index), metadata: Settings.keepsMetadata ? properties : nil, to: out, as: format, quality: quality)
            return
        }
        var flattened: CGImage?
        if format == .jpg, let raw = CGImageSourceCreateImageAtIndex(source, index, nil), hasTransparency(raw) {
            flattened = try flatten(raw)
            Fidelity.note(L("JPG has no transparency, so transparent areas became white. PNG, WebP, HEIC or JPEG XL keep it."))
        }
        var options: [CFString: Any] = [:]
        if [.jpg, .heic, .avif].contains(format) { options[kCGImageDestinationLossyCompressionQuality] = quality.lossy }
        let temp = Output.tempSibling(of: out)
        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, type as CFString, 1, nil) else {
            throw Problem(L("macOS could not create the %@ file in the folder “%@”.", format.label, out.deletingLastPathComponent().lastPathComponent),
                          suggestion: FileCheck.privacyHint(for: out.deletingLastPathComponent()))
        }
        if let flattened {
            CGImageDestinationAddImageAndMetadata(destination, flattened, CGImageSourceCopyMetadataAtIndex(source, index, nil), options as CFDictionary)
        } else {
            CGImageDestinationAddImageFromSource(destination, source, index, options as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            Output.discard(temp)
            throw Problem(L("The %@ encoder in macOS refused this image.", format.label),
                          suggestion: format == .avif || format == .heic
                              ? L("%@ has limits on size and color format. Try PNG, JPG or WebP.", format.label)
                              : L("Try another format, such as PNG."))
        }
        try Output.commit(temp, to: out)
    }

    /// Any target from pixels (SVG renders, icon sizes, pages): ImageIO, cwebp or cjxl.
    static func writeAny(_ image: CGImage, metadata: [CFString: Any]?, to out: URL, as format: Format) throws {
        switch format {
        case .webp: try writeWebP(image, to: out)
        case .jxl: try writeJXL(image, to: out)
        default: try write(image, metadata: metadata, to: out, as: format)
        }
    }

    /// Every image of the source as a page (PDF) or an image of a multi-page TIFF.
    static func writePages(_ source: CGImageSource, to out: URL, as format: Format) throws {
        guard let type = imageIOTypes[format] else { return }
        let count = CGImageSourceGetCount(source)
        let temp = Output.tempSibling(of: out)
        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, type as CFString, count, nil) else {
            throw Problem(L("macOS could not create the %@ file in the folder “%@”.", format.label, out.deletingLastPathComponent().lastPathComponent),
                          suggestion: FileCheck.privacyHint(for: out.deletingLastPathComponent()))
        }
        for index in 0..<count {
            try JobProgress.checkCancelled()
            if Settings.keepsMetadata && format == .tiff {
                CGImageDestinationAddImageFromSource(destination, source, index, nil)
            } else {
                CGImageDestinationAddImage(destination, try orientedImage(source, index: index), nil)
            }
        }
        guard CGImageDestinationFinalize(destination) else {
            Output.discard(temp)
            throw Problem(L("macOS could not put the %@ images together into one %@.", String(count), format.label))
        }
        try Output.commit(temp, to: out)
    }

    /// Animated GIF or PNG (APNG) with each frame's own delay and the original loop count.
    static func writeAnimation(_ source: CGImageSource, to out: URL, as format: Format) throws {
        let count = CGImageSourceGetCount(source)
        let isGIF = format == .gif
        let temp = Output.tempSibling(of: out)
        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, (isGIF ? "com.compuserve.gif" : "public.png") as CFString, count, nil) else {
            throw Problem(L("macOS could not create the %@ file in the folder “%@”.", format.label, out.deletingLastPathComponent().lastPathComponent),
                          suggestion: FileCheck.privacyHint(for: out.deletingLastPathComponent()))
        }
        let loops = loopCount(source)
        let container: [CFString: Any] = isGIF
            ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loops]]
            : [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: loops]]
        CGImageDestinationSetProperties(destination, container as CFDictionary)
        for index in 0..<count {
            try JobProgress.checkCancelled()
            let delay = frameDelay(source, index)
            let frame: [CFString: Any] = isGIF
                ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]]
                : [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay]]
            CGImageDestinationAddImageFromSource(destination, source, index, frame as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            Output.discard(temp)
            throw Problem(L("macOS could not build the animated %@ (%@ frames).", format.label, String(count)),
                          suggestion: L("Very long or large animations can fail. Convert to MP4 or WebP, which handle animation better."))
        }
        try Output.commit(temp, to: out)
    }

    /// 0 means "forever", as in the formats themselves.
    static func loopCount(_ source: CGImageSource) -> Int {
        let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
        if let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any], let loops = gif[kCGImagePropertyGIFLoopCount] as? Int { return loops }
        if let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any], let loops = png[kCGImagePropertyAPNGLoopCount] as? Int { return loops }
        if let webp = properties[kCGImagePropertyWebPDictionary] as? [CFString: Any], let loops = webp[kCGImagePropertyWebPLoopCount] as? Int { return loops }
        return 0
    }

    /// Animated WebP from any animation ImageIO reads (APNG, animated HEIC…), frame by frame.
    static func writeAnimatedWebP(_ source: CGImageSource, to out: URL) throws {
        let img2webp = try Engines.require("img2webp", brew: "webp")
        let dir = try Output.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var arguments = ["-loop", String(loopCount(source)), "-lossy", "-q", String(Settings.quality.webp)]
        for index in 0..<CGImageSourceGetCount(source) {
            try JobProgress.checkCancelled()
            let frame = dir.appendingPathComponent(String(format: "frame-%05d.png", index))
            try write(try orientedImage(source, index: index), metadata: nil, to: frame, as: .png)
            arguments += ["-d", String(Int((frameDelay(source, index) * 1000).rounded())), frame.path]
        }
        let temp = Output.tempSibling(of: out)
        do {
            try runChecked(img2webp, arguments + ["-o", temp.path], what: L("Converting to WebP"))
        } catch {
            Output.discard(temp)
            throw error
        }
        try Output.commit(temp, to: out)
    }

    // MARK: JPEG XL

    /// JPEG XL keeps everything: a JPEG is repacked without losing a single pixel (and can be
    /// restored byte for byte), lossless sources stay lossless, the rest uses the chosen quality.
    static func writeJXL(_ url: URL, from source: Format, to out: URL) throws {
        let cjxl = try Engines.require("cjxl", brew: "jpeg-xl")
        let imageSource = try open(url)
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
        var input = url
        var arguments: [String]
        var scratch: URL?
        defer { if let scratch { try? FileManager.default.removeItem(at: scratch) } }
        switch source {
        case .jpg where orientation == 1:
            arguments = ["--lossless_jpeg=1"]
        case .png, .gif:
            arguments = ["-d", "0"]
        default:
            // cjxl reads PNG, GIF and JPEG; everything else (and rotated photos) goes through a PNG
            // that carries the metadata.
            let dir = try Output.scratchDirectory()
            scratch = dir
            input = dir.appendingPathComponent("frame.png")
            let metadata = Settings.keepsMetadata ? properties : nil
            try write(try orientedImage(imageSource), metadata: metadata, to: input, as: .png)
            let lossless: Set<Format> = [.png, .tiff, .bmp, .gif, .ico, .jpg]
            arguments = lossless.contains(source) ? ["-d", "0"] : ["-q", String(Settings.quality.webp)]
        }
        if !Settings.keepsMetadata { arguments += ["-x", "strip=exif", "-x", "strip=xmp"] }
        try encodeJXL(cjxl, input: input, arguments: arguments, to: out)
    }

    static func writeJXL(_ image: CGImage, to out: URL) throws {
        let cjxl = try Engines.require("cjxl", brew: "jpeg-xl")
        let dir = try Output.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("frame.png")
        try write(image, metadata: nil, to: png, as: .png)
        try encodeJXL(cjxl, input: png, arguments: ["-d", "0"], to: out)
    }

    /// GIF and APNG go to cjxl as they are (it keeps the animation); other animations become an APNG first.
    static func writeAnimatedJXL(_ url: URL, _ source: CGImageSource, from format: Format, to out: URL) throws {
        let cjxl = try Engines.require("cjxl", brew: "jpeg-xl")
        if format == .gif || format == .png {
            try encodeJXL(cjxl, input: url, arguments: ["-d", "0"], to: out)
            return
        }
        let dir = try Output.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let apng = dir.appendingPathComponent("animation.png")
        try writeAnimation(source, to: apng, as: .png)
        try encodeJXL(cjxl, input: apng, arguments: ["-d", "0"], to: out)
    }

    private static func encodeJXL(_ cjxl: String, input: URL, arguments: [String], to out: URL) throws {
        let temp = Output.tempSibling(of: out)
        do {
            try runChecked(cjxl, [input.path, temp.path, "--quiet", "-e", "7"] + arguments, what: L("Converting to JPEG XL"))
        } catch {
            Output.discard(temp)
            throw error
        }
        try Output.commit(temp, to: out)
    }

    static func write(_ image: CGImage, metadata: [CFString: Any]?, to out: URL, as format: Format, quality: Quality = Settings.quality) throws {
        guard let type = imageIOTypes[format] else {
            throw Problem(L("macOS can’t save %@ images directly.", format.label), suggestion: L("Choose PNG or JPG."))
        }
        var image = image
        if format == .jpg && hasTransparency(image) {
            image = try flatten(image)
            Fidelity.note(L("JPG has no transparency, so transparent areas became white. PNG, WebP, HEIC or JPEG XL keep it."))
        }
        if format == .ico {
            try writeIcon(image, to: out)
            return
        }
        var properties: [CFString: Any] = [:]
        if Settings.keepsMetadata, let metadata {
            for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
                if let value = metadata[key] { properties[key] = value }
            }
            // Pixel dimensions in EXIF describe the original; edited images may differ.
            if var exif = metadata[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                exif[kCGImagePropertyExifPixelXDimension] = nil
                exif[kCGImagePropertyExifPixelYDimension] = nil
                properties[kCGImagePropertyExifDictionary] = exif
            }
            if var tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                properties[kCGImagePropertyTIFFDictionary] = tiff
            }
        }
        properties[kCGImagePropertyOrientation] = 1
        if [.jpg, .heic, .avif].contains(format) {
            properties[kCGImageDestinationLossyCompressionQuality] = quality.lossy
        }
        let temp = Output.tempSibling(of: out)
        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, type as CFString, 1, nil) else {
            throw Problem(L("macOS could not create the %@ file in the folder “%@”.", format.label, out.deletingLastPathComponent().lastPathComponent),
                                  suggestion: FileCheck.privacyHint(for: out.deletingLastPathComponent()))
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            Output.discard(temp)
            throw Problem(L("The %@ encoder in macOS refused this image (%@ × %@ px).", format.label, image.width, image.height),
                                  suggestion: format == .avif || format == .heic
                                      ? L("%@ has limits on size and color format. Try PNG, JPG or WebP.", format.label)
                                      : L("Try another format, such as PNG."))
        }
        try Output.commit(temp, to: out)
    }

    /// An icon with the standard sizes up to the image's own (ICO stops at 256 px).
    static func writeIcon(_ image: CGImage, to out: URL) throws {
        let longest = max(image.width, image.height)
        if longest > 256 { Fidelity.note(L("ICO holds at most 256×256 pixels, so the image was reduced to that size.")) }
        let sides = [16, 32, 48, 64, 128, 256].filter { $0 <= max(16, longest) }
        let temp = Output.tempSibling(of: out)
        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, "com.microsoft.ico" as CFString, sides.count, nil) else {
            throw Problem(L("macOS could not create the %@ file in the folder “%@”.", "ICO", out.deletingLastPathComponent().lastPathComponent))
        }
        for side in sides.reversed() { CGImageDestinationAddImage(destination, try squareIcon(image, side: side), nil) }
        guard CGImageDestinationFinalize(destination) else {
            Output.discard(temp)
            throw Problem(L("The %@ encoder in macOS refused this image.", "ICO"), suggestion: L("Try another format, such as PNG."))
        }
        try Output.commit(temp, to: out)
    }

    static func writeAnimatedGIF(_ source: CGImageSource, count: Int, to out: URL) throws {
        let temp = Output.tempSibling(of: out)
        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, "com.compuserve.gif" as CFString, count, nil) else {
            throw Problem(L("macOS couldn’t create the GIF in the destination folder."), suggestion: FileCheck.privacyHint(for: out.deletingLastPathComponent()))
        }
        let loop: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(destination, loop as CFDictionary)
        for index in 0..<count {
            let frame: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: frameDelay(source, index)]]
            CGImageDestinationAddImageFromSource(destination, source, index, frame as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            Output.discard(temp)
            throw Problem(L("macOS couldn’t assemble the animated GIF (%@ frames).", count),
                                  suggestion: L("Very long or large animations can fail. Convert to MP4 or WebP, which handle animation better."))
        }
        try Output.commit(temp, to: out)
    }

    static func frameDelay(_ source: CGImageSource, _ index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let containers: [(CFString, [CFString])] = [
            (kCGImagePropertyGIFDictionary, [kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime]),
            (kCGImagePropertyPNGDictionary, [kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime]),
            (kCGImagePropertyWebPDictionary, [kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime]),
        ]
        for (container, keys) in containers {
            guard let dict = properties[container] as? [CFString: Any] else { continue }
            for key in keys {
                if let delay = dict[key] as? Double, delay > 0.01 { return delay }
            }
        }
        return 0.1
    }

    static func writeWebP(_ url: URL, from source: Format, to out: URL) throws {
        let temp = Output.tempSibling(of: out)
        let quality = String(Settings.quality.webp)
        if source == .gif, let gifSource = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(gifSource) > 1 {
            let gif2webp = try Engines.require("gif2webp", brew: "webp")
            try runChecked(gif2webp, ["-quiet", "-q", quality, "-m", "4", "-mixed", url.path, "-o", temp.path], what: L("Converting to WebP"))
            try Output.commit(temp, to: out)
            return
        }
        let cwebp = try Engines.require("cwebp", brew: "webp")
        var input = url
        var scratch: URL?
        defer { if let scratch { try? FileManager.default.removeItem(at: scratch) } }
        // Homebrew's cwebp reads only JPEG and PNG (no libtiff) and ignores EXIF
        // orientation, so anything else (or a rotated photo) goes through an oriented PNG.
        var needsPNG = source == .svg
        if !needsPNG {
            let imageSource = try open(url)
            let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
            let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
            needsPNG = ![.jpg, .png].contains(source) || orientation != 1
        }
        if needsPNG {
            let dir = try Output.scratchDirectory()
            scratch = dir
            input = dir.appendingPathComponent("frame.png")
            let image = source == .svg ? try renderSVG(url) : try orientedImage(try open(url))
            try write(image, metadata: nil, to: input, as: .png)
        }
        let metadata = Settings.keepsMetadata ? "exif,icc,xmp" : "none"
        do {
            try runChecked(cwebp, ["-quiet", "-q", quality, "-metadata", metadata, input.path, "-o", temp.path], what: L("Converting to WebP"))
        } catch {
            Output.discard(temp)
            throw error
        }
        try Output.commit(temp, to: out)
    }

    /// WebP from pixels (editors): an intermediate PNG fed to cwebp, alpha kept.
    static func writeWebP(_ image: CGImage, to out: URL, quality: Quality = Settings.quality) throws {
        let cwebp = try Engines.require("cwebp", brew: "webp")
        let dir = try Output.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("image.png")
        try write(image, metadata: nil, to: png, as: .png)
        let temp = Output.tempSibling(of: out)
        do {
            try runChecked(cwebp, ["-quiet", "-q", String(quality.webp), "-alpha_q", "100", png.path, "-o", temp.path], what: L("Creating the WebP"))
        } catch {
            Output.discard(temp)
            throw error
        }
        try Output.commit(temp, to: out)
    }

    // MARK: Pixel helpers

    static func bitmapContext(_ size: CGSize) -> CGContext? {
        CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    static func outOfMemory(_ size: CGSize) -> Problem {
        Problem(L("There isn’t enough memory for a %@ × %@ pixel image.", Int(size.width), Int(size.height)),
                        suggestion: L("Close other apps or make the image smaller first."))
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// An alpha channel that is actually used (many opaque PNGs carry one anyway).
    static func hasTransparency(_ image: CGImage) -> Bool {
        guard hasAlpha(image) else { return false }
        let width = image.width
        let height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let data = context.data else { return true }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let alpha = data.bindMemory(to: UInt8.self, capacity: width * height)
        for offset in 0..<(width * height) where alpha[offset] < 255 { return true }
        return false
    }

    static func flatten(_ image: CGImage, background: CGColor = CGColor(gray: 1, alpha: 1)) throws -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        guard let context = bitmapContext(size) else { throw outOfMemory(size) }
        context.setFillColor(background)
        context.fill(CGRect(origin: .zero, size: size))
        context.draw(image, in: CGRect(origin: .zero, size: size))
        guard let result = context.makeImage() else { throw outOfMemory(size) }
        return result
    }

    /// ICO entries must be square and at most 256 px: fit the image on a transparent square.
    static func squareIcon(_ image: CGImage, side: Int) throws -> CGImage {
        let canvas = CGSize(width: side, height: side)
        guard let context = bitmapContext(canvas) else { throw outOfMemory(canvas) }
        let factor = min(CGFloat(side) / CGFloat(image.width), CGFloat(side) / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * factor, height: CGFloat(image.height) * factor)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                                       width: size.width, height: size.height))
        guard let result = context.makeImage() else { throw outOfMemory(canvas) }
        return result
    }

    static func scaled(_ image: CGImage, maxSide: Int) throws -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxSide else { return image }
        let factor = CGFloat(maxSide) / CGFloat(longest)
        let size = CGSize(width: max(1, (CGFloat(image.width) * factor).rounded()), height: max(1, (CGFloat(image.height) * factor).rounded()))
        guard let context = bitmapContext(size) else { throw outOfMemory(size) }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        guard let result = context.makeImage() else { throw outOfMemory(size) }
        return result
    }
}
