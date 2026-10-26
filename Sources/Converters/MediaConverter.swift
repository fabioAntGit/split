import Foundation
import CoreGraphics

// Audio and video through ffmpeg. Every track, subtitle, chapter and tag the target can
// hold goes along; streams that already fit the container are copied untouched, and what
// the container can't hold is told to the user (see `Fidelity`).
enum MediaConverter: ConversionFamily {
    static let audioTargets: [Format] = [.mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma]
    static let videoTargets: [Format] = [.mp4, .mov, .mkv, .webm, .avi, .wmv, .gif]

    static func targets(from source: Format) -> [Format] {
        switch source.group {
        case .audio: return audioTargets
        case .video: return videoTargets + audioTargets
        case .subtitle: return [.srt, .vtt]
        default: return []
        }
    }

    static func convert(_ url: URL, from source: Format, to target: Format) throws -> [URL] {
        source.group == .subtitle ? try subtitle(url, to: target) : try transcode(url, from: source, to: target)
    }

    /// One stream of a media file, as ffprobe describes it.
    struct Stream {
        var index = 0
        var type = ""
        var codec = ""
        var isCover = false
        var channels = 0
        var sampleFormat = ""
        var bits = 0
        var transfer = ""
    }

    struct Probe {
        var videoEncoder: String?
        var audioEncoder: String?
        var width = 0
        var height = 0
        var rotation = 0
        var duration: Double = 0
        var chapters = 0
        var streams: [Stream] = []
        var hasVideo: Bool { videoEncoder != nil }
        var containsAudio: Bool { audioEncoder != nil }
        /// Size as played (phones store portrait video as rotated landscape).
        var displaySize: CGSize {
            abs(rotation) % 180 == 90 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        }
        var videos: [Stream] { streams.filter { $0.type == "video" && !$0.isCover } }
        var audios: [Stream] { streams.filter { $0.type == "audio" } }
        var covers: [Stream] { streams.filter { $0.type == "video" && $0.isCover } }
        var subtitles: [Stream] { streams.filter { $0.type == "subtitle" } }
        var attachments: [Stream] { streams.filter { $0.type == "attachment" || $0.type == "data" } }
        /// PQ (HDR10, Dolby Vision) or HLG: needs 10 bits and its colour tags to look right.
        var isHDR: Bool { videos.first.map { ["smpte2084", "arib-std-b67"].contains($0.transfer) } ?? false }
    }

    static func ffmpeg() throws -> String { try Engines.require("ffmpeg") }

    static func probe(_ url: URL) throws -> Probe {
        let ffprobe = try Engines.require("ffprobe", brew: "ffmpeg")
        let result = try runChecked(ffprobe, [
            "-v", "error", "-show_entries",
            "stream=index,codec_type,codec_name,width,height,channels,sample_fmt,bits_per_raw_sample,color_transfer"
                + ":stream_disposition=attached_pic:stream_side_data=rotation:stream_tags=rotate:format=duration",
            "-show_chapters", "-of", "json", "-protocol_whitelist", "file", url.path,
        ], what: L("Reading the file"))
        guard let json = (try? JSONSerialization.jsonObject(with: result.stdoutData)) as? [String: Any] else {
            throw Problem(L("ffprobe could not describe “%@”.", url.lastPathComponent),
                          suggestion: L("The file may be damaged or not be audio or video."))
        }
        var probe = Probe()
        for stream in json["streams"] as? [[String: Any]] ?? [] {
            let disposition = stream["disposition"] as? [String: Any]
            var info = Stream()
            info.index = stream["index"] as? Int ?? probe.streams.count
            info.type = stream["codec_type"] as? String ?? ""
            info.codec = stream["codec_name"] as? String ?? "unknown"
            info.isCover = (disposition?["attached_pic"] as? Int) == 1
            info.channels = stream["channels"] as? Int ?? 0
            info.sampleFormat = stream["sample_fmt"] as? String ?? ""
            info.bits = Int(stream["bits_per_raw_sample"] as? String ?? "") ?? 0
            info.transfer = stream["color_transfer"] as? String ?? ""
            probe.streams.append(info)
            if info.type == "video", !info.isCover, probe.videoEncoder == nil {
                probe.videoEncoder = info.codec
                probe.width = stream["width"] as? Int ?? 0
                probe.height = stream["height"] as? Int ?? 0
                let sideData = stream["side_data_list"] as? [[String: Any]] ?? []
                if let rotation = sideData.compactMap({ $0["rotation"] as? Int }).first {
                    probe.rotation = rotation
                } else if let tags = stream["tags"] as? [String: Any], let rotate = Int(tags["rotate"] as? String ?? "") {
                    probe.rotation = rotate
                }
            } else if info.type == "audio", probe.audioEncoder == nil {
                probe.audioEncoder = info.codec
            }
        }
        if let format = json["format"] as? [String: Any], let duration = format["duration"] as? String {
            probe.duration = Double(duration) ?? 0
        }
        probe.chapters = (json["chapters"] as? [Any])?.count ?? 0
        return probe
    }

