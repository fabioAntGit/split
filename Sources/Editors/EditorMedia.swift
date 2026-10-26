import AppKit
import AVFoundation
import SwiftUI

struct MaskRegion: Identifiable, Equatable {
    enum Kind: String, CaseIterable { case blur, black }
    let id = UUID()
    var rect: CGRect      // normalised, top-left origin, in the rotated/displayed frame
    var kind: Kind
}

enum MediaOutput: String, CaseIterable, Identifiable {
    case same, mp4, gif, m4a, mp3, wav
    var id: String { rawValue }
}

/// Every edit, independent of the UI, so the ffmpeg command can be built and tested on its own.
struct MediaEdit: Equatable {
    var start = 0.0
    var end = 0.0
    var duration = 0.0
    var speed = 1.0
    var volume = 1.0
    var mute = false
    var fadeIn = false
    var fadeOut = false
    var turns = 0
    var flipH = false
    var crop: CGRect?
    var masks: [MaskRegion] = []
    var output: MediaOutput = .same
    var fastTrim = false

    var trimmed: Bool { start > 0.01 || (duration > 0 && end < duration - 0.01) }
    var length: Double { max(0.05, end - start) }
    var resultDuration: Double { length / speed }
    var hasVideoChanges: Bool { turns % 4 != 0 || flipH || crop != nil || !masks.isEmpty || speed != 1 }
    var hasAudioChanges: Bool { speed != 1 || volume != 1 || mute || fadeIn || fadeOut }
    var isIdentity: Bool { !trimmed && !hasVideoChanges && !hasAudioChanges && output == .same }
    /// Stream copy is only possible when nothing but the cut changes.
    var canCopy: Bool { trimmed && !hasVideoChanges && !hasAudioChanges && output == .same }
}

enum MediaEditRenderer {
    /// Output format: the source's own when it can be re-encoded, else MP4 / M4A.
    static func outputFormat(source: Format, edit: MediaEdit, isVideo: Bool) -> Format {
        switch edit.output {
        case .mp4: return .mp4
        case .gif: return .gif
        case .m4a: return .m4a
        case .mp3: return .mp3
        case .wav: return .wav
        case .same:
            if isVideo { return [.mp4, .mov, .m4v, .mkv, .webm].contains(source) ? source : .mp4 }
            return source
        }
    }

    static func atempo(_ speed: Double) -> [String] {
        var remaining = speed
        var filters: [String] = []
        while remaining > 2.0 { filters.append("atempo=2.0"); remaining /= 2 }
        while remaining < 0.5 { filters.append("atempo=0.5"); remaining /= 0.5 }
        if abs(remaining - 1) > 0.0001 { filters.append(String(format: "atempo=%.4f", remaining)) }
        return filters
    }

    /// Even sizes (yuv420p needs them), at least 2 px.
    static func even(_ value: CGFloat) -> Int { max(2, Int(value / 2) * 2) }
    /// Even positions; unlike sizes these may be 0.
    static func evenOffset(_ value: CGFloat) -> Int { max(0, Int(value / 2) * 2) }

