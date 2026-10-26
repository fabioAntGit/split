import AppKit
import CoreImage
import SwiftUI

struct GradientPreset {
    let name: String
    let from: String
    let to: String

    static let all: [GradientPreset] = [
        GradientPreset(name: L("Citrine"), from: "#FF9A3D", to: "#FF4E7A"),
        GradientPreset(name: L("Ocean"), from: "#2E8BFF", to: "#36D1DC"),
        GradientPreset(name: L("Mint"), from: "#43E97B", to: "#38F9D7"),
        GradientPreset(name: L("Sunset"), from: "#FA709A", to: "#FEE140"),
        GradientPreset(name: L("Lavender"), from: "#A18CD1", to: "#FBC2EB"),
        GradientPreset(name: L("Sky"), from: "#89F7FE", to: "#66A6FF"),
        GradientPreset(name: L("Peach"), from: "#FFECD2", to: "#FCB69F"),
        GradientPreset(name: L("Paper"), from: "#FFFFFF", to: "#E6E6E6"),
        GradientPreset(name: L("Graphite"), from: "#434343", to: "#000000"),
        GradientPreset(name: L("Charcoal"), from: "#2B2B2B", to: "#121212"),
    ]

    var colors: [CGColor] { [Imaging.color(hex: from), Imaging.color(hex: to)] }
    var swiftUI: LinearGradient {
        LinearGradient(colors: colors.map { Color(cgColor: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

enum BackdropKind: String, CaseIterable, Identifiable {
    case gradient, solid, blur, transparent
    var id: String { rawValue }
    var title: String {
        switch self {
        case .gradient: return L("Gradient")
        case .solid: return L("Color")
        case .blur: return L("Blurred")
        case .transparent: return L("None")
        }
    }
}

enum BackdropRatio: String, CaseIterable, Identifiable {
    case auto, square, r4x5, r4x3, r16x9, r9x16
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return L("Automatic")
        case .square: return L("Square")
        case .r4x5: return L("4:5 (Instagram)")
        case .r4x3: return "4:3"
        case .r16x9: return "16:9"
        case .r9x16: return L("9:16 (Stories)")
        }
    }
    var value: CGFloat? {
        switch self {
        case .auto: return nil
        case .square: return 1
        case .r4x5: return 4.0 / 5
        case .r4x3: return 4.0 / 3
        case .r16x9: return 16.0 / 9
        case .r9x16: return 9.0 / 16
        }
    }
}

/// Everything relative to the image size, so the preview and the full-size output match.
struct BackdropStyle: Equatable {
    var kind: BackdropKind = .gradient
    var gradient = 0
    var solid = CGColor(gray: 1, alpha: 1)
    var padding = 0.08
    var corner = 0.03
    var shadow = 0.5
    var ratio: BackdropRatio = .auto

    var producesTransparency: Bool { kind == .transparent }
}

enum BackdropRenderer {
    static func backdropSize(for image: CGSize, style: BackdropStyle) -> CGSize {
        let longest = max(image.width, image.height)
        let pad = style.padding * longest
        var canvas = CGSize(width: image.width + pad * 2, height: image.height + pad * 2)
        if let ratio = style.ratio.value {
            if canvas.width / canvas.height < ratio { canvas.width = canvas.height * ratio } else { canvas.height = canvas.width / ratio }
        }
        return CGSize(width: canvas.width.rounded(), height: canvas.height.rounded())
    }

    static func render(_ image: CGImage, style: BackdropStyle) throws -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        let canvas = backdropSize(for: size, style: style)
        guard let context = ImageConverter.bitmapContext(canvas) else { throw ImageConverter.outOfMemory(canvas) }
        context.interpolationQuality = .high
        let full = CGRect(origin: .zero, size: canvas)
        switch style.kind {
        case .gradient:
            let preset = GradientPreset.all[min(max(style.gradient, 0), GradientPreset.all.count - 1)]
            if let gradient = CGGradient(colorsSpace: Imaging.sRGB, colors: preset.colors as CFArray, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: canvas.height), end: CGPoint(x: canvas.width, y: 0), options: [])
            }
        case .solid:
            context.setFillColor(style.solid)
            context.fill(full)
        case .blur:
            if let blurred = blurredFill(image, canvas: canvas) { context.draw(blurred, in: full) }
        case .transparent:
            break
        }

        let longest = max(size.width, size.height)
        let frame = CGRect(x: ((canvas.width - size.width) / 2).rounded(), y: ((canvas.height - size.height) / 2).rounded(),
                           width: size.width, height: size.height)
        let radius = style.corner * min(size.width, size.height)
        let rounded = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.saveGState()
        if style.shadow > 0 {
            context.setShadow(offset: CGSize(width: 0, height: -longest * 0.012 * style.shadow), blur: longest * 0.05 * style.shadow,
                              color: CGColor(gray: 0, alpha: 0.38 * style.shadow))
        }
        // The shadow is cast by the rounded image as a whole.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.addPath(rounded)
        context.clip()
        context.draw(image, in: frame)
        context.endTransparencyLayer()
        context.restoreGState()
        guard let result = context.makeImage() else { throw ImageConverter.outOfMemory(canvas) }
        return result
    }