    /// Checks the result against the source and says what didn't make it across.
    static func compare(_ source: Probe, with out: URL, target: Format) {
        guard let result = try? probe(out) else { return }
        if Settings.keepsMetadata && source.chapters > 0 && result.chapters == 0 {
            Fidelity.note(L("%@ doesn’t keep chapters, so the %@ chapter marks were left out.", target.label, String(source.chapters)))
        }
        if target.group == .video && result.audios.count < source.audios.count {
            Fidelity.note(L("Only %@ of the %@ audio tracks fit in %@.", String(result.audios.count), String(source.audios.count), target.label))
        }
    }

    static func transcode(_ url: URL, from source: Format, to target: Format) throws -> [URL] {
        let info = try probe(url)
        if target.group == .audio && !info.containsAudio {
            throw Problem(L("“%@” has no sound, so a %@ can’t be made from it.", url.lastPathComponent, target.label),
                          suggestion: L("The video was recorded or exported without an audio track."))
        }
        if (target.group == .video || target == .gif) && !info.hasVideo {
            throw Problem(L("“%@” has no picture, so a %@ can’t be made from it.", url.lastPathComponent, target.label),
                          suggestion: info.containsAudio ? L("It is audio only. To make a video from sound, use “Audio to Video” on the tools wheel.") : nil)
        }
        let out = Output.url(for: url, ext: target.ext)
        let metadata = Settings.keepsMetadata ? ["-map_metadata", "0", "-map_chapters", "0"] : ["-map_metadata", "-1", "-map_chapters", "-1"]
        let what = L("Converting to %@", target.label)

        if target.group == .audio {
            try encode(url, audioOnlyArguments(info, to: target) + metadata, to: out, what: what)
            compare(info, with: out, target: target)
            return [out]
        }
        if target == .gif {
            if info.containsAudio { Fidelity.note(L("GIF has no sound, so the audio was left out. MP4 or WebM keep it.")) }
            try encode(url, videoArguments(target, info), to: out, what: what)
            return [out]
        }
        // Copy what already fits the new container and re-encode only the rest, so the
        // picture isn't touched when only the audio needs changing.
        let plan = StreamPlan(info, target: target)
        do {
            try encode(url, plan.arguments(copyVideo: plan.canCopyVideo, copyAudio: plan.canCopyAudio) + metadata, to: out, what: what)
        } catch where plan.canCopyVideo || plan.canCopyAudio {
            try encode(url, plan.arguments(copyVideo: false, copyAudio: false) + metadata, to: out, what: what)
        }
        plan.reportLosses()
        compare(info, with: out, target: target)
        return [out]
    }

