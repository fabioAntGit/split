import AppKit
import SwiftUI

enum CollageLayout: String, CaseIterable, Identifiable {
    case grid, row, column
    var id: String { rawValue }
    var title: String {
        switch self {
        case .grid: return L("Grid")
        case .row: return L("Row")
        case .column: return L("Column")
        }
    }
    var symbol: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .row: return "rectangle.split.3x1"
        case .column: return "rectangle.split.1x2"
        }
    }
}

enum CollageFill: String, CaseIterable, Identifiable {
    case white, black, transparent, gradient
    var id: String { rawValue }
    var title: String {
        switch self {
        case .white: return L("White")
        case .black: return L("Black")
        case .transparent: return L("Transparent")
        case .gradient: return L("Gradient")
        }
    }
}

struct CollageSpec: Equatable {
    var layout: CollageLayout = .grid
    var spacing = 0.02          // fraction of the output width
    var corner = 0.0            // fraction of the smaller cell side
    var fill = true             // grid cells cropped to fill (true) or whole images (false)
    var background: CollageFill = .white
    var gradient = 0
    var width = 2400.0
}

enum CollageRenderer {
    /// Cell rects (top-left origin) and the canvas size for images with these aspect ratios.
    static func layout(aspects: [CGFloat], style: CollageSpec) -> (canvas: CGSize, cells: [CGRect]) {
        let count = aspects.count
        guard count > 0 else { return (.zero, []) }
        let width = CGFloat(style.width)
        let gap = (CGFloat(style.spacing) * width).rounded()
        switch style.layout {
        case .row:
            let height = (width - gap * CGFloat(count + 1)) / aspects.reduce(0, +)
            var x = gap
            var cells: [CGRect] = []
            for aspect in aspects {
                cells.append(CGRect(x: x, y: gap, width: height * aspect, height: height))
                x += height * aspect + gap
            }
            return (CGSize(width: width, height: (height + gap * 2).rounded()), cells)
        case .column:
            let cellWidth = width - gap * 2
            var y = gap
            var cells: [CGRect] = []
            for aspect in aspects {
                let height = cellWidth / aspect
                cells.append(CGRect(x: gap, y: y, width: cellWidth, height: height))
                y += height + gap
            }
            return (CGSize(width: width, height: y.rounded()), cells)
        case .grid:
            let columns = Int(ceil(sqrt(Double(count))))
            let rows = Int(ceil(Double(count) / Double(columns)))
            let cellWidth = (width - gap * CGFloat(columns + 1)) / CGFloat(columns)
            let sorted = aspects.sorted()
            let cellAspect = style.fill ? 1 : sorted[sorted.count / 2]
            let cellHeight = cellWidth / cellAspect
            var cells: [CGRect] = []
            for index in 0..<count {
                let row = index / columns
                let column = index % columns
                // The last row is centred when it isn't full.
                let inRow = row == rows - 1 ? count - row * columns : columns
                let offset = CGFloat(columns - inRow) * (cellWidth + gap) / 2
                cells.append(CGRect(x: gap + offset + CGFloat(column) * (cellWidth + gap), y: gap + CGFloat(row) * (cellHeight + gap),
                                    width: cellWidth, height: cellHeight))
            }
            return (CGSize(width: width, height: (CGFloat(rows) * (cellHeight + gap) + gap).rounded()), cells)
        }
    }

    static func render(_ images: [CGImage], style: CollageSpec) throws -> CGImage {
        let aspects = images.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) }
        let (canvas, cells) = layout(aspects: aspects, style: style)
        guard canvas.width >= 1, canvas.height >= 1, let context = ImageConverter.bitmapContext(canvas) else {
            throw ImageConverter.outOfMemory(canvas)
        }
        context.interpolationQuality = .high
        let full = CGRect(origin: .zero, size: canvas)
        switch style.background {
        case .white: context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(full)
        case .black: context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(full)
        case .transparent: break
        case .gradient:
            let preset = GradientPreset.all[min(max(style.gradient, 0), GradientPreset.all.count - 1)]
            if let gradient = CGGradient(colorsSpace: Imaging.sRGB, colors: preset.colors as CFArray, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: canvas.height), end: CGPoint(x: canvas.width, y: 0), options: [])
            }
        }
        for (image, cell) in zip(images, cells) {
            // Cells are top-left; Core Graphics is bottom-left.
            let rect = CGRect(x: cell.minX, y: canvas.height - cell.maxY, width: cell.width, height: cell.height)
            let size = CGSize(width: image.width, height: image.height)
            let scale = style.layout == .grid && style.fill
                ? max(rect.width / size.width, rect.height / size.height)
                : min(rect.width / size.width, rect.height / size.height)
            let drawn = CGRect(x: rect.midX - size.width * scale / 2, y: rect.midY - size.height * scale / 2,
                               width: size.width * scale, height: size.height * scale)
            let clip = style.layout == .grid && style.fill ? rect : drawn
            let radius = CGFloat(style.corner) * min(clip.width, clip.height)
            context.saveGState()
            context.addPath(CGPath(roundedRect: clip, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.clip()
            context.draw(image, in: drawn)
            context.restoreGState()
        }
        guard let result = context.makeImage() else { throw ImageConverter.outOfMemory(canvas) }
        return result
    }
}

