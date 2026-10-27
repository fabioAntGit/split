import AppKit
import SwiftUI

enum CropAspect: String, CaseIterable, Identifiable {
    case free, original, square, r4x3, r3x4, r4x5, r5x4, r16x9, r9x16, r3x2, r2x3
    case instagramPost, instagramPortrait, instagramLandscape, story, youtube, linkPost, xHeader, facebookCover, linkedInBanner

    var id: String { rawValue }

    /// The formats of the social networks, shown apart in the picker. Only their shape is kept:
    /// the networks resize pictures themselves, and enlarging a small one would only soften it.
    static let social: [CropAspect] = [.instagramPost, .instagramPortrait, .instagramLandscape, .story, .youtube, .linkPost,
                                       .xHeader, .facebookCover, .linkedInBanner]
    static let general = allCases.filter { !social.contains($0) }

    var title: String {
        switch self {
        case .free: return L("Free")
        case .original: return L("Original")
        case .square: return L("Square")
        case .r4x3: return "4:3"
        case .r3x4: return "3:4"
        case .r4x5: return "4:5"
        case .r5x4: return "5:4"
        case .r16x9: return "16:9"
        case .r9x16: return "9:16"
        case .r3x2: return "3:2"
        case .r2x3: return "2:3"
        case .instagramPost: return "\(L("Instagram Post")) 1:1"
        case .instagramPortrait: return "\(L("Instagram Portrait")) 4:5"
        case .instagramLandscape: return "\(L("Instagram Landscape")) 1.91:1"
        case .story: return "\(L("Story, Reel or TikTok")) 9:16"
        case .youtube: return "YouTube 16:9"
        case .linkPost: return "\(L("Link Post (Facebook, LinkedIn)")) 1.91:1"
        case .xHeader: return "\(L("X Header")) 3:1"
        case .facebookCover: return "\(L("Facebook Cover")) 2.7:1"
        case .linkedInBanner: return "\(L("LinkedIn Banner")) 4:1"
        }
    }

    /// Width ÷ height in pixels; nil when free.
    func ratio(original: CGSize) -> CGFloat? {
        switch self {
        case .free: return nil
        case .original: return original.width / max(original.height, 1)
        case .square: return 1
        case .r4x3: return 4.0 / 3
        case .r3x4: return 3.0 / 4
        case .r4x5: return 4.0 / 5
        case .r5x4: return 5.0 / 4
        case .r16x9: return 16.0 / 9
        case .r9x16: return 9.0 / 16
        case .r3x2: return 3.0 / 2
        case .r2x3: return 2.0 / 3
        case .instagramPost: return 1
        case .instagramPortrait: return 4.0 / 5
        case .instagramLandscape, .linkPost: return 1.91
        case .story: return 9.0 / 16
        case .youtube: return 16.0 / 9
        case .xHeader: return 3
        case .facebookCover: return 851.0 / 315
        case .linkedInBanner: return 4
        }
    }
}

/// Crop in normalised coordinates (top-left origin) of the rotated/flipped image.
struct CropSettings: Equatable {
    static let full = CGRect(x: 0, y: 0, width: 1, height: 1)
    var turns = 0
    var flipH = false
    var flipV = false
    var rect = CropSettings.full
    /// Set for a fixed format (4:5, 16:9…), so every picture of a batch gets that shape even
    /// when the pictures differ in size.
    var shape: CropShape?

    var isIdentity: Bool { turns % 4 == 0 && !flipH && !flipV && rect == CropSettings.full }
}

/// A fixed crop format: its pixel width ÷ height, and how large the crop is next to the
/// largest crop of that shape the picture allows.
struct CropShape: Equatable {
    var ratio: CGFloat
    var scale: CGFloat
}

enum CropHandle {
    case move, topLeft, topRight, bottomLeft, bottomRight, top, bottom, left, right
}