    /// Audio files keep the first track, its tags and chapters, the cover where the format
    /// has room for one, the bit depth of lossless sources and every channel the format can hold.
    static func audioOnlyArguments(_ info: Probe, to target: Format) -> [String] {
        guard let first = info.audios.first else { return ["-vn"] + audioArguments(target) }
        var args = ["-map", "0:\(first.index)"]
        if info.audios.count > 1 {
            Fidelity.note(L("%@ holds one audio track, so only the first of %@ was kept.", target.label, String(info.audios.count)))
        }
        let coverTargets: Set<Format> = [.mp3, .m4a, .flac, .aiff]
        if let cover = info.covers.first, Settings.keepsMetadata {
            if coverTargets.contains(target) {
                // MP4 covers must be JPEG or PNG; the others take the picture as it is.
                let codec = target == .m4a && !["mjpeg", "png"].contains(cover.codec) ? "png" : "copy"
                args += ["-map", "0:\(cover.index)", "-c:v", codec, "-disposition:v:0", "attached_pic"]
            } else {
                Fidelity.note(L("%@ has no place for cover art, so the cover was left out. MP3, M4A, FLAC or AIFF keep it.", target.label))
            }
        } else {
            args += ["-vn"]
        }
        if target == .aiff { args += ["-write_id3v2", "1"] }
        if [.mp3, .wma].contains(target), first.channels > 2 {
            args += ["-ac", "2"]
            Fidelity.note(L("%@ holds at most two channels, so the surround sound was mixed down to stereo.", target.label))
        }
        if target == .ogg && first.channels > 2 {
            // The built-in Vorbis encoder is stereo only; Opus in an Ogg file keeps every channel.
            return args + ["-c:a", "libopus", "-b:a", Settings.quality.audioKbps]
        }
        return args + audioArguments(target, depthOf: first)
    }

    /// Which streams go into a video container and which of them can be copied as they are.
    struct StreamPlan {
        let info: Probe
        let target: Format

        init(_ info: Probe, target: Format) {
            self.info = info
            self.target = target
        }

        static let textSubtitles: Set<String> = ["subrip", "ass", "ssa", "webvtt", "mov_text", "text"]

        var canCopyVideo: Bool {
            guard let video = info.videos.first?.codec else { return false }
            switch target {
            case .mp4: return ["h264", "hevc", "av1", "mpeg4"].contains(video)
            case .mov: return ["h264", "hevc", "prores", "mpeg4", "mjpeg"].contains(video)
            case .mkv: return video != "gif"
            case .webm: return ["vp8", "vp9", "av1"].contains(video)
            default: return false
            }
        }

        var canCopyAudio: Bool {
            let codecs = info.audios.map(\.codec)
            switch target {
            case .mp4, .mov: return codecs.allSatisfy { ["aac", "mp3", "alac", "ac3", "eac3"].contains($0) }
            case .mkv: return true
            case .webm: return codecs.allSatisfy { ["opus", "vorbis"].contains($0) }
            default: return false
            }
        }

        /// Subtitle tracks the container can hold, and the codec to write them with.
        var subtitles: (kept: [Stream], codec: String?) {
            switch target {
            case .mkv: return (info.subtitles, "copy")
            case .mp4, .mov: return (info.subtitles.filter { StreamPlan.textSubtitles.contains($0.codec) }, "mov_text")
            case .webm: return (info.subtitles.filter { StreamPlan.textSubtitles.contains($0.codec) }, "webvtt")
            default: return ([], nil)
            }
        }

        func arguments(copyVideo: Bool, copyAudio: Bool) -> [String] {
            guard let video = info.videos.first else { return [] }
            var args = ["-map", "0:\(video.index)"]
            for audio in info.audios { args += ["-map", "0:\(audio.index)"] }
            let subs = subtitles
            for subtitle in subs.kept { args += ["-map", "0:\(subtitle.index)"] }
            if target == .mkv { for attachment in info.attachments where attachment.type == "attachment" { args += ["-map", "0:\(attachment.index)"] } }

            if copyVideo {
                args += ["-c:v", "copy"]
                if video.codec == "hevc" && (target == .mp4 || target == .mov) { args += ["-tag:v", "hvc1"] }
            } else {
                args += MediaConverter.encodeVideo(target, info)
            }
            if !info.audios.isEmpty {
                args += copyAudio ? ["-c:a", "copy"] : MediaConverter.audioArgumentsForContainer(target)
            }
            if let codec = subs.codec, !subs.kept.isEmpty { args += ["-c:s", codec] }
            if target == .mkv && !info.attachments.isEmpty { args += ["-c:t", "copy"] }
            if target == .mp4 || target == .mov { args += ["-movflags", "+faststart"] }
            return args
        }

