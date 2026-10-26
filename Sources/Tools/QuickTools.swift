import AppKit
import CoreImage
import PDFKit
import Quartz
import Vision

// One-click tools on the tools wheel: no editor window, the result goes beside the file.
enum QuickTool: String, CaseIterable {
    case compress, compressToSize = "compress-to", stripMetadata = "strip-metadata", removeBackground = "remove-background"
    case combinePDF = "merge-pdf", splitPages = "split-pdf", extract, zip
    case normalize, mono, trimSilence = "trim-silence", mute, concatVideos = "join-videos"
    case snapshots, waveformVideo = "audio-to-video", readQR = "read-qr"

    var title: String {
        switch self {
        case .compress: return L("Compress")
        case .compressToSize: return L("Compress To…")
        case .stripMetadata: return L("Remove Metadata")
        case .removeBackground: return L("Remove Background")
        case .combinePDF: return L("Combine into PDF")
        case .splitPages: return L("Split PDF")
        case .extract: return L("Extract")
        case .zip: return L("Create ZIP")
        case .normalize: return L("Normalize Volume")
        case .mono: return L("Convert to Mono")
        case .trimSilence: return L("Trim Silence")
        case .mute: return L("Remove Audio")
        case .concatVideos: return L("Join Videos")
        case .snapshots: return L("Frames")
        case .waveformVideo: return L("Audio to Video")
        case .readQR: return L("Read QR Code")
        }
    }

    var symbol: String {
        switch self {
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .compressToSize: return "gauge.with.dots.needle.33percent"
        case .stripMetadata: return "eye.slash"
        case .removeBackground: return "person.crop.rectangle"
        case .combinePDF: return "doc.on.doc"
        case .splitPages: return "scissors"
        case .extract: return "shippingbox"
        case .zip: return "archivebox"
        case .normalize: return "speaker.wave.2"
        case .mono: return "speaker.wave.1"
        case .trimSilence: return "waveform.badge.minus"
        case .mute: return "speaker.slash"
        case .concatVideos: return "film.stack"
        case .snapshots: return "photo.on.rectangle"
        case .waveformVideo: return "waveform.and.magnifyingglass"
        case .readQR: return "qrcode.viewfinder"
        }
    }

    /// Shown in the centre of the wheel while hovering.
    var detail: String {
        switch self {
        case .compress: return L("A lighter copy")
        case .compressToSize: return L("Choose the largest size")
        case .stripMetadata: return L("No GPS, camera or dates")
        case .removeBackground: return L("PNG with transparency")
        case .combinePDF: return L("One PDF")
        case .splitPages: return L("One PDF per page")
        case .extract: return L("Opens the archive")
        case .zip: return L("Compresses into a ZIP")
        case .normalize: return L("Even volume")
        case .mono: return L("A single channel")
        case .trimSilence: return L("Removes silence at the start and end")
        case .mute: return L("Video without sound")
        case .concatVideos: return L("One continuous video")
        case .snapshots: return L("12 pictures from the video")
        case .waveformVideo: return L("MP4 with a waveform")
        case .readQR: return L("Copies the text")
        }
    }

    /// Batch tools produce one result from all files; the rest run per file.
    var isBatch: Bool { [.combinePDF, .zip, .concatVideos].contains(self) }

    func applies(to urls: [URL]) -> Bool {
        let formats = urls.compactMap(Format.detect)
        let allKnown = formats.count == urls.count
        func all(_ test: (Format) -> Bool) -> Bool { allKnown && !formats.isEmpty && formats.allSatisfy(test) }
        switch self {
        case .compress: return all { [.image, .audio, .video].contains($0.group) || $0 == .pdf }
        case .compressToSize: return all { ([.image, .audio, .video].contains($0.group) && $0 != .svg) }
        case .stripMetadata: return all { [.image, .audio, .video].contains($0.group) || $0 == .pdf }
        case .removeBackground: return all { $0.group == .image && $0 != .svg } && Tools.canRemoveBackground
        case .combinePDF: return urls.count >= 1 && all { $0 == .pdf || $0.group == .image } && (urls.count > 1 || formats.first != .pdf)
        case .splitPages: return all { $0 == .pdf }
        case .extract: return all { $0.group == .archive }
        case .zip: return !urls.isEmpty
        case .normalize: return all { [.audio, .video].contains($0.group) }
        case .mono: return all { [.audio, .video].contains($0.group) }
        case .trimSilence: return all { $0.group == .audio }
        case .mute: return all { $0.group == .video }
        case .concatVideos: return urls.count >= 2 && all { $0.group == .video }
        case .snapshots: return all { $0.group == .video }
        case .waveformVideo: return all { $0.group == .audio }
        case .readQR: return all { $0.group == .image || $0 == .pdf }
        }
    }