    /// ffmpeg arguments (input options, output options) for an edit.
    static func arguments(edit: MediaEdit, probe: MediaConverter.Probe, target: Format) -> (input: [String], output: [String]) {
        var input: [String] = []
        if edit.trimmed {
            input += ["-ss", String(format: "%.3f", edit.start), "-t", String(format: "%.3f", edit.length)]
        }
        if edit.canCopy && edit.fastTrim {
            return (input, ["-map", "0", "-c", "copy", "-avoid_negative_ts", "make_zero"])
        }
        var output: [String] = []
        let isVideoOutput = probe.hasVideo && target.group != .audio

        if isVideoOutput {
            var size = probe.displaySize
            if edit.turns % 2 == 1 { size = CGSize(width: size.height, height: size.width) }
            var graph: [String] = []
            var chain: [String] = []
            switch ((edit.turns % 4) + 4) % 4 {
            case 1: chain.append("transpose=1")
            case 2: chain += ["hflip", "vflip"]
            case 3: chain.append("transpose=2")
            default: break
            }
            if edit.flipH { chain.append("hflip") }
            var label = "0:v"
            if !chain.isEmpty {
                graph.append("[0:v]" + chain.joined(separator: ",") + "[rot]")
                label = "rot"
            }
            for (index, redaction) in edit.masks.enumerated() {
                let x = evenOffset(redaction.rect.minX * size.width)
                let y = evenOffset(redaction.rect.minY * size.height)
                let w = min(even(redaction.rect.width * size.width), even(size.width) - x)
                let h = min(even(redaction.rect.height * size.height), even(size.height) - y)
                guard w >= 2, h >= 2 else { continue }
                switch redaction.kind {
                case .black:
                    graph.append("[\(label)]drawbox=x=\(x):y=\(y):w=\(w):h=\(h):color=black:t=fill[r\(index)]")
                case .blur:
                    let sigma = max(8, min(w, h) / 5)
                    graph.append("[\(label)]split=2[a\(index)][b\(index)];[b\(index)]crop=\(w):\(h):\(x):\(y),gblur=sigma=\(sigma):steps=3[c\(index)];"
                        + "[a\(index)][c\(index)]overlay=\(x):\(y)[r\(index)]")
                }
                label = "r\(index)"
            }
            var tail: [String] = []
            if let crop = edit.crop {
                let x = evenOffset(crop.minX * size.width)
                let y = evenOffset(crop.minY * size.height)
                let w = min(even(crop.width * size.width), even(size.width) - x)
                let h = min(even(crop.height * size.height), even(size.height) - y)
                tail.append("crop=\(w):\(h):\(x):\(y)")
            }
            if edit.speed != 1 { tail.append(String(format: "setpts=PTS/%.4f", edit.speed)) }
            if target == .gif {
                tail.append("fps=15,scale='min(720,iw)':-2:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse")
            } else {
                tail.append(MediaConverter.evenDimensions)
            }
            graph.append("[\(label)]" + tail.joined(separator: ",") + "[vout]")
            output += ["-filter_complex", graph.joined(separator: ";"), "-map", "[vout]"]
            if target == .gif {
                return (input, output + ["-an", "-loop", "0"])
            }
            if !edit.mute && probe.containsAudio { output += ["-map", "0:a:0?"] }
        } else {
            output += ["-vn", "-map", "0:a:0"]
        }

        let wantsAudio = probe.containsAudio && !edit.mute
        if wantsAudio {
            var audio = atempo(edit.speed)
            if edit.volume != 1 { audio.append(String(format: "volume=%.3f", edit.volume)) }
            let duration = edit.resultDuration
            if edit.fadeIn { audio.append("afade=t=in:st=0:d=\(String(format: "%.2f", min(1.5, duration / 3)))") }
            if edit.fadeOut {
                let fade = min(1.5, duration / 3)
                audio.append("afade=t=out:st=\(String(format: "%.3f", max(0, duration - fade))):d=\(String(format: "%.2f", fade))")
            }
            if !audio.isEmpty { output += ["-af", audio.joined(separator: ",")] }
        } else if isVideoOutput {
            output.append("-an")
        }

        if isVideoOutput {
            switch target {
            case .webm:
                output += ["-c:v", "libvpx-vp9", "-crf", Settings.quality.vp9CRF, "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4",
                           "-pix_fmt", "yuv420p"]
                if wantsAudio { output += ["-c:a", "libopus", "-b:a", "128k"] }
            default:
                output += ["-c:v", "libx264", "-preset", "veryfast", "-crf", Settings.quality.x264CRF, "-pix_fmt", "yuv420p"]
                if wantsAudio { output += ["-c:a", "aac", "-b:a", Settings.quality.audioKbps] }
                if [.mp4, .mov, .m4v].contains(target) { output += ["-movflags", "+faststart"] }
            }
        } else {
            output += MediaConverter.audioArguments(target)
        }
        return (input, output + ["-map_metadata", Settings.keepsMetadata ? "0" : "-1"])
    }