        func reportLosses() {
            let droppedSubtitles = info.subtitles.count - subtitles.kept.count
            if droppedSubtitles > 0 {
                Fidelity.note(L("%@ of the subtitle tracks were left out: %@ can’t hold them. MKV keeps every track.", String(droppedSubtitles), target.label))
            }
            if target != .mkv && info.attachments.contains(where: { $0.type == "attachment" }) {
                Fidelity.note(L("Files attached to the video (such as subtitle fonts) were left out: only MKV holds them."))
            }
            if info.videos.count > 1 {
                Fidelity.note(L("Only the first of the %@ video tracks was kept.", String(info.videos.count)))
            }
            if info.isHDR && !canCopyVideo && [.avi, .wmv].contains(target) {
                Fidelity.note(L("The video is HDR and %@ only holds standard range, so the colors may look flatter.", target.label))
            }
        }
    }

    static func subtitle(_ url: URL, to target: Format) throws -> [URL] {
        let out = Output.url(for: url, ext: target.ext)
        if target == .srt, let text = try? DocumentPipeline.readText(url),
           text.contains("\nSTYLE") || text.range(of: #"-->[^\n]*\b(line|position|align|size|vertical):"#, options: .regularExpression) != nil {
            Fidelity.note(L("SRT has no place for WebVTT positions and styles, so the subtitles show in the default place and style."))
        }
        // ffmpeg reads subtitles as UTF-8, so older Windows or Mac files go through a UTF-8 copy.
        let utf8 = TextDecoding.utf8(try Data(contentsOf: url))
        guard !utf8.wasUTF8 else {
            try encode(url, [], to: out, what: L("Converting subtitles"))
            return [out]
        }
        let folder = try Output.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appendingPathComponent(url.lastPathComponent)
        try utf8.data.write(to: copy)
        try encode(copy, [], to: out, what: L("Converting subtitles"))
        return [out]
    }