    /// The image itself, scaled to cover the canvas and heavily blurred (iOS-style backdrop).
    static func blurredFill(_ image: CGImage, canvas: CGSize) -> CGImage? {
        let source = CIImage(cgImage: image)
        let scale = max(canvas.width / source.extent.width, canvas.height / source.extent.height)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let offset = CGAffineTransform(translationX: (canvas.width - scaled.extent.width) / 2, y: (canvas.height - scaled.extent.height) / 2)
        let blurred = scaled.transformed(by: offset).clampedToExtent()
            .applyingGaussianBlur(sigma: max(canvas.width, canvas.height) * 0.04)
            .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.04, kCIInputSaturationKey: 1.15])
        return Imaging.cgImage(blurred, extent: CGRect(origin: .zero, size: canvas))
    }
}

final class BackgroundModel: ObservableObject {
    let urls: [URL]
    let preview: CGImage
    @Published var style = BackdropStyle() { didSet { scheduleRender() } }
    @Published private(set) var rendered: CGImage?
    private var renderWork: DispatchWorkItem?
    private let renderQueue = DispatchQueue(label: "split.backdrop", qos: .userInteractive)

    init(urls: [URL], preview: CGImage) {
        self.urls = urls
        // Smaller preview: the blur and shadow are recomputed on every change.
        self.preview = (try? ImageConverter.scaled(preview, maxSide: 1100)) ?? preview
        rendered = try? BackdropRenderer.render(self.preview, style: style)
    }

    /// Coalesced background rendering keeps sliders responsive.
    private func scheduleRender() {
        renderWork?.cancel()
        let style = self.style
        let preview = self.preview
        let work = DispatchWorkItem { [weak self] in
            let image = try? BackdropRenderer.render(preview, style: style)
            DispatchQueue.main.async { if self?.style == style { self?.rendered = image } }
        }
        renderWork = work
        renderQueue.async(execute: work)
    }

    func save() {
        let style = self.style
        JobRunner.shared.each(title: L("Adding a background…"), verb: (L("1 image with a background"), L("%@ images with a background")), urls: urls, width: 2) { url in
            let image = try ImageConverter.loadImage(url)
            let result = try BackdropRenderer.render(image, style: style)
            return [try ImageSaver.save(result, like: url, suffix: " (" + L("with background") + ")", needsAlpha: style.producesTransparency)]
        }
    }
}

struct BackgroundScreen: View {
    @ObservedObject var model: BackgroundModel
    let host: EditorHost
    @State private var solid = Color.white

    var body: some View {
        EditorScaffold(saveTitle: model.urls.count > 1 ? L("Apply to %@", model.urls.count) : L("Save"),
                       onReset: { model.style = BackdropStyle() },
                       onCancel: host.close,
                       onSave: { model.save(); host.close() }) {
            GeometryReader { geometry in
                if let rendered = model.rendered {
                    let size = CGSize(width: rendered.width, height: rendered.height)
                    let frame = Imaging.fit(size, in: geometry.size, margin: 32)
                    ZStack {
                        if model.style.kind == .transparent {
                            Checkerboard()
                                .frame(width: frame.width, height: frame.height)
                                .position(x: frame.midX, y: frame.midY)
                        }
                        Image(decorative: rendered, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } inspector: {
            Section(L("Background")) {
                Picker(L("Type"), selection: $model.style.kind) {
                    ForEach(BackdropKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                switch model.style.kind {
                case .gradient:
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 6), count: 5), spacing: 6) {
                        ForEach(GradientPreset.all.indices, id: \.self) { index in
                            Swatch(fill: GradientPreset.all[index].swiftUI, selected: model.style.gradient == index,
                                   help: GradientPreset.all[index].name) { model.style.gradient = index }
                        }
                    }
                case .solid:
                    ColorPicker(L("Color"), selection: $solid, supportsOpacity: false)
                        .onChange(of: solid) { color in
                            if let cg = NSColor(color).usingColorSpace(.sRGB)?.cgColor { model.style.solid = cg }
                        }
                case .blur:
                    InspectorNote(text: L("Uses the image itself, enlarged and blurred, as the background."))
                case .transparent:
                    InspectorNote(text: L("No background: the result is a PNG with transparency, useful for rounded corners and a shadow."))
                }
            }
            Section(L("Frame")) {
                ValueSlider(title: L("Margin"), value: $model.style.padding, range: 0...0.3)
                ValueSlider(title: L("Corners"), value: $model.style.corner, range: 0...0.2)
                ValueSlider(title: L("Shadow"), value: $model.style.shadow, range: 0...1)
            }
            Section(L("Format")) {
                Picker(L("Aspect Ratio"), selection: $model.style.ratio) {
                    ForEach(BackdropRatio.allCases) { Text($0.title).tag($0) }
                }
                if model.urls.count > 1 {
                    InspectorNote(text: L("The same settings are applied to the %@ images.", model.urls.count))
                }
            }
        }
    }
}