    static func available(for urls: [URL]) -> [QuickTool] {
        allCases.filter { $0.applies(to: urls) }
    }

    struct Result {
        var outputs: [URL] = []
        var message: String?
    }

    /// `targetBytes` is the size chosen for "Compress To…".
    func run(_ urls: [URL], targetBytes: Int? = nil) throws -> Result {
        for url in urls { try FileCheck.preflight(url, allowFolders: self == .zip) }
        switch self {
        case .combinePDF: return Result(outputs: [try Tools.combinePDF(urls)])
        case .zip: return Result(outputs: [try Tools.zip(urls)])
        case .concatVideos: return Result(outputs: [try Tools.concatVideos(urls)])
        default:
            var result = Result()
            var messages: [String] = []
            for url in urls {
                let single = try runSingle(url, targetBytes: targetBytes)
                result.outputs += single.outputs
                if let message = single.message { messages.append(message) }
            }
            result.message = messages.isEmpty ? nil : messages.joined(separator: "\n")
            return result
        }
    }

    private func runSingle(_ url: URL, targetBytes: Int?) throws -> Result {
        switch self {
        case .compress: return Result(outputs: [try Tools.compress(url)])
        case .compressToSize:
            guard let targetBytes else { throw Problem(L("No size was chosen.")) }
            return Result(outputs: [try TargetSize.compress(url, toFit: targetBytes)])
        case .stripMetadata: return Result(outputs: [try Tools.stripMetadata(url)])
        case .removeBackground: return Result(outputs: [try Tools.removeBackground(url)])
        case .splitPages: return Result(outputs: [try Tools.splitPages(url)])
        case .extract: return Result(outputs: try ArchiveTools.extract(url))
        case .normalize: return Result(outputs: [try Tools.normalize(url)])
        case .mono: return Result(outputs: [try Tools.mono(url)])
        case .trimSilence: return Result(outputs: [try Tools.trimSilence(url)])
        case .mute: return Result(outputs: [try Tools.mute(url)])
        case .snapshots: return Result(outputs: [try Tools.snapshots(url)])
        case .waveformVideo: return Result(outputs: [try Tools.waveformVideo(url)])
        case .readQR:
            let codes = try Tools.readQR(url)
            return Result(outputs: [], message: codes.joined(separator: "\n"))
        case .combinePDF, .zip, .concatVideos:
            return try run([url])
        }
    }
}

enum Tools {
    // MARK: Compress

    static func compress(_ url: URL) throws -> URL {
        guard let format = Format.detect(url) else { throw Explain.noTargets([url], tools: true) }
        let originalSize = fileSize(url)
        let out: URL
        switch format.group {
        case .image:
            out = try compressImage(url, format: format)
        case .video:
            out = Output.url(for: url, ext: "mp4", suffix: " (" + L("compressed") + ")")
            try MediaConverter.encode(url, ["-map", "0:v:0", "-map", "0:a:0?"] + MediaConverter.h264Arguments(maxHeight: 1080, quality: .compact)
                                      + ["-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", "-map_metadata", "0"],
                                      to: out, what: L("Compressing the video"))
        case .audio:
            // Lossless sources become AAC; lossy ones are re-encoded at a lower bitrate.
            let target: Format = [.wav, .aiff, .flac].contains(format) ? .m4a : format
            out = Output.url(for: url, ext: target.ext, suffix: " (" + L("compressed") + ")")
            try MediaConverter.encode(url, ["-vn"] + MediaConverter.audioArguments(target, bitrate: "128k") + ["-map_metadata", "0"],
                                      to: out, what: L("Compressing the audio"))
        default:
            out = try compressPDF(url)
        }
        if fileSize(out) >= originalSize {
            Output.discard(out)
            throw Problem(L("“%@” is already well compressed: the new version wouldn’t be smaller, so it wasn’t saved.", url.lastPathComponent),
                                  suggestion: L("To make it smaller, convert to a more efficient format (for example HEIC or WebP for images, MP4 for videos)."))
        }
        return out
    }