    /// Runs ffmpeg into a hidden temp file and renames it when it succeeds.
    /// `duration` is the length of the result in seconds (for the progress bar); probed when omitted.
    static func encode(_ input: URL, _ arguments: [String], to out: URL, what: String, inputArguments: [String] = [],
                       duration: Double? = nil) throws {
        let temp = Output.tempSibling(of: out)
        let progress = FileManager.default.temporaryDirectory.appendingPathComponent("split-progress-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: progress) }
        let total = duration ?? ((try? probe(input))?.duration ?? 0)
        let args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-progress", progress.path]
            + inputArguments + localInput(input) + arguments + [temp.path]
        do {
            try runChecked(try ffmpeg(), args, what: what, monitor: { reportProgress(progress, total: total) })
        } catch {
            Output.discard(temp)
            throw error
        }
        try Output.commit(temp, to: out)
    }

    /// ffmpeg's `-progress` file reports the encoded position as out_time_us.
    static func reportProgress(_ file: URL, total: Double) {
        guard total > 0, let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        guard let line = text.split(separator: "\n").last(where: { $0.hasPrefix("out_time_us=") }),
              let micro = Double(line.dropFirst("out_time_us=".count)) else { return }
        JobProgress.report(micro / 1_000_000 / total)
    }

    /// Input restricted to local files: a crafted playlist inside a "video" can't make ffmpeg reach the network.
    static func localInput(_ url: URL) -> [String] {
        ["-protocol_whitelist", "file", "-i", url.path]
    }

    // MARK: Argument builders

    /// `depthOf` keeps 24- and 32-bit lossless audio at its depth in WAV and AIFF.
    static func audioArguments(_ target: Format, bitrate: String = Settings.quality.audioKbps, depthOf source: Stream? = nil) -> [String] {
        let lossless: Set<String> = ["flac", "alac", "wavpack", "ape", "tta", "truehd", "mlp"]
        let isLossless = source.map { lossless.contains($0.codec) || $0.codec.hasPrefix("pcm_") } ?? false
        let depth = !isLossless ? 16 : (source?.sampleFormat.hasPrefix("flt") == true || source?.sampleFormat.hasPrefix("dbl") == true
            ? 32 : (source?.bits ?? 0) > 16 || source?.sampleFormat.hasPrefix("s32") == true ? 24 : 16)
        let float = isLossless && (source?.sampleFormat.hasPrefix("flt") == true || source?.sampleFormat.hasPrefix("dbl") == true)
        switch target {
        case .mp3: return ["-c:a", "libmp3lame", "-b:a", bitrate]
        case .m4a: return ["-c:a", "aac", "-b:a", bitrate]
        case .wav: return ["-c:a", float ? "pcm_f32le" : (depth == 24 ? "pcm_s24le" : "pcm_s16le")]
        case .aiff: return ["-c:a", float ? "pcm_f32be" : (depth == 24 ? "pcm_s24be" : "pcm_s16be")]
        case .flac: return ["-c:a", "flac"]
        case .ogg: return ["-c:a", "vorbis", "-strict", "experimental", "-ac", "2", "-b:a", bitrate]
        case .opus: return ["-c:a", "libopus", "-b:a", bitrate]
        case .wma: return ["-c:a", "wmav2", "-b:a", bitrate]
        default: return []
        }
    }

    static let evenDimensions = "scale=trunc(iw/2)*2:trunc(ih/2)*2"

    static func h264Arguments(maxHeight: Int? = nil, quality: Quality = Settings.quality) -> [String] {
        var filter = evenDimensions
        if let maxHeight { filter = "scale=-2:'min(\(maxHeight),ih)'," + evenDimensions }
        return ["-vf", filter, "-c:v", "libx264", "-preset", "veryfast", "-crf", quality.x264CRF, "-pix_fmt", "yuv420p"]
    }

    /// The picture re-encoded for a container (all mapping is done by `StreamPlan`).
    static func encodeVideo(_ target: Format, _ info: Probe) -> [String] {
        switch target {
        case .mp4, .mov, .mkv:
            if info.isHDR {
                // 10-bit HEVC with the source's colour tags, so HDR stays HDR.
                return ["-vf", evenDimensions, "-c:v", "libx265", "-preset", "fast", "-crf", Settings.quality.x264CRF, "-pix_fmt", "yuv420p10le",
                        "-tag:v", "hvc1", "-color_primaries", "bt2020", "-colorspace", "bt2020nc",
                        "-color_trc", info.videos.first?.transfer ?? "smpte2084", "-x265-params", "log-level=error"]
            }
            return ["-vf", evenDimensions, "-c:v", "libx264", "-preset", "veryfast", "-crf", Settings.quality.x264CRF, "-pix_fmt", "yuv420p"]
        case .webm:
            var args = ["-vf", evenDimensions, "-c:v", "libvpx-vp9", "-crf", Settings.quality.vp9CRF, "-b:v", "0",
                        "-row-mt", "1", "-deadline", "good", "-cpu-used", "4"]
            if info.isHDR {
                args += ["-pix_fmt", "yuv420p10le", "-color_primaries", "bt2020", "-colorspace", "bt2020nc", "-color_trc", info.videos.first?.transfer ?? "smpte2084"]
            } else {
                args += ["-pix_fmt", info.videoEncoder == "gif" ? "yuva420p" : "yuv420p"]
            }
            return args
        case .avi:
            return ["-vf", evenDimensions, "-c:v", "mpeg4", "-q:v", "3"]
        case .wmv:
            return ["-vf", evenDimensions, "-c:v", "wmv2", "-q:v", "3"]
        default:
            return []
        }
    }

    static func videoArguments(_ target: Format, _ info: Probe) -> [String] {
        switch target {
        case .gif:
            return ["-an", "-vf", "fps=15,scale='min(720,iw)':-2:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse",
                    "-loop", "0"]
        default:
            return StreamPlan(info, target: target).arguments(copyVideo: false, copyAudio: false)
        }
    }

    /// Audio settings that keep the container valid when only the audio is re-encoded.
    static func audioArgumentsForContainer(_ format: Format) -> [String] {
        switch format {
        case .webm: return ["-c:a", "libopus", "-b:a", "128k"]
        case .avi: return ["-c:a", "libmp3lame", "-b:a", Settings.quality.audioKbps]
        case .wmv: return ["-c:a", "wmav2", "-b:a", Settings.quality.audioKbps]
        case .mp4, .mov, .m4v, .mkv: return ["-c:a", "aac", "-b:a", Settings.quality.audioKbps]
        default: return audioArguments(format)
        }
    }
}