    static func export(_ url: URL, edit: MediaEdit) throws -> URL {
        let probe = try MediaConverter.probe(url)
        let source = Format.detect(url) ?? .mp4
        let target = outputFormat(source: source, edit: edit, isVideo: probe.hasVideo)
        if edit.mute && !probe.hasVideo {
            throw Problem(L("Removing the sound from an audio file would leave an empty file."), suggestion: L("Turn off “Mute”."))
        }
        let out = Output.url(for: url, ext: target.ext, suffix: " (" + L("edited") + ")")
        let (input, output) = arguments(edit: edit, probe: probe, target: target)
        try MediaConverter.encode(url, output, to: out, what: L("Exporting"), inputArguments: input, duration: edit.resultDuration)
        return out
    }

    /// One frame at full resolution, exactly at `time`.
    static func saveFrame(_ url: URL, at time: Double) throws -> URL {
        let seconds = String(format: "%.1f", locale: Localizer.shared.locale, time)
        let out = Output.url(for: url, ext: "png", suffix: " (" + L("frame at %@ s", seconds) + ")")
        try MediaConverter.encode(url, ["-frames:v", "1", "-update", "1"], to: out, what: L("Capturing the frame"),
                                  inputArguments: ["-ss", String(format: "%.3f", time)], duration: 1)
        return out
    }

    /// Peak levels for drawing an audio waveform (0…1).
    static func waveform(_ url: URL, bins: Int = 320) throws -> [Float] {
        let ffmpeg = try MediaConverter.ffmpeg()
        let result = try runChecked(ffmpeg, ["-hide_banner", "-loglevel", "error", "-nostdin"] + MediaConverter.localInput(url)
                                        + ["-vn", "-ac", "1", "-ar", "800", "-f", "f32le", "-"], what: L("Reading the sound"))
        let samples = result.stdoutData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard !samples.isEmpty else { return [] }
        let per = max(1, samples.count / bins)
        var peaks: [Float] = []
        var index = 0
        while index < samples.count {
            let slice = samples[index..<min(index + per, samples.count)]
            peaks.append(slice.map { abs($0) }.max() ?? 0)
            index += per
        }
        let top = max(peaks.max() ?? 1, 0.0001)
        return peaks.map { $0 / top }
    }
}

final class MediaEditorModel: ObservableObject {
    enum Mode: String, CaseIterable { case view, crop, redact }

    let url: URL
    @Published var edit = MediaEdit()
    @Published var probe = MediaConverter.Probe()
    @Published var player: AVPlayer?
    @Published var current = 0.0
    @Published var isPlaying = false
    @Published var loading: String? = L("Opening…")
    @Published var loadingFraction: Double?
    @Published var failure: Problem?
    @Published var thumbnails: [CGImage] = []
    @Published var waveform: [Float] = []
    @Published var mode: Mode = .view
    @Published var maskKind: MaskRegion.Kind = .blur
    @Published var selectedRedaction: UUID?
    private var observer: Any?
    private var proxyFolder: URL?

    init(url: URL) {
        self.url = url
        load()
    }

    deinit {
        if let observer { player?.removeTimeObserver(observer) }
        if let proxyFolder { try? FileManager.default.removeItem(at: proxyFolder) }
    }

    var isVideo: Bool { probe.hasVideo }
    var displaySize: CGSize {
        let size = probe.displaySize
        return edit.turns % 2 == 1 ? CGSize(width: size.height, height: size.width) : size
    }