    static func compressImage(_ url: URL, format: Format) throws -> URL {
        let target: Format = [.svg, .ico].contains(format) ? .png : format
        let out = Output.url(for: url, ext: target.ext, suffix: " (" + L("compressed") + ")")
        if format == .webp {
            let cwebp = try Engines.require("cwebp", brew: "webp")
            let temp = Output.tempSibling(of: out)
            try runChecked(cwebp, ["-quiet", "-q", "60", "-resize", "0", "0", "-metadata", "icc", url.path, "-o", temp.path], what: L("Compressing the WebP"))
            try Output.commit(temp, to: out)
            return out
        }
        let source = try ImageConverter.open(url)
        let image = try ImageConverter.orientedImage(source, maxPixelSize: 2560)
        let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        try ImageConverter.write(image, metadata: metadata, to: out, as: target, quality: .compact)
        return out
    }

    static func compressPDF(_ url: URL) throws -> URL {
        let document = try PDFTools.open(url)
        let filterURL = URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")
        guard let filter = QuartzFilter(url: filterURL) else {
            throw Problem(L("The macOS “Reduce File Size” filter isn’t available on this Mac."),
                                  suggestion: L("This filter is part of macOS; if it was removed, open the PDF in Preview and use File › Export › Quartz Filter."))
        }
        let out = Output.url(for: url, ext: "pdf", suffix: " (" + L("compressed") + ")")
        let temp = Output.tempSibling(of: out)
        let options: [PDFDocumentWriteOption: Any] = [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]
        guard document.write(to: temp, withOptions: options), PDFDocument(url: temp) != nil else {
            Output.discard(temp)
            throw Problem(L("macOS couldn’t create the compressed version of “%@”.", url.lastPathComponent),
                                  suggestion: L("Some PDFs (forms, PDF/A, signed) don’t accept this filter. Try “Remove Metadata” or convert to images."))
        }
        try Output.commit(temp, to: out)
        return out
    }

    // MARK: Metadata

    static func stripMetadata(_ url: URL) throws -> URL {
        guard let format = Format.detect(url) else { throw Explain.noTargets([url], tools: true) }
        let out = Output.url(for: url, ext: format.ext, suffix: " (" + L("no metadata") + ")")
        switch format.group {
        case .image:
            let exiftool = try Engines.require("exiftool")
            let temp = Output.tempSibling(of: out)
            // Drop everything but keep orientation and colour profile so the photo looks the same.
            try runChecked(exiftool, ["-q", "-all=", "-tagsFromFile", "@", "-Orientation", "-ICC_Profile", "-o", temp.path, url.path],
                           what: L("Removing the metadata"))
            try Output.commit(temp, to: out)
        case .audio, .video:
            try MediaConverter.encode(url, ["-map", "0:v?", "-map", "0:a?", "-map", "0:s?", "-c", "copy",
                                            "-map_metadata", "-1", "-map_chapters", "-1", "-fflags", "+bitexact"],
                                      to: out, what: L("Removing the metadata"))
        default:
            let document = try PDFTools.open(url)
            document.documentAttributes = [:]
            let temp = Output.tempSibling(of: out)
            guard document.write(to: temp) else {
                throw Problem(L("PDFKit couldn’t save the clean copy of “%@”.", url.lastPathComponent),
                                      suggestion: FileCheck.privacyHint(for: url.deletingLastPathComponent()))
            }
            try Output.commit(temp, to: out)
        }
        return out
    }

    // MARK: PDF

    static func combinePDF(_ urls: [URL]) throws -> URL {
        let sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let merged = PDFDocument()
        for url in sorted {
            if Format.detect(url) == .pdf {
                let document = try PDFTools.open(url)
                for index in 0..<document.pageCount {
                    if let page = document.page(at: index)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
                }
            } else {
                let image = try ImageConverter.loadImage(url)
                let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                guard let page = PDFPage(image: nsImage) else {
                    throw Problem(L("The image “%@” couldn’t be turned into a PDF page.", url.lastPathComponent),
                                          suggestion: L("Convert it to JPG or PNG first."))
                }
                merged.insert(page, at: merged.pageCount)
            }
        }
        let name = sorted.count == 1 ? Output.baseName(sorted[0]) : Output.baseName(sorted[0]) + " (" + L("combined") + ")"
        let out = Output.unique(sorted[0].deletingLastPathComponent().appendingPathComponent(name + ".pdf"))
        let temp = Output.tempSibling(of: out)
        guard merged.write(to: temp) else {
            throw Problem(L("PDFKit couldn’t save the combined PDF."), suggestion: FileCheck.privacyHint(for: out.deletingLastPathComponent()))
        }
        try Output.commit(temp, to: out)
        return out
    }

