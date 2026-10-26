import AppKit
import CoreImage
import SwiftUI

enum PhotoFilter: String, CaseIterable, Identifiable {
    case none, mono, noir, tonal, fade, chrome, instant, process, transfer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return L("None")
        case .mono: return L("Mono")
        case .noir: return L("Noir")
        case .tonal: return L("Tonal")
        case .fade: return L("Fade")
        case .chrome: return L("Chrome")
        case .instant: return L("Instant")
        case .process: return L("Process")
        case .transfer: return L("Transfer")
        }
    }

    var ciName: String? {
        switch self {
        case .none: return nil
        case .mono: return "CIPhotoEffectMono"
        case .noir: return "CIPhotoEffectNoir"
        case .tonal: return "CIPhotoEffectTonal"
        case .fade: return "CIPhotoEffectFade"
        case .chrome: return "CIPhotoEffectChrome"
        case .instant: return "CIPhotoEffectInstant"
        case .process: return "CIPhotoEffectProcess"
        case .transfer: return "CIPhotoEffectTransfer"
        }
    }
}

/// Neutral values leave the image untouched.
struct Adjustments: Equatable {
    var auto = false
    var exposure = 0.0      // EV, −2…2
    var brightness = 0.0    // −0.5…0.5
    var contrast = 1.0      // 0.5…1.5
    var saturation = 1.0    // 0…2
    var vibrance = 0.0      // −1…1
    var warmth = 0.0        // −1 (cool) … 1 (warm)
    var tint = 0.0          // −1…1
    var highlights = 0.0    // 0…1 recovers highlights
    var shadows = 0.0       // −1…1
    var sharpness = 0.0     // 0…1
    var noise = 0.0         // 0…1
    var vignette = 0.0      // 0…1
    var filter: PhotoFilter = .none

    var isNeutral: Bool { self == Adjustments() }
}

enum AdjustRenderer {
    static func apply(_ adjustments: Adjustments, to input: CIImage) -> CIImage {
        var image = input
        let extent = input.extent
        if adjustments.auto {
            for filter in input.autoAdjustmentFilters(options: [.redEye: false]) {
                filter.setValue(image, forKey: kCIInputImageKey)
                if let output = filter.outputImage { image = output }
            }
        }
        if adjustments.exposure != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: adjustments.exposure])
        }
        if adjustments.brightness != 0 || adjustments.contrast != 1 || adjustments.saturation != 1 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: adjustments.brightness,
                kCIInputContrastKey: adjustments.contrast,
                kCIInputSaturationKey: adjustments.saturation,
            ])
        }
        if adjustments.vibrance != 0 {
            image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": adjustments.vibrance])
        }
        if adjustments.warmth != 0 || adjustments.tint != 0 {
            // A lower target neutral makes the picture warmer.
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 - adjustments.warmth * 2500, y: adjustments.tint * 60),
            ])
        }
        if adjustments.highlights != 0 || adjustments.shadows != 0 {
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1 - adjustments.highlights,
                "inputShadowAmount": adjustments.shadows,
            ])
        }
        if adjustments.noise > 0 {
            image = image.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": 0.02 * adjustments.noise,
                "inputSharpness": 0.4,
            ])
        }
        if adjustments.sharpness > 0 {
            image = image.applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": adjustments.sharpness * 1.5])
        }
        if let name = adjustments.filter.ciName {
            image = image.applyingFilter(name)
        }
        if adjustments.vignette > 0 {
            image = image.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: adjustments.vignette * 1.6,
                kCIInputRadiusKey: max(extent.width, extent.height) / 1000 * 1.4,
            ])
        }
        return image.cropped(to: extent)
    }

    static func render(_ image: CGImage, _ adjustments: Adjustments) throws -> CGImage {
        guard !adjustments.isNeutral else { return image }
        let output = apply(adjustments, to: CIImage(cgImage: image))
        guard let result = Imaging.cgImage(output, extent: CGRect(x: 0, y: 0, width: image.width, height: image.height)) else {
            throw ImageConverter.outOfMemory(CGSize(width: image.width, height: image.height))
        }
        return result
    }
}

final class AdjustModel: ObservableObject {
    let urls: [URL]
    let preview: CGImage
    @Published var adjustments = Adjustments() { didSet { scheduleRender() } }
    @Published private(set) var rendered: CGImage
    @Published var showOriginal = false
    private var work: DispatchWorkItem?
    private let queue = DispatchQueue(label: "split.adjust", qos: .userInteractive)