    private func load() {
        let url = self.url
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try FileCheck.preflight(url)
                let probe = try MediaConverter.probe(url)
                guard probe.containsAudio || probe.hasVideo else {
                    throw Problem(L("“%@” has no sound or picture that can be edited.", url.lastPathComponent))
                }
                DispatchQueue.main.async {
                    self.probe = probe
                    self.edit.duration = probe.duration
                    self.edit.end = probe.duration
                }
                let playable = try self.playableURL(for: url, probe: probe)
                if !probe.hasVideo, let peaks = try? MediaEditRenderer.waveform(url) {
                    DispatchQueue.main.async { self.waveform = peaks }
                }
                DispatchQueue.main.async { self.attachPlayer(playable) }
                if probe.hasVideo { self.makeThumbnails(playable, duration: probe.duration) }
            } catch {
                let explained = Explain.error(error, file: url)
                DispatchQueue.main.async {
                    self.failure = explained
                    self.loading = nil
                }
            }
        }
    }

    /// AVFoundation plays MP4/MOV/M4A/MP3/WAV/AIFF; anything else gets a light preview copy.
    private func playableURL(for url: URL, probe: MediaConverter.Probe) throws -> URL {
        let format = Format.detect(url)
        let native: Set<Format> = [.mp4, .mov, .m4v, .m4a, .mp3, .wav, .aiff]
        if let format, native.contains(format), MediaEditorModel.isPlayable(url) { return url }
        DispatchQueue.main.async { self.loading = L("Preparing the preview…") }
        let folder = try Output.scratchDirectory()
        proxyFolder = folder
        let proxy = folder.appendingPathComponent(probe.hasVideo ? "preview.mp4" : "preview.m4a")
        let arguments = probe.hasVideo
            ? ["-map", "0:v:0", "-map", "0:a:0?", "-vf", "scale=-2:'min(720,ih)'," + MediaConverter.evenDimensions,
               "-c:v", "libx264", "-preset", "ultrafast", "-crf", "30", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k"]
            : ["-vn", "-c:a", "aac", "-b:a", "160k"]
        try JobProgress.run({ fraction in
            DispatchQueue.main.async { self.loadingFraction = fraction }
        }) {
            try MediaConverter.encode(url, arguments, to: proxy, what: L("Preparing the preview"), duration: probe.duration)
        }
        return proxy
    }

    /// AVFoundation's async check, waited for on this background thread.
    static func isPlayable(_ url: URL) -> Bool {
        final class Box { var value = false }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            box.value = (try? await AVURLAsset(url: url).load(.isPlayable)) ?? false
            semaphore.signal()
        }
        semaphore.wait()
        return box.value
    }

    private func attachPlayer(_ url: URL) {
        let player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self else { return }
            self.current = time.seconds
            // Play only the selected range, looping like QuickTime's trim preview.
            if self.isPlaying && self.current >= self.edit.end - 0.02 {
                self.seek(self.edit.start)
            }
        }
        self.player = player
        loading = nil
        applyPlaybackSettings()
    }

    private func makeThumbnails(_ url: URL, duration: Double) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        let count = 12
        let times = (0..<count).map { NSValue(time: CMTime(seconds: duration * (Double($0) + 0.5) / Double(count), preferredTimescale: 600)) }
        var images: [Int: CGImage] = [:]
        var remaining = count
        generator.generateCGImagesAsynchronously(forTimes: times) { requested, image, _, _, _ in
            let index = times.firstIndex(of: NSValue(time: requested)) ?? 0
            DispatchQueue.main.async {
                if let image { images[index] = image }
                remaining -= 1
                if remaining == 0 { self.thumbnails = images.keys.sorted().compactMap { images[$0] } }
            }
        }
    }

    func applyPlaybackSettings() {
        player?.volume = Float(min(1, edit.volume))
        player?.isMuted = edit.mute
        if isPlaying { player?.rate = Float(edit.speed) }
    }

    func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if current < edit.start || current >= edit.end - 0.05 { seek(edit.start) }
            player.rate = Float(edit.speed)
            isPlaying = true
        }
    }

    func seek(_ time: Double) {
        let clamped = min(max(time, 0), max(edit.duration, 0))
        current = clamped
        player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setStart() { edit.start = min(current, edit.end - 0.1) }
    func setEnd() { edit.end = max(current, edit.start + 0.1) }

    func save() {
        let edit = self.edit
        JobRunner.shared.single(title: L("Exporting…"), item: url.lastPathComponent, files: [url]) { [url] in
            [try MediaEditRenderer.export(url, edit: edit)]
        }
    }

    func saveFrame() {
        let time = current
        JobRunner.shared.single(title: L("Saving the frame…"), item: url.lastPathComponent, files: [url]) { [url] in
            [try MediaEditRenderer.saveFrame(url, at: time)]
        }
    }
}