    static func splitPages(_ url: URL) throws -> URL {
        let document = try PDFTools.open(url)
        let folder = Output.folder(for: url, suffix: " (" + L("pages") + ")")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let digits = String(document.pageCount).count
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            let number = String(format: "%0\(digits)d", index + 1)
            guard single.write(to: folder.appendingPathComponent(Output.baseName(url) + " - " + L("page %@", number) + ".pdf")) else {
                throw Problem(L("Page %@ couldn’t be saved as a separate PDF.", index + 1),
                                      suggestion: L("Check that there is disk space and permission to write in the folder."))
            }
        }
        return folder
    }

    // MARK: Archives

    static func zip(_ urls: [URL]) throws -> URL {
        let name = urls.count == 1 ? urls[0].lastPathComponent : L("Archive")
        let out = Output.unique(urls[0].deletingLastPathComponent().appendingPathComponent(name + ".zip"))
        try ArchiveTools.pack(urls, as: .zip, to: out)
        return out
    }

    // MARK: Audio / video

    static func normalize(_ url: URL) throws -> URL {
        guard let format = Format.detect(url) else { throw Explain.noTargets([url], tools: true) }
        let info = try MediaConverter.probe(url)
        guard info.containsAudio else { throw Problem(L("“%@” has no sound, so there is no volume to normalize.", url.lastPathComponent)) }
        let out = Output.url(for: url, ext: format.ext, suffix: " (" + L("normalized") + ")")
        var args = ["-map", "0:v?", "-map", "0:a:0", "-af", "loudnorm=I=-16:LRA=11:TP=-1.5", "-ar", "48000"]
        if format.group == .video {
            args += ["-c:v", "copy"] + MediaConverter.audioArgumentsForContainer(format)
        } else {
            args += MediaConverter.audioArguments(format)
        }
        try MediaConverter.encode(url, args + ["-map_metadata", "0"], to: out, what: L("Normalizing the volume"))
        return out
    }

    static func mute(_ url: URL) throws -> URL {
        guard let format = Format.detect(url) else { throw Explain.noTargets([url], tools: true) }
        let out = Output.url(for: url, ext: format.ext, suffix: " (" + L("no audio") + ")")
        try MediaConverter.encode(url, ["-map", "0:v", "-c", "copy", "-an", "-map_metadata", "0"], to: out, what: L("Removing the audio"))
        return out
    }

    static func concatVideos(_ urls: [URL]) throws -> URL {
        let sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let probes = try sorted.map(MediaConverter.probe)
        guard let first = probes.first, first.width > 0, first.height > 0 else {
            throw Problem(L("The first video (“%@”) has no picture or its dimensions are invalid.", sorted[0].lastPathComponent),
                                  suggestion: L("Videos are joined in name order and at the size of the first one. Check that the first one opens in QuickTime."))
        }
        let width = first.width / 2 * 2
        let height = first.height / 2 * 2
        var inputs: [String] = []
        for url in sorted { inputs += MediaConverter.localInput(url) }
        var filter = ""
        var concatInputs = ""
        var silentIndex = sorted.count
        for (index, probe) in probes.enumerated() {
            filter += "[\(index):v:0]scale=\(width):\(height):force_original_aspect_ratio=decrease:force_divisible_by=2,"
                + "pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,format=yuv420p[v\(index)];"
            if probe.containsAudio {
                filter += "[\(index):a:0]aresample=48000,aformat=channel_layouts=stereo[a\(index)];"
            } else {
                // Silent clips get generated silence so concat keeps audio in sync.
                inputs += ["-f", "lavfi", "-t", String(format: "%.3f", max(probe.duration, 0.1)), "-i", "anullsrc=r=48000:cl=stereo"]
                filter += "[\(silentIndex):a:0]anull[a\(index)];"
                silentIndex += 1
            }
            concatInputs += "[v\(index)][a\(index)]"
        }
        filter += "\(concatInputs)concat=n=\(sorted.count):v=1:a=1[v][a]"
        let out = Output.unique(sorted[0].deletingLastPathComponent().appendingPathComponent(Output.baseName(sorted[0]) + " (" + L("joined") + ").mp4"))
        let temp = Output.tempSibling(of: out)
        let args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"] + inputs + [
            "-filter_complex", filter, "-map", "[v]", "-map", "[a]",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", Settings.quality.x264CRF,
            "-c:a", "aac", "-b:a", Settings.quality.audioKbps, "-movflags", "+faststart", temp.path,
        ]
        do {
            try runChecked(try MediaConverter.ffmpeg(), args, what: L("Joining the videos"))
        } catch {
            Output.discard(temp)
            throw error
        }
        try Output.commit(temp, to: out)
        return out
    }


    // MARK: Background removal (Vision, on this Mac)

    static var canRemoveBackground: Bool { NSClassFromString("VNGenerateForegroundInstanceMaskRequest") != nil }

    /// Subject lifting as in Photos: Vision's foreground instance mask (macOS 14+), called
    /// dynamically because this project builds against the macOS 13 SDK.
    static func removeBackground(_ url: URL) throws -> URL {
        guard let requestClass = NSClassFromString("VNGenerateForegroundInstanceMaskRequest") as? NSObject.Type,
              let request = requestClass.init() as? VNRequest else {
            throw Problem(L("Removing the background needs macOS 14 (Sonoma) or later."))
        }
        let image = try ImageConverter.loadImage(url)
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        guard let observation = request.results?.first as? NSObject,
              let instances = observation.value(forKey: "allInstances") as? IndexSet, !instances.isEmpty else {
            throw Problem(L("No main subject was found in “%@”.", url.lastPathComponent),
                                  suggestion: L("It works best with people, animals and objects that stand out from the background."))
        }
        let selector = NSSelectorFromString("generateMaskedImageOfInstances:fromRequestHandler:croppedToInstancesExtent:error:")
        guard observation.responds(to: selector) else {
            throw Problem(L("This version of macOS can’t cut out the subject."), suggestion: L("Update macOS and try again."))
        }
        typealias Generate = @convention(c) (AnyObject, Selector, NSIndexSet, VNImageRequestHandler, ObjCBool,
                                             UnsafeMutablePointer<NSError?>?) -> Unmanaged<CVPixelBuffer>?
        let generate = unsafeBitCast(observation.method(for: selector), to: Generate.self)
        var error: NSError?
        guard let buffer = generate(observation, selector, instances as NSIndexSet, handler, ObjCBool(false), &error)?.takeUnretainedValue() else {
            throw Problem(L("Vision couldn’t cut out the subject of “%@”.", url.lastPathComponent),
                                  suggestion: error?.localizedDescription)
        }
        let masked = CIImage(cvPixelBuffer: buffer)
        guard let result = Imaging.cgImage(masked) else { throw ImageConverter.outOfMemory(masked.extent.size) }
        let out = Output.url(for: url, ext: "png", suffix: " (" + L("no background") + ")")
        try ImageConverter.write(result, metadata: nil, to: out, as: .png)
        return out
    }

    // MARK: More audio and video

    static func mono(_ url: URL) throws -> URL {
        guard let format = Format.detect(url) else { throw Explain.noTargets([url], tools: true) }
        let info = try MediaConverter.probe(url)
        guard info.containsAudio else { throw Problem(L("“%@” has no sound to convert to mono.", url.lastPathComponent)) }
        let out = Output.url(for: url, ext: format.ext, suffix: " (" + L("mono") + ")")
        // The built-in Vorbis encoder only writes stereo: the same mono signal goes to both sides.
        let downmix = format == .ogg ? ["-af", "pan=stereo|c0=0.5*c0+0.5*c1|c1=0.5*c0+0.5*c1"] : []
        var args = ["-map", "0:v?", "-map", "0:a:0"] + downmix
        if format.group == .video {
            args += ["-c:v", "copy"] + MediaConverter.audioArgumentsForContainer(format)
        } else {
            args += MediaConverter.audioArguments(format)
        }
        if format != .ogg { args += ["-ac", "1"] }
        try MediaConverter.encode(url, args + ["-map_metadata", "0"], to: out, what: L("Converting to mono"))
        return out
    }

    static func trimSilence(_ url: URL) throws -> URL {
        guard let format = Format.detect(url) else { throw Explain.noTargets([url], tools: true) }
        let info = try MediaConverter.probe(url)
        guard info.containsAudio else { throw Problem(L("“%@” has no sound.", url.lastPathComponent)) }
        guard info.duration < 3 * 3600 else {
            throw Problem(L("“%@” is longer than 3 hours, too long to trim silence in one go.", url.lastPathComponent),
                                  suggestion: L("Cut it into parts with the audio editor first."))
        }
        // start_duration must be 0: in ffmpeg 9 it also trims that much of the sound itself.
        // start_silence keeps 50 ms so the cut is not abrupt and a second pass finds nothing.
        let edge = "silenceremove=start_periods=1:start_duration=0:start_silence=0.05:start_threshold=-50dB:detection=peak"
        let out = Output.url(for: url, ext: format.ext, suffix: " (" + L("silence trimmed") + ")")
        try MediaConverter.encode(url, ["-vn", "-af", "\(edge),areverse,\(edge),areverse"] + MediaConverter.audioArguments(format) + ["-map_metadata", "0"],
                                  to: out, what: L("Trimming the silence"))
        let result = (try? MediaConverter.probe(out))?.duration ?? info.duration
        if info.duration - result < 0.05 {
            Output.discard(out)
            throw Problem(L("“%@” has no silence at the start or the end, so there was nothing to trim.", url.lastPathComponent),
                                  suggestion: L("Only sound below −50 dB counts as silence."))
        }
        return out
    }

    /// Twelve evenly spaced frames, full resolution, in a folder next to the video.
    static func snapshots(_ url: URL) throws -> URL {
        let info = try MediaConverter.probe(url)
        guard info.hasVideo, info.duration > 0 else {
            throw Problem(L("“%@” has no picture to take frames from.", url.lastPathComponent))
        }
        let folder = Output.folder(for: url, suffix: " (" + L("frames") + ")")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let count = 12
        for index in 0..<count {
            let time = info.duration * (Double(index) + 0.5) / Double(count)
            let out = folder.appendingPathComponent(String(format: L("Video frame") + " %02d.png", index + 1))
            try MediaConverter.encode(url, ["-frames:v", "1", "-update", "1"], to: out, what: L("Capturing frame %@", index + 1),
                                      inputArguments: ["-ss", String(format: "%.3f", time)], duration: 1)
            JobProgress.report(Double(index + 1) / Double(count))
        }
        return folder
    }

    /// A shareable video of the sound wave: white on black, like the app.
    static func waveformVideo(_ url: URL) throws -> URL {
        let info = try MediaConverter.probe(url)
        guard info.containsAudio else { throw Problem(L("“%@” has no sound.", url.lastPathComponent)) }
        let color = "0xF2F2F2"
        let out = Output.url(for: url, ext: "mp4", suffix: " (" + L("video") + ")")
        let filter = "[0:a]aformat=channel_layouts=mono,showwaves=s=1280x720:mode=cline:rate=30:colors=\(color),format=yuv420p[v]"
        try MediaConverter.encode(url, ["-filter_complex", filter, "-map", "[v]", "-map", "0:a:0", "-c:v", "libx264", "-preset", "veryfast",
                                        "-crf", "23", "-c:a", "aac", "-b:a", Settings.quality.audioKbps, "-shortest", "-movflags", "+faststart"],
                                  to: out, what: L("Creating the video"), duration: info.duration)
        return out
    }

    // MARK: QR codes

    static func readQR(_ url: URL) throws -> [String] {
        var images: [CGImage] = []
        if Format.detect(url) == .pdf {
            let document = try PDFTools.open(url)
            for index in 0..<min(document.pageCount, 20) {
                if let page = document.page(at: index), let image = PDFTools.pageImage(page, scale: 3) { images.append(image) }
            }
        } else {
            images.append(try ImageConverter.loadImage(url))
        }
        var codes: [String] = []
        for image in images {
            let request = VNDetectBarcodesRequest()
            try VNImageRequestHandler(cgImage: image).perform([request])
            for observation in request.results ?? [] {
                if let payload = observation.payloadStringValue, !codes.contains(payload) { codes.append(payload) }
            }
        }
        guard !codes.isEmpty else {
            throw Problem(L("No QR code or barcode was found in “%@”.", url.lastPathComponent),
                                  suggestion: L("The code has to be sharp, whole and not too small. If it is a photo, crop around the code and try again."))
        }
        return codes
    }

    static func fileSize(_ url: URL) -> Int64 {
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 { return size }
        // Folders (split outputs) are measured by their contents.
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let item = enumerator?.nextObject() as? URL {
            total += Int64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