    init(urls: [URL], preview: CGImage) {
        self.urls = urls
        self.preview = (try? ImageConverter.scaled(preview, maxSide: 1400)) ?? preview
        rendered = self.preview
    }

    private func scheduleRender() {
        work?.cancel()
        let adjustments = self.adjustments
        let preview = self.preview
        let item = DispatchWorkItem { [weak self] in
            let image = (try? AdjustRenderer.render(preview, adjustments)) ?? preview
            DispatchQueue.main.async { if self?.adjustments == adjustments { self?.rendered = image } }
        }
        work = item
        queue.async(execute: item)
    }

    func save() {
        let adjustments = self.adjustments
        JobRunner.shared.each(title: L("Applying adjustments…"), verb: (L("1 image adjusted"), L("%@ images adjusted")), urls: urls, width: 2) { url in
            let image = try ImageConverter.loadImage(url)
            return [try ImageSaver.save(try AdjustRenderer.render(image, adjustments), like: url, suffix: " (" + L("adjusted") + ")")]
        }
    }
}

struct AdjustScreen: View {
    @ObservedObject var model: AdjustModel
    let host: EditorHost

    var body: some View {
        EditorScaffold(saveTitle: model.urls.count > 1 ? L("Apply to %@", model.urls.count) : L("Save"),
                       canSave: !model.adjustments.isNeutral,
                       onReset: { model.adjustments = Adjustments() },
                       onCancel: host.close,
                       onSave: { model.save(); host.close() }) {
            GeometryReader { geometry in
                let image = model.showOriginal ? model.preview : model.rendered
                let frame = Imaging.fit(CGSize(width: image.width, height: image.height), in: geometry.size, margin: 28)
                ZStack(alignment: .bottom) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                    compareButton.padding(.bottom, 14)
                }
            }
        } inspector: {
            Section {
                Toggle(L("Auto Enhance"), isOn: $model.adjustments.auto)
                Picker(L("Filter"), selection: $model.adjustments.filter) {
                    ForEach(PhotoFilter.allCases) { Text($0.title).tag($0) }
                }
            }
            Section(L("Light")) {
                ValueSlider(title: L("Exposure"), value: $model.adjustments.exposure, range: -2...2, format: signed(" EV", factor: 1, decimals: 1))
                ValueSlider(title: L("Brightness"), value: $model.adjustments.brightness, range: -0.5...0.5, format: signed("", factor: 200))
                ValueSlider(title: L("Contrast"), value: $model.adjustments.contrast, range: 0.5...1.5, format: { signed("", factor: 200)($0 - 1) })
                ValueSlider(title: L("Highlights"), value: $model.adjustments.highlights, range: 0...1)
                ValueSlider(title: L("Shadows"), value: $model.adjustments.shadows, range: -1...1, format: signed("", factor: 100))
            }
            Section(L("Color")) {
                ValueSlider(title: L("Saturation"), value: $model.adjustments.saturation, range: 0...2, format: { signed("", factor: 100)($0 - 1) })
                ValueSlider(title: L("Vibrance"), value: $model.adjustments.vibrance, range: -1...1, format: signed("", factor: 100))
                ValueSlider(title: L("Temperature"), value: $model.adjustments.warmth, range: -1...1, format: signed("", factor: 100))
                ValueSlider(title: L("Tint"), value: $model.adjustments.tint, range: -1...1, format: signed("", factor: 100))
            }
            Section(L("Detail")) {
                ValueSlider(title: L("Sharpness"), value: $model.adjustments.sharpness, range: 0...1)
                ValueSlider(title: L("Noise Reduction"), value: $model.adjustments.noise, range: 0...1)
                ValueSlider(title: L("Vignette"), value: $model.adjustments.vignette, range: 0...1)
            }
            if model.urls.count > 1 {
                Section { InspectorNote(text: L("The same adjustments are applied to the %@ images (“(%@)”).", model.urls.count, L("adjusted"))) }
            }
        }
    }

    /// Press and hold to see the original — feedback on press, not on release.
    private var compareButton: some View {
        Text(model.showOriginal ? L("Original") : L("Press and hold to compare"))
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !model.showOriginal { model.showOriginal = true } }
                .onEnded { _ in model.showOriginal = false })
            .opacity(model.adjustments.isNeutral ? 0 : 1)
    }

    private func signed(_ unit: String, factor: Double, decimals: Int = 0) -> (Double) -> String {
        { value in
            let scaled = value * factor
            let text = decimals > 0 ? String(format: "%.\(decimals)f", scaled) : String(Int(scaled.rounded()))
            return (scaled > 0.0001 ? "+" : "") + text + unit
        }
    }
}