// MARK: - Views

/// AVPlayerLayer without controls; the editor draws its own transport and timeline.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
        layer.frame = view.bounds
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view.layer?.sublayers?.first as? AVPlayerLayer)?.player = player
    }
}

struct MediaScreen: View {
    @ObservedObject var model: MediaEditorModel
    let host: EditorHost
    @State private var draftRect: CGRect?
    @State private var activeHandle: CropHandle?
    @State private var startRect = CropSettings.full

    var body: some View {
        EditorScaffold(saveTitle: L("Export"), canSave: model.player != nil && !model.edit.isIdentity,
                       onReset: { let duration = model.edit.duration; model.edit = MediaEdit(); model.edit.duration = duration; model.edit.end = duration; model.applyPlaybackSettings() },
                       onCancel: host.close,
                       onSave: { model.player?.pause(); model.save(); host.close() }) {
            VStack(spacing: 0) {
                stage
                Divider()
                transport
                TimelineStrip(model: model)
                    .frame(height: 64)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            }
            .background(
                Button("") { model.togglePlay() }.keyboardShortcut(.space, modifiers: []).opacity(0)
            )
        } inspector: {
            inspector
        }
        .onChange(of: model.edit.speed) { _ in model.applyPlaybackSettings() }
        .onChange(of: model.edit.volume) { _ in model.applyPlaybackSettings() }
        .onChange(of: model.edit.mute) { _ in model.applyPlaybackSettings() }
        .onDisappear { model.player?.pause() }
    }

    // MARK: Stage