enum CropRenderer {
    /// Quarter turns clockwise, then mirroring as seen on screen.
    static func transform(_ image: CGImage, turns: Int, flipH: Bool, flipV: Bool) throws -> CGImage {
        let quarter = ((turns % 4) + 4) % 4
        if quarter == 0 && !flipH && !flipV { return image }
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let size = quarter % 2 == 0 ? CGSize(width: w, height: h) : CGSize(width: h, height: w)
        guard let context = ImageConverter.bitmapContext(size) else { throw ImageConverter.outOfMemory(size) }
        context.interpolationQuality = .high
        context.translateBy(x: size.width / 2, y: size.height / 2)
        if flipH { context.scaleBy(x: -1, y: 1) }
        if flipV { context.scaleBy(x: 1, y: -1) }
        context.rotate(by: -CGFloat(quarter) * .pi / 2)
        context.draw(image, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        guard let result = context.makeImage() else { throw ImageConverter.outOfMemory(size) }
        return result
    }

    static func render(_ image: CGImage, _ settings: CropSettings) throws -> CGImage {
        let transformed = try transform(image, turns: settings.turns, flipH: settings.flipH, flipV: settings.flipV)
        let size = CGSize(width: transformed.width, height: transformed.height)
        let rect = self.rect(settings, in: size)
        guard rect != CropSettings.full else { return transformed }
        let pixels = Imaging.pixels(rect, in: size).integral.intersection(CGRect(origin: .zero, size: size))
        guard pixels.width >= 1, pixels.height >= 1, let cropped = transformed.cropping(to: pixels) else {
            throw Problem(L("The crop area is empty."), suggestion: L("Make the selection bigger and try again."))
        }
        return cropped
    }

    /// The crop for a picture of `size`: the drawn rect, or for a fixed format the same shape,
    /// relative size and centre on this picture.
    static func rect(_ settings: CropSettings, in size: CGSize) -> CGRect {
        guard let shape = settings.shape else { return settings.rect }
        let center = CGPoint(x: settings.rect.midX, y: settings.rect.midY)
        let largest = fitted(ratio: shape.ratio, imageSize: size, center: center)
        let width = min(1, largest.width * shape.scale)
        let height = min(1, largest.height * shape.scale)
        let x = min(max(center.x - width / 2, 0), 1 - width)
        let y = min(max(center.y - height / 2, 0), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Largest rect with `ratio` (pixel width ÷ height) inside the image, centred on `center`.
    static func fitted(ratio: CGFloat, imageSize: CGSize, center: CGPoint) -> CGRect {
        let normalised = ratio * imageSize.height / max(imageSize.width, 1)
        let width = normalised >= 1 ? 1 : normalised
        let height = normalised >= 1 ? 1 / normalised : 1
        let x = min(max(center.x - width / 2, 0), 1 - width)
        let y = min(max(center.y - height / 2, 0), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Which handle a point (in view coordinates) grabs; corners win over edges, edges over moving.
    static func handle(at point: CGPoint, crop: CGRect, frame: CGRect) -> CropHandle? {
        let r = CGRect(x: frame.minX + crop.minX * frame.width, y: frame.minY + crop.minY * frame.height,
                       width: crop.width * frame.width, height: crop.height * frame.height)
        let corner: CGFloat = 18
        let edge: CGFloat = 10
        func near(_ a: CGPoint) -> Bool { abs(point.x - a.x) <= corner && abs(point.y - a.y) <= corner }
        if near(CGPoint(x: r.minX, y: r.minY)) { return .topLeft }
        if near(CGPoint(x: r.maxX, y: r.minY)) { return .topRight }
        if near(CGPoint(x: r.minX, y: r.maxY)) { return .bottomLeft }
        if near(CGPoint(x: r.maxX, y: r.maxY)) { return .bottomRight }
        let insideX = point.x >= r.minX && point.x <= r.maxX
        let insideY = point.y >= r.minY && point.y <= r.maxY
        if insideX && abs(point.y - r.minY) <= edge { return .top }
        if insideX && abs(point.y - r.maxY) <= edge { return .bottom }
        if insideY && abs(point.x - r.minX) <= edge { return .left }
        if insideY && abs(point.x - r.maxX) <= edge { return .right }
        if r.contains(point) { return .move }
        return nil
    }

    /// New crop after dragging `handle` by `delta` (normalised), keeping `ratio` (normalised w÷h) if set.
    static func drag(_ handle: CropHandle, from start: CGRect, by delta: CGSize, ratio: CGFloat?) -> CGRect {
        let minimum: CGFloat = 0.03
        if handle == .move {
            let x = min(max(start.minX + delta.width, 0), 1 - start.width)
            let y = min(max(start.minY + delta.height, 0), 1 - start.height)
            return CGRect(x: x, y: y, width: start.width, height: start.height)
        }
        var minX = start.minX, minY = start.minY, maxX = start.maxX, maxY = start.maxY
        switch handle {
        case .topLeft: minX += delta.width; minY += delta.height
        case .topRight: maxX += delta.width; minY += delta.height
        case .bottomLeft: minX += delta.width; maxY += delta.height
        case .bottomRight: maxX += delta.width; maxY += delta.height
        case .top: minY += delta.height
        case .bottom: maxY += delta.height
        case .left: minX += delta.width
        case .right: maxX += delta.width
        case .move: break
        }
        minX = min(max(minX, 0), start.maxX - minimum)
        maxX = max(min(maxX, 1), start.minX + minimum)
        minY = min(max(minY, 0), start.maxY - minimum)
        maxY = max(min(maxY, 1), start.minY + minimum)
        guard let ratio else { return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY) }

        switch handle {
        case .left, .right:
            // Width drives height, centred on the original middle.
            var width = maxX - minX
            var height = width / ratio
            let available = min(start.midY, 1 - start.midY) * 2
            if height > available { height = available; width = height * ratio }
            let x = handle == .left ? start.maxX - width : start.minX
            return CGRect(x: x, y: start.midY - height / 2, width: width, height: height)
        case .top, .bottom:
            var height = maxY - minY
            var width = height * ratio
            let available = min(start.midX, 1 - start.midX) * 2
            if width > available { width = available; height = width / ratio }
            let y = handle == .top ? start.maxY - height : start.minY
            return CGRect(x: start.midX - width / 2, y: y, width: width, height: height)
        default:
            // Corners: the opposite corner stays put.
            let anchorX = (handle == .topLeft || handle == .bottomLeft) ? start.maxX : start.minX
            let anchorY = (handle == .topLeft || handle == .topRight) ? start.maxY : start.minY
            var width = maxX - minX
            var height = maxY - minY
            if width / height > ratio { width = height * ratio } else { height = width / ratio }
            let roomX = (handle == .topLeft || handle == .bottomLeft) ? anchorX : 1 - anchorX
            let roomY = (handle == .topLeft || handle == .topRight) ? anchorY : 1 - anchorY
            if width > roomX { width = roomX; height = width / ratio }
            if height > roomY { height = roomY; width = height * ratio }
            let x = (handle == .topLeft || handle == .bottomLeft) ? anchorX - width : anchorX
            let y = (handle == .topLeft || handle == .topRight) ? anchorY - height : anchorY
            return CGRect(x: x, y: y, width: width, height: height)
        }
    }
}

final class CropModel: ObservableObject {
    let urls: [URL]
    let preview: CGImage
    @Published private(set) var display: CGImage
    @Published var settings = CropSettings()
    @Published var aspect: CropAspect = .free {
        didSet { applyAspect() }
    }

    init(urls: [URL], preview: CGImage) {
        self.urls = urls
        self.preview = preview
        display = preview
    }

    var displaySize: CGSize { CGSize(width: display.width, height: display.height) }
    var normalisedRatio: CGFloat? {
        aspect.ratio(original: displaySize).map { $0 * displaySize.height / max(displaySize.width, 1) }
    }

    private func refreshDisplay() {
        display = (try? CropRenderer.transform(preview, turns: settings.turns, flipH: settings.flipH, flipV: settings.flipV)) ?? preview
    }

    func applyAspect() {
        guard let ratio = aspect.ratio(original: displaySize) else { return }
        let center = CGPoint(x: settings.rect.midX, y: settings.rect.midY)
        settings.rect = CropRenderer.fitted(ratio: ratio, imageSize: displaySize, center: center)
    }

    func rotate(clockwise: Bool) {
        let r = settings.rect
        settings.turns = (settings.turns + (clockwise ? 1 : 3)) % 4
        settings.rect = clockwise
            ? CGRect(x: 1 - r.maxY, y: r.minX, width: r.height, height: r.width)
            : CGRect(x: r.minY, y: 1 - r.maxX, width: r.height, height: r.width)
        refreshDisplay()
        applyAspect()
    }

    func flip(horizontal: Bool) {
        let r = settings.rect
        if horizontal {
            settings.flipH.toggle()
            settings.rect.origin.x = 1 - r.maxX
        } else {
            settings.flipV.toggle()
            settings.rect.origin.y = 1 - r.maxY
        }
        refreshDisplay()
    }

    func reset() {
        settings = CropSettings()
        aspect = .free
        refreshDisplay()
    }

    var resultSize: CGSize {
        CGSize(width: (settings.rect.width * displaySize.width).rounded(), height: (settings.rect.height * displaySize.height).rounded())
    }

    /// The settings to apply to every picture; "Original" keeps each picture's own shape.
    var batchSettings: CropSettings {
        var settings = self.settings
        if aspect != .original, let ratio = aspect.ratio(original: displaySize) {
            let largest = CropRenderer.fitted(ratio: ratio, imageSize: displaySize, center: CGPoint(x: 0.5, y: 0.5))
            settings.shape = CropShape(ratio: ratio, scale: settings.rect.width / max(largest.width, 0.0001))
        }
        return settings
    }

    func save() {
        let settings = batchSettings
        JobRunner.shared.each(title: L("Cropping…"), verb: (L("1 image cropped"), L("%@ images cropped")), urls: urls, width: 3) { url in
            let image = try ImageConverter.loadImage(url)
            let result = try CropRenderer.render(image, settings)
            return [try ImageSaver.save(result, like: url, suffix: " (" + L("cropped") + ")")]
        }
    }
}

struct CropScreen: View {
    @ObservedObject var model: CropModel
    let host: EditorHost
    @State private var activeHandle: CropHandle?
    @State private var startRect = CropSettings.full

    var body: some View {
        EditorScaffold(saveTitle: model.urls.count > 1 ? L("Crop %@", model.urls.count) : L("Crop"),
                       canSave: !model.settings.isIdentity,
                       onReset: { withAnimation(Motion.standard) { model.reset() } },
                       onCancel: host.close,
                       onSave: { model.save(); host.close() }) {
            GeometryReader { geometry in
                let frame = Imaging.fit(model.displaySize, in: geometry.size, margin: 36)
                ZStack {
                    Image(decorative: model.display, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                    CropOverlay(crop: model.settings.rect, frame: frame, showGrid: activeHandle != nil)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if activeHandle == nil {
                            activeHandle = CropRenderer.handle(at: value.startLocation, crop: model.settings.rect, frame: frame)
                            startRect = model.settings.rect
                        }
                        guard let handle = activeHandle, frame.width > 0 else { return }
                        let delta = CGSize(width: value.translation.width / frame.width, height: value.translation.height / frame.height)
                        model.settings.rect = CropRenderer.drag(handle, from: startRect, by: delta, ratio: model.normalisedRatio)
                    }
                    .onEnded { _ in activeHandle = nil })
            }
        } inspector: {
            Section(L("Aspect Ratio")) {
                Picker(L("Format"), selection: $model.aspect) {
                    ForEach(CropAspect.general) { Text($0.title).tag($0) }
                    Section(L("Social Media")) {
                        ForEach(CropAspect.social) { Text($0.title).tag($0) }
                    }
                }
            }
            Section(L("Rotate and Flip")) {
                HStack(spacing: 6) {
                    Button { withAnimation(Motion.standard) { model.rotate(clockwise: false) } } label: { Image(systemName: "rotate.left") }
                        .buttonStyle(ToolButtonStyle(selected: false)).iconLabel(L("Rotate 90° Left"))
                    Button { withAnimation(Motion.standard) { model.rotate(clockwise: true) } } label: { Image(systemName: "rotate.right") }
                        .buttonStyle(ToolButtonStyle(selected: false)).iconLabel(L("Rotate 90° Right"))
                    Button { model.flip(horizontal: true) } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                        .buttonStyle(ToolButtonStyle(selected: model.settings.flipH)).iconLabel(L("Flip Horizontally"))
                    Button { model.flip(horizontal: false) } label: { Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down") }
                        .buttonStyle(ToolButtonStyle(selected: model.settings.flipV)).iconLabel(L("Flip Vertically"))
                }
            }
            Section {
                LabeledContent(L("Original"), value: "\(Int(model.preview.width)) × \(Int(model.preview.height))")
                LabeledContent(L("Result"), value: "\(Int(model.resultSize.width)) × \(Int(model.resultSize.height))")
                InspectorNote(text: model.urls.count > 1
                    ? L("The same crop is applied to the %@ images, in the same shape. Each is saved next to its original with “(%@)”.", model.urls.count, L("cropped"))
                    : L("Drag the corners or sides to crop and the middle to move. The copy is saved next to the original with “(%@)”.", L("cropped")))
            } header: {
                Text(L("Size (preview)"))
            }
        }
    }
}

/// Dimmed outside area, frame, corner marks and (while dragging) the rule-of-thirds grid.
struct CropOverlay: View {
    let crop: CGRect
    let frame: CGRect
    let showGrid: Bool

    var body: some View {
        Canvas { context, _ in
            let r = CGRect(x: frame.minX + crop.minX * frame.width, y: frame.minY + crop.minY * frame.height,
                           width: crop.width * frame.width, height: crop.height * frame.height)
            var dim = Path()
            dim.addRect(frame)
            dim.addRect(r)
            context.fill(dim, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
            context.stroke(Path(r), with: .color(.white.opacity(0.9)), lineWidth: 1)
            if showGrid {
                var grid = Path()
                for i in 1...2 {
                    let x = r.minX + r.width * CGFloat(i) / 3
                    let y = r.minY + r.height * CGFloat(i) / 3
                    grid.move(to: CGPoint(x: x, y: r.minY)); grid.addLine(to: CGPoint(x: x, y: r.maxY))
                    grid.move(to: CGPoint(x: r.minX, y: y)); grid.addLine(to: CGPoint(x: r.maxX, y: y))
                }
                context.stroke(grid, with: .color(.white.opacity(0.55)), lineWidth: 0.5)
            }
            let length = min(22, r.width / 3, r.height / 3)
            var corners = Path()
            for (x, y, sx, sy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0), (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
                corners.move(to: CGPoint(x: x, y: y + sy * length))
                corners.addLine(to: CGPoint(x: x, y: y))
                corners.addLine(to: CGPoint(x: x + sx * length, y: y))
            }
            context.stroke(corners, with: .color(.white), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
            var edges = Path()
            let bar = min(18, r.width / 4, r.height / 4)
            edges.move(to: CGPoint(x: r.midX - bar / 2, y: r.minY)); edges.addLine(to: CGPoint(x: r.midX + bar / 2, y: r.minY))
            edges.move(to: CGPoint(x: r.midX - bar / 2, y: r.maxY)); edges.addLine(to: CGPoint(x: r.midX + bar / 2, y: r.maxY))
            edges.move(to: CGPoint(x: r.minX, y: r.midY - bar / 2)); edges.addLine(to: CGPoint(x: r.minX, y: r.midY + bar / 2))
            edges.move(to: CGPoint(x: r.maxX, y: r.midY - bar / 2)); edges.addLine(to: CGPoint(x: r.maxX, y: r.midY + bar / 2))
            context.stroke(edges, with: .color(.white), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
        }
        .allowsHitTesting(false)
    }
}