final class CollageModel: ObservableObject {
    @Published var urls: [URL]
    @Published var thumbnails: [URL: CGImage] = [:]
    @Published var style = CollageSpec() { didSet { scheduleRender() } }
    @Published private(set) var rendered: CGImage?
    private var work: DispatchWorkItem?
    private let queue = DispatchQueue(label: "split.collage", qos: .userInteractive)

    init(urls: [URL]) {
        self.urls = urls
        for url in urls {
            if let image = try? ImageConverter.loadImage(url, maxPixelSize: 700) { thumbnails[url] = image }
        }
        scheduleRender()
    }

    var unreadable: [URL] { urls.filter { thumbnails[$0] == nil } }

    func move(from source: IndexSet, to destination: Int) {
        urls.move(fromOffsets: source, toOffset: destination)
        scheduleRender()
    }

    func remove(_ url: URL) {
        urls.removeAll { $0 == url }
        scheduleRender()
    }

    private func scheduleRender() {
        work?.cancel()
        var style = self.style
        style.width = 1200
        let images = urls.compactMap { thumbnails[$0] }
        let item = DispatchWorkItem { [weak self] in
            let image = try? CollageRenderer.render(images, style: style)
            DispatchQueue.main.async { self?.rendered = image }
        }
        work = item
        queue.async(execute: item)
    }

    func save() {
        let urls = self.urls
        let style = self.style
        guard let first = urls.first else { return }
        JobRunner.shared.single(title: L("Creating the collage…"), item: L("%@ images", urls.count), files: urls) {
            var images: [CGImage] = []
            for (index, url) in urls.enumerated() {
                // Each image is loaded at the size its cell needs, not at full resolution.
                images.append(try ImageConverter.loadImage(url, maxPixelSize: Int(style.width)))
                JobProgress.report(Double(index + 1) / Double(urls.count + 1))
            }
            let result = try CollageRenderer.render(images, style: style)
            let transparent = style.background == .transparent
            let format: Format = transparent ? .png : .jpg
            let out = Output.unique(first.deletingLastPathComponent().appendingPathComponent(L("Collage") + "." + format.ext))
            try ImageConverter.write(result, metadata: nil, to: out, as: format, quality: .high)
            return [out]
        }
    }
}

struct CollageScreen: View {
    @ObservedObject var model: CollageModel
    let host: EditorHost

    var body: some View {
        EditorScaffold(saveTitle: L("Create Collage"), canSave: model.urls.count >= 2,
                       onReset: { model.style = CollageSpec() },
                       onCancel: host.close,
                       onSave: { model.save(); host.close() }) {
            GeometryReader { geometry in
                if let rendered = model.rendered {
                    let frame = Imaging.fit(CGSize(width: rendered.width, height: rendered.height), in: geometry.size, margin: 28)
                    ZStack {
                        if model.style.background == .transparent {
                            Checkerboard().frame(width: frame.width, height: frame.height).position(x: frame.midX, y: frame.midY)
                        }
                        Image(decorative: rendered, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } inspector: {
            Section(L("Layout")) {
                Picker(L("Layout"), selection: $model.style.layout) {
                    ForEach(CollageLayout.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if model.style.layout == .grid {
                    Toggle(L("Fill the cells (crops)"), isOn: $model.style.fill)
                }
                ValueSlider(title: L("Spacing"), value: $model.style.spacing, range: 0...0.08)
                ValueSlider(title: L("Corners"), value: $model.style.corner, range: 0...0.25)
            }
            Section(L("Background")) {
                Picker(L("Background"), selection: $model.style.background) {
                    ForEach(CollageFill.allCases) { Text($0.title).tag($0) }
                }
                if model.style.background == .gradient {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 6), count: 5), spacing: 6) {
                        ForEach(GradientPreset.all.indices, id: \.self) { index in
                            Swatch(fill: GradientPreset.all[index].swiftUI, selected: model.style.gradient == index,
                                   help: GradientPreset.all[index].name) { model.style.gradient = index }
                        }
                    }
                }
                Picker(L("Width"), selection: $model.style.width) {
                    Text("1080 px").tag(1080.0)
                    Text("2400 px").tag(2400.0)
                    Text("4000 px").tag(4000.0)
                }
            }
            Section(L("Order")) {
                List {
                    ForEach(model.urls, id: \.self) { url in
                        HStack(spacing: 8) {
                            if let thumb = model.thumbnails[url] {
                                Image(decorative: thumb, scale: 1).resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            }
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { model.remove(url) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).foregroundColor(.secondary).iconLabel(L("Remove from the collage"))
                        }
                    }
                    .onMove { model.move(from: $0, to: $1) }
                }
                .frame(minHeight: 140)
                InspectorNote(text: model.unreadable.isEmpty
                    ? L("Drag to change the order. The collage is saved in the first image’s folder.")
                    : L("Couldn’t read: %@. These images are left out.", model.unreadable.map(\.lastPathComponent).joined(separator: ", ")))
            }
        }
    }
}