    @ViewBuilder
    private var stage: some View {
        GeometryReader { geometry in
            if let failure = model.failure {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 28)).foregroundColor(.secondary)
                    Text(failure.message).font(.headline).multilineTextAlignment(.center)
                    if let suggestion = failure.suggestion { Text(suggestion).foregroundColor(.secondary).multilineTextAlignment(.center) }
                }
                .padding(30)
                .frame(width: geometry.size.width, height: geometry.size.height)
            } else if let loading = model.loading {
                VStack(spacing: 10) {
                    if let fraction = model.loadingFraction {
                        ProgressView(value: fraction).frame(width: 200)
                    } else {
                        ProgressView()
                    }
                    Text(loading).foregroundColor(.secondary)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            } else if let player = model.player {
                if model.isVideo {
                    videoStage(player: player, size: geometry.size)
                } else {
                    WaveformView(peaks: model.waveform, start: model.edit.start, end: model.edit.end, duration: model.edit.duration, current: model.current)
                        .padding(30)
                }
            }
        }
    }

    private func videoStage(player: AVPlayer, size: CGSize) -> some View {
        let frame = Imaging.fit(model.displaySize, in: size, margin: 20)
        let rotated = model.edit.turns % 2 == 1
        return ZStack {
            PlayerSurface(player: player)
                .frame(width: rotated ? frame.height : frame.width, height: rotated ? frame.width : frame.height)
                .rotationEffect(.degrees(Double(model.edit.turns) * 90))
                .scaleEffect(x: model.edit.flipH ? -1 : 1, y: 1)
                .position(x: frame.midX, y: frame.midY)
            ForEach(model.edit.masks) { redaction in
                let rect = viewRect(redaction.rect, frame)
                RoundedRectangle(cornerRadius: 2)
                    .fill(redaction.kind == .black ? Color.black : Color.white.opacity(0.25))
                    .background(redaction.kind == .blur ? AnyView(VisualEffect(material: .hudWindow, blending: .withinWindow)) : AnyView(EmptyView()))
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(model.selectedRedaction == redaction.id ? LookStore.shared.accent : Color.white.opacity(0.6),
                                                                        lineWidth: model.selectedRedaction == redaction.id ? 2 : 1))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
            }
            if let draftRect {
                let rect = viewRect(draftRect, frame)
                RoundedRectangle(cornerRadius: 2).stroke(LookStore.shared.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
            }
            if model.mode == .crop || model.edit.crop != nil {
                CropOverlay(crop: model.edit.crop ?? CropSettings.full, frame: frame, showGrid: activeHandle != nil)
                    .opacity(model.mode == .crop ? 1 : 0.7)
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in stageDrag(value, frame: frame) }
            .onEnded { value in stageDragEnded(value, frame: frame) })
    }

    private func viewRect(_ rect: CGRect, _ frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + rect.minX * frame.width, y: frame.minY + rect.minY * frame.height, width: rect.width * frame.width, height: rect.height * frame.height)
    }

    private func normalised(_ point: CGPoint, _ frame: CGRect) -> CGPoint {
        CGPoint(x: min(max((point.x - frame.minX) / frame.width, 0), 1), y: min(max((point.y - frame.minY) / frame.height, 0), 1))
    }

    private func stageDrag(_ value: DragGesture.Value, frame: CGRect) {
        guard frame.width > 0 else { return }
        switch model.mode {
        case .view:
            break
        case .crop:
            let crop = model.edit.crop ?? CropSettings.full
            if activeHandle == nil {
                activeHandle = CropRenderer.handle(at: value.startLocation, crop: crop, frame: frame)
                startRect = crop
            }
            guard let handle = activeHandle else { return }
            let delta = CGSize(width: value.translation.width / frame.width, height: value.translation.height / frame.height)
            model.edit.crop = CropRenderer.drag(handle, from: startRect, by: delta, ratio: nil)
        case .redact:
            let a = normalised(value.startLocation, frame)
            let b = normalised(value.location, frame)
            draftRect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        }
    }

    private func stageDragEnded(_ value: DragGesture.Value, frame: CGRect) {
        activeHandle = nil
        if model.mode == .crop, let crop = model.edit.crop, crop == CropSettings.full { model.edit.crop = nil }
        guard model.mode == .redact else { return }
        defer { draftRect = nil }
        if let rect = draftRect, rect.width > 0.01, rect.height > 0.01 {
            let redaction = MaskRegion(rect: rect, kind: model.maskKind)
            model.edit.masks.append(redaction)
            model.selectedRedaction = redaction.id
        } else {
            let point = normalised(value.location, frame)
            model.selectedRedaction = model.edit.masks.last { $0.rect.contains(point) }?.id
        }
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: 10) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 16)
            }
            .buttonStyle(ToolButtonStyle(selected: false))
            .iconLabel(model.isPlaying ? L("Pause (space)") : L("Play (space)"))
            Text("\(timecode(model.current)) / \(timecode(model.edit.duration))")
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(.secondary)
            Spacer()
            Button(L("Start Here")) { model.setStart() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut("i", modifiers: [])
                .help(L("Sets the start of the trim at the current position (I)"))
            Button(L("End Here")) { model.setEnd() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut("o", modifiers: [])
                .help(L("Sets the end of the trim at the current position (O)"))
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .disabled(model.player == nil)
    }

    // MARK: Inspector

    @ViewBuilder
    private var inspector: some View {
        Section(L("Trim")) {
            LabeledContent(L("Start"), value: timecode(model.edit.start))
            LabeledContent(L("End"), value: timecode(model.edit.end))
            LabeledContent(L("Final Length"), value: timecode(model.edit.resultDuration))
            if model.edit.canCopy {
                Toggle(L("Quick trim (no re-encoding)"), isOn: $model.edit.fastTrim)
                if model.edit.fastTrim {
                    InspectorNote(text: L("Instant and lossless, but the start snaps to the nearest keyframe (it may move by a few tenths of a second)."))
                }
            }
        }
        Section(L("Speed and Sound")) {
            Picker(L("Speed"), selection: $model.edit.speed) {
                ForEach([0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 4], id: \.self) { value in
                    Text(value == 1 ? L("Normal") : "\(String(format: value < 1 ? "%.2g" : "%.3g", value))×").tag(value)
                }
            }
            if model.probe.containsAudio {
                ValueSlider(title: L("Volume"), value: $model.edit.volume, range: 0...2)
                    .disabled(model.edit.mute)
                if model.isVideo { Toggle(L("Mute"), isOn: $model.edit.mute) }
                Toggle(L("Fade In"), isOn: $model.edit.fadeIn).disabled(model.edit.mute)
                Toggle(L("Fade Out"), isOn: $model.edit.fadeOut).disabled(model.edit.mute)
            }
        }
        if model.isVideo {
            Section(L("Picture")) {
                Picker(L("Tool"), selection: $model.mode) {
                    Text(L("View")).tag(MediaEditorModel.Mode.view)
                    Text(L("Crop")).tag(MediaEditorModel.Mode.crop)
                    Text(L("Cover")).tag(MediaEditorModel.Mode.redact)
                }
                .pickerStyle(.segmented)
                HStack(spacing: 6) {
                    Button { model.edit.turns = (model.edit.turns + 3) % 4; model.edit.crop = nil; model.edit.masks = [] } label: { Image(systemName: "rotate.left") }
                        .buttonStyle(ToolButtonStyle(selected: false)).iconLabel(L("Rotate 90° Left"))
                    Button { model.edit.turns = (model.edit.turns + 1) % 4; model.edit.crop = nil; model.edit.masks = [] } label: { Image(systemName: "rotate.right") }
                        .buttonStyle(ToolButtonStyle(selected: false)).iconLabel(L("Rotate 90° Right"))
                    Button { model.edit.flipH.toggle() } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                        .buttonStyle(ToolButtonStyle(selected: model.edit.flipH)).iconLabel(L("Flip"))
                    Spacer()
                    if model.edit.crop != nil {
                        Button(L("No Crop")) { model.edit.crop = nil }.buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                    }
                }
                if model.mode == .redact {
                    Picker(L("Cover With"), selection: $model.maskKind) {
                        Text(L("Blurred")).tag(MaskRegion.Kind.blur)
                        Text(L("Black")).tag(MaskRegion.Kind.black)
                    }
                    InspectorNote(text: L("Drag over the video to cover an area for the whole clip."))
                }
                ForEach(model.edit.masks) { redaction in
                    HStack {
                        Image(systemName: redaction.kind == .blur ? "drop" : "rectangle.fill").foregroundColor(.secondary)
                        Text(redaction.kind == .blur ? L("Blurred Area") : L("Black Area"))
                        Spacer()
                        Button { model.edit.masks.removeAll { $0.id == redaction.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundColor(.secondary).iconLabel(L("Remove"))
                    }
                }
                Button(L("Save Frame (PNG)")) { model.saveFrame() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        Section(L("Format")) {
            Picker(L("Save As"), selection: $model.edit.output) {
                Text(L("Same as the Original")).tag(MediaOutput.same)
                if model.isVideo {
                    Text("MP4").tag(MediaOutput.mp4)
                    Text(L("Animated GIF")).tag(MediaOutput.gif)
                }
                Text(L("Audio Only (M4A)")).tag(MediaOutput.m4a)
                Text(L("Audio Only (MP3)")).tag(MediaOutput.mp3)
                if !model.isVideo { Text("WAV").tag(MediaOutput.wav) }
            }
            InspectorNote(text: L("The result is saved next to the original with “(%@)”.", L("edited")))
        }
    }

    private func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00.0" }
        let total = max(0, seconds)
        let minutes = Int(total) / 60
        let rest = total - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, rest)
    }
}

/// Filmstrip (video) or waveform (audio) with trim handles and the playhead.
struct TimelineStrip: View {
    @ObservedObject var model: MediaEditorModel
    @ObservedObject var look = LookStore.shared
    @State private var dragging: Int?   // 0 = start, 1 = end, 2 = playhead

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let duration = max(model.edit.duration, 0.001)
            let startX = CGFloat(model.edit.start / duration) * width
            let endX = CGFloat(model.edit.end / duration) * width
            let playX = CGFloat(model.current / duration) * width
            ZStack(alignment: .topLeading) {
                Group {
                    if !model.thumbnails.isEmpty {
                        HStack(spacing: 0) {
                            ForEach(model.thumbnails.indices, id: \.self) { index in
                                Image(decorative: model.thumbnails[index], scale: 1)
                                    .resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: width / CGFloat(model.thumbnails.count), height: height)
                                    .clipped()
                            }
                        }
                    } else {
                        WaveformView(peaks: model.waveform, start: 0, end: duration, duration: duration, current: -1)
                            .background(Color.primary.opacity(0.05))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                // Outside the selection is dimmed.
                Rectangle().fill(Color.black.opacity(0.55)).frame(width: max(0, startX), height: height)
                Rectangle().fill(Color.black.opacity(0.55)).frame(width: max(0, width - endX), height: height).offset(x: endX)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(look.accent, lineWidth: 3)
                    .frame(width: max(8, endX - startX), height: height)
                    .offset(x: startX)
                handle.offset(x: startX - 5)
                handle.offset(x: endX - 5)
                Rectangle().fill(Color.white).frame(width: 2, height: height + 8).offset(x: playX - 1, y: -4)
                    .shadow(color: .black.opacity(0.4), radius: 1)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let time = Double(min(max(value.location.x / width, 0), 1)) * duration
                    if dragging == nil {
                        let x = value.startLocation.x
                        if abs(x - startX) < 12 { dragging = 0 } else if abs(x - endX) < 12 { dragging = 1 } else { dragging = 2 }
                    }
                    switch dragging {
                    case 0: model.edit.start = min(time, model.edit.end - 0.1); model.seek(model.edit.start)
                    case 1: model.edit.end = max(time, model.edit.start + 0.1); model.seek(model.edit.end)
                    default: model.seek(time)
                    }
                }
                .onEnded { _ in dragging = nil })
        }
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(look.selection)
            .frame(width: 10)
            .overlay(Capsule().fill(look.onSelection.opacity(0.8)).frame(width: 2, height: 16))
    }
}

struct WaveformView: View {
    let peaks: [Float]
    let start: Double
    let end: Double
    let duration: Double
    let current: Double
    @ObservedObject var look = LookStore.shared

    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty else { return }
            let step = size.width / CGFloat(peaks.count)
            let mid = size.height / 2
            for (index, peak) in peaks.enumerated() {
                let x = CGFloat(index) * step
                let time = Double(index) / Double(peaks.count) * duration
                let inside = time >= start && time <= end
                let h = max(1, CGFloat(peak) * (size.height * 0.9))
                let bar = CGRect(x: x, y: mid - h / 2, width: max(1, step * 0.7), height: h)
                context.fill(Path(roundedRect: bar, cornerRadius: min(1.5, step / 2)),
                             with: .color(inside ? look.accent : Color.primary.opacity(0.25)))
            }
            if current >= 0, duration > 0 {
                let x = CGFloat(current / duration) * size.width
                context.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(.primary))
            }
        }
    }
}
