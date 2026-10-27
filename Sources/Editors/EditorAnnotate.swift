import AppKit
import CoreImage
import SwiftUI
import Vision

enum MarkupTool: String, CaseIterable, Identifiable {
    case select, arrow, line, rectangle, ellipse, pen, highlighter, text, counter, blur, pixelate, redact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return L("Select and Move")
        case .arrow: return L("Arrow")
        case .line: return L("Line")
        case .rectangle: return L("Rectangle")
        case .ellipse: return L("Ellipse")
        case .pen: return L("Pen")
        case .highlighter: return L("Highlighter")
        case .text: return L("Text")
        case .counter: return L("Number")
        case .blur: return L("Blur Area")
        case .pixelate: return L("Pixelate Area")
        case .redact: return L("Cover Area")
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .pen: return "scribble"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        case .counter: return "1.circle"
        case .blur: return "drop"
        case .pixelate: return "square.grid.3x3.fill"
        case .redact: return "rectangle.fill"
        }
    }

    /// Tools that define an area (drawn from corner to corner).
    var isArea: Bool { [.rectangle, .ellipse, .blur, .pixelate, .redact].contains(self) }
    var isPrivacy: Bool { [.blur, .pixelate, .redact].contains(self) }
}

/// One annotation. Points are normalised to the image (0…1, top-left origin).
struct Mark: Identifiable, Equatable {
    let id: UUID
    var tool: MarkupTool
    var points: [CGPoint]
    var color: CGColor
    var width: CGFloat
    var text: String = ""
    var number: Int = 0

    init(tool: MarkupTool, points: [CGPoint], color: CGColor, width: CGFloat) {
        id = UUID()
        self.tool = tool
        self.points = points
        self.color = color
        self.width = width
    }

    var bounds: CGRect {
        guard let first = points.first else { return .null }
        var rect = CGRect(origin: first, size: .zero)
        for point in points.dropFirst() { rect = rect.union(CGRect(origin: point, size: .zero)) }
        return rect
    }

    func translated(by delta: CGSize) -> Mark {
        var copy = self
        copy.points = points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) }
        return copy
    }
}

enum MarkupRenderer {
    /// Blurred and pixelated copies of the whole image; privacy marks reveal them inside their area.
    static func privacyLayers(for image: CGImage) -> (blurred: CGImage?, pixelated: CGImage?) {
        let source = CIImage(cgImage: image)
        let longest = max(source.extent.width, source.extent.height)
        let blurred = source.clampedToExtent().applyingGaussianBlur(sigma: longest * 0.02).cropped(to: source.extent)
        let pixelated = source.clampedToExtent()
            .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(8, longest / 55), kCIInputCenterKey: CIVector(x: 0, y: 0)])
            .cropped(to: source.extent)
        return (Imaging.cgImage(blurred, extent: source.extent), Imaging.cgImage(pixelated, extent: source.extent))
    }

    static func needsPrivacyLayers(_ marks: [Mark]) -> Bool { marks.contains { $0.tool == .blur || $0.tool == .pixelate } }

    static func render(base: CGImage, marks: [Mark], blurred: CGImage? = nil, pixelated: CGImage? = nil, hiding: UUID? = nil) -> CGImage? {
        let size = CGSize(width: base.width, height: base.height)
        guard let context = ImageConverter.bitmapContext(size) else { return nil }
        context.interpolationQuality = .high
        let full = CGRect(origin: .zero, size: size)
        context.draw(base, in: full)
        // Draw in top-left coordinates, like the editor.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        let scale = max(size.width, size.height) / 1000
        for mark in marks where mark.id != hiding {
            draw(mark, in: context, size: size, scale: scale, blurred: blurred, pixelated: pixelated)
        }
        return context.makeImage()
    }

    private static func point(_ p: CGPoint, _ size: CGSize) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }

    static func draw(_ mark: Mark, in context: CGContext, size: CGSize, scale: CGFloat, blurred: CGImage?, pixelated: CGImage?) {
        let points = mark.points.map { point($0, size) }
        guard let first = points.first else { return }
        let last = points.last ?? first
        let lineWidth = mark.width * scale
        let area = CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
        context.saveGState()
        context.setStrokeColor(mark.color)
        context.setFillColor(mark.color)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch mark.tool {
        case .select:
            break
        case .rectangle:
            context.stroke(area.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
        case .ellipse:
            context.strokeEllipse(in: area.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
        case .line:
            context.strokeLineSegments(between: [first, last])
        case .arrow:
            let length = hypot(last.x - first.x, last.y - first.y)
            guard length > 1 else { break }
            let head = min(max(lineWidth * 4.2, 14 * scale), length * 0.6)
            let angle = atan2(last.y - first.y, last.x - first.x)
            let base = CGPoint(x: last.x - head * 0.8 * cos(angle), y: last.y - head * 0.8 * sin(angle))
            context.strokeLineSegments(between: [first, base])
            let spread: CGFloat = .pi / 7
            let left = CGPoint(x: last.x - head * cos(angle - spread), y: last.y - head * sin(angle - spread))
            let right = CGPoint(x: last.x - head * cos(angle + spread), y: last.y - head * sin(angle + spread))
            context.move(to: last)
            context.addLine(to: left)
            context.addLine(to: right)
            context.closePath()
            context.fillPath()
        case .pen, .highlighter:
            if mark.tool == .highlighter {
                context.setLineWidth(lineWidth * 3.5)
                context.setBlendMode(.multiply)
                context.setStrokeColor(mark.color.copy(alpha: 0.4) ?? mark.color)
                context.setLineCap(.butt)
            }
            context.move(to: first)
            for p in points.dropFirst() { context.addLine(to: p) }
            if points.count == 1 { context.addLine(to: CGPoint(x: first.x + 0.1, y: first.y)) }
            context.strokePath()
        case .text:
            let fontSize = (16 + mark.width * 2.2) * scale
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: NSColor(cgColor: mark.color) ?? .red,
            ]
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            NSAttributedString(string: mark.text, attributes: attributes).draw(at: first)
            NSGraphicsContext.restoreGraphicsState()
        case .counter:
            let radius = (12 + mark.width * 1.4) * scale
            context.fillEllipse(in: CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2))
            let label = NSAttributedString(string: "\(mark.number)", attributes: [
                .font: NSFont.systemFont(ofSize: radius * 1.15, weight: .bold),
                .foregroundColor: NSColor.white,
            ])
            let labelSize = label.size()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            label.draw(at: CGPoint(x: first.x - labelSize.width / 2, y: first.y - labelSize.height / 2))
            NSGraphicsContext.restoreGraphicsState()
        case .blur, .pixelate:
            guard let layer = mark.tool == .blur ? blurred : pixelated else { break }
            context.clip(to: area)
            // Images are drawn upright: undo the top-left flip locally.
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(layer, in: CGRect(origin: .zero, size: size))
        case .redact:
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(area)
        }
        context.restoreGState()
    }

    /// Faces as blur areas, slightly enlarged so hair and chin are covered.
    static func faceAreas(in image: CGImage) throws -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).map { face in
            let box = face.boundingBox
            let rect = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
            return rect.insetBy(dx: -rect.width * 0.15, dy: -rect.height * 0.2).intersection(CropSettings.full)
        }
    }
}

final class AnnotateModel: ObservableObject {
    let url: URL
    let preview: CGImage
    let blurred: CGImage?
    let pixelated: CGImage?
    @Published var marks: [Mark] = [] { didSet { refresh() } }
    @Published var tool: MarkupTool = .arrow
    @Published var color = Color(nsColor: .systemRed)
    @Published var width: Double = 4
    @Published var selection: UUID?
    @Published var editingText: UUID? { didSet { refresh() } }
    @Published private(set) var rendered: CGImage
    @Published var note: String?
    var undoManager: UndoManager?

    init(url: URL, preview: CGImage) {
        self.url = url
        self.preview = preview
        let layers = MarkupRenderer.privacyLayers(for: preview)
        blurred = layers.blurred
        pixelated = layers.pixelated
        rendered = preview
    }

    var size: CGSize { CGSize(width: preview.width, height: preview.height) }

    private func refresh() {
        rendered = MarkupRenderer.render(base: preview, marks: marks, blurred: blurred, pixelated: pixelated, hiding: editingText) ?? preview
    }

    var cgColor: CGColor { NSColor(color).usingColorSpace(.sRGB)?.cgColor ?? CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1) }

    /// Every change goes through here so it can be undone (⌘Z / Edit › Undo).
    func commit(_ new: [Mark], name: String) {
        let old = marks
        guard old != new else { return }
        marks = new
        undoManager?.registerUndo(withTarget: self) { model in model.commit(old, name: name) }
        undoManager?.setActionName(name)
    }

    func mark(at point: CGPoint) -> Mark? {
        let tolerance: CGFloat = 0.015
        return marks.reversed().first { mark in
            var box = mark.bounds
            if mark.tool == .text {
                let fontSize = (16 + mark.width * 2.2) / 1000 * max(size.width, size.height)
                box.size = CGSize(width: CGFloat(mark.text.count) * fontSize * 0.6 / size.width, height: fontSize * 1.3 / size.height)
            }
            if mark.tool == .counter {
                let radius = (12 + mark.width * 1.4) / 1000
                box = box.insetBy(dx: -radius, dy: -radius)
            }
            return box.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    func removeSelected() {
        guard let selection else { return }
        commit(marks.filter { $0.id != selection }, name: L("Delete"))
        self.selection = nil
    }

    func blurFaces() {
        do {
            let faces = try MarkupRenderer.faceAreas(in: preview)
            guard !faces.isEmpty else {
                note = L("No faces were found in this image. Use “Blur Area” to mark them by hand.")
                return
            }
            let added = faces.map { Mark(tool: .blur, points: [CGPoint(x: $0.minX, y: $0.minY), CGPoint(x: $0.maxX, y: $0.maxY)], color: cgColor, width: 4) }
            commit(marks + added, name: L("Blur Faces"))
            note = faces.count == 1 ? L("1 face blurred.") : L("%@ faces blurred.", faces.count)
        } catch {
            note = L("Face detection failed: %@", error.localizedDescription)
        }
    }

    func save() {
        let marks = self.marks
        JobRunner.shared.single(title: L("Saving annotations…"), item: url.lastPathComponent, files: [url]) { [url] in
            let image = try ImageConverter.loadImage(url)
            let layers = MarkupRenderer.needsPrivacyLayers(marks) ? MarkupRenderer.privacyLayers(for: image) : (nil, nil)
            guard let result = MarkupRenderer.render(base: image, marks: marks, blurred: layers.0, pixelated: layers.1) else {
                throw ImageConverter.outOfMemory(CGSize(width: image.width, height: image.height))
            }
            return [try ImageSaver.save(result, like: url, suffix: " (" + L("annotated") + ")")]
        }
    }
}

struct AnnotateScreen: View {
    @ObservedObject var model: AnnotateModel
    let host: EditorHost
    @Environment(\.undoManager) private var undoManager
    @State private var draft: Mark?
    @State private var moving: (id: UUID, original: Mark)?
    @State private var text = ""
    @FocusState private var textFocused: Bool

    private let colors: [(NSColor, String)] = [
        (.systemRed, L("Red")), (.systemOrange, L("Orange")), (.systemYellow, L("Yellow")), (.systemGreen, L("Green")),
        (.systemBlue, L("Blue")), (.systemPurple, L("Purple")), (.black, L("Black")), (.white, L("White")),
    ]

    var body: some View {
        EditorScaffold(saveTitle: L("Save"), canSave: !model.marks.isEmpty,
                       onReset: model.marks.isEmpty ? nil : { model.commit([], name: L("Delete All")) },
                       onCancel: host.close,
                       onSave: { finishText(); model.save(); host.close() }) {
            VStack(spacing: 0) {
                toolbar
                Divider()
                GeometryReader { geometry in
                    let frame = Imaging.fit(model.size, in: geometry.size, margin: 28)
                    ZStack(alignment: .topLeading) {
                        Image(decorative: draftImage, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                        if let id = model.selection, let mark = model.marks.first(where: { $0.id == id }) {
                            selectionBox(mark, frame: frame)
                        }
                        if let id = model.editingText, let mark = model.marks.first(where: { $0.id == id }) {
                            textField(for: mark, frame: frame)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in dragChanged(value, frame: frame) }
                        .onEnded { value in dragEnded(value, frame: frame) })
                }
            }
        } inspector: {
            Section(L("Color and Width")) {
                HStack(spacing: 4) {
                    ForEach(colors.indices, id: \.self) { index in
                        let color = colors[index].0
                        Swatch(fill: Color(nsColor: color), selected: NSColor(model.color).usingColorSpace(.sRGB) == color.usingColorSpace(.sRGB),
                               help: colors[index].1) {
                            model.color = Color(nsColor: color)
                            applyStyleToSelection()
                        }
                        .scaleEffect(0.8)
                        .frame(width: 30, height: 30)
                    }
                }
                ColorPicker(L("Other Color"), selection: $model.color, supportsOpacity: false)
                    .onChange(of: model.color) { _ in applyStyleToSelection() }
                ValueSlider(title: L("Line Width"), value: $model.width, range: 1...20, format: { "\(Int($0)) pt" })
                    .onChange(of: model.width) { _ in applyStyleToSelection() }
            }
            Section(L("Privacy")) {
                Button(L("Blur Faces Automatically")) { model.undoManager = undoManager; model.blurFaces() }
                    .buttonStyle(SecondaryButtonStyle())
                if let note = model.note { InspectorNote(text: note) }
                InspectorNote(text: L("“Cover Area” fills the area with black: it is the only option that leaves no trace of the original information."))
            }
            Section {
                InspectorNote(text: L("Drag to draw. With “Select” you can move or delete marks (⌫ key). ⌘Z undoes. The copy gets “(%@)”.", L("annotated")))
            }
        }
        .onAppear { model.undoManager = undoManager }
        .background(
            Button("") { model.removeSelected() }
                .keyboardShortcut(.delete, modifiers: [])
                .opacity(0)
                .disabled(model.selection == nil || model.editingText != nil)
        )
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            ForEach(MarkupTool.allCases) { tool in
                Button { finishText(); model.tool = tool; if tool != .select { model.selection = nil } } label: {
                    Image(systemName: tool.symbol)
                }
                .buttonStyle(ToolButtonStyle(selected: model.tool == tool))
                .iconLabel(tool.title)
                if tool == .select || tool == .counter { Divider().frame(height: 18).padding(.horizontal, 4) }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.18))
    }

    /// The marks plus the one being drawn.
    private var draftImage: CGImage {
        guard let draft else { return model.rendered }
        return MarkupRenderer.render(base: model.rendered, marks: [draft], blurred: model.blurred, pixelated: model.pixelated) ?? model.rendered
    }

    private func normalised(_ point: CGPoint, _ frame: CGRect) -> CGPoint {
        CGPoint(x: min(max((point.x - frame.minX) / frame.width, 0), 1), y: min(max((point.y - frame.minY) / frame.height, 0), 1))
    }

    private func dragChanged(_ value: DragGesture.Value, frame: CGRect) {
        guard frame.width > 0 else { return }
        let start = normalised(value.startLocation, frame)
        let current = normalised(value.location, frame)
        switch model.tool {
        case .select:
            if moving == nil {
                if let mark = model.mark(at: start) {
                    model.selection = mark.id
                    moving = (mark.id, mark)
                } else {
                    model.selection = nil
                }
            }
            guard let moving else { return }
            let delta = CGSize(width: current.x - start.x, height: current.y - start.y)
            if let index = model.marks.firstIndex(where: { $0.id == moving.id }) {
                model.marks[index] = moving.original.translated(by: delta)
            }
        case .text, .counter:
            break
        case .pen, .highlighter:
            if draft == nil { finishText(); draft = Mark(tool: model.tool, points: [start], color: model.cgColor, width: CGFloat(model.width)) }
            if let lastPoint = draft?.points.last, hypot(current.x - lastPoint.x, current.y - lastPoint.y) > 0.0015 {
                draft?.points.append(current)
            }
        default:
            if draft == nil { finishText(); draft = Mark(tool: model.tool, points: [start, start], color: model.cgColor, width: CGFloat(model.width)) }
            draft?.points[1] = current
        }
    }

    private func dragEnded(_ value: DragGesture.Value, frame: CGRect) {
        let point = normalised(value.location, frame)
        let tapped = hypot(value.translation.width, value.translation.height) < 3
        switch model.tool {
        case .select:
            if let moving, let mark = model.marks.first(where: { $0.id == moving.id }), mark != moving.original {
                // Record the move as one undoable step.
                var before = model.marks
                if let index = before.firstIndex(where: { $0.id == moving.id }) { before[index] = moving.original }
                model.marks = before
                model.commit(before.map { $0.id == mark.id ? mark : $0 }, name: L("Move"))
            }
            moving = nil
        case .text:
            finishText()
            var mark = Mark(tool: .text, points: [point], color: model.cgColor, width: CGFloat(model.width))
            mark.text = L("Text")
            model.commit(model.marks + [mark], name: L("Text"))
            text = ""
            model.editingText = mark.id
            DispatchQueue.main.async { textFocused = true }
        case .counter:
            var mark = Mark(tool: .counter, points: [point], color: model.cgColor, width: CGFloat(model.width))
            mark.number = (model.marks.filter { $0.tool == .counter }.map(\.number).max() ?? 0) + 1
            model.commit(model.marks + [mark], name: L("Number"))
        default:
            guard let finished = draft else { return }
            draft = nil
            let box = finished.bounds
            // A click without dragging doesn't leave an invisible mark behind.
            if tapped || (finished.tool.isArea && (box.width < 0.005 || box.height < 0.005)) { return }
            model.commit(model.marks + [finished], name: finished.tool.title)
        }
    }

    private func finishText() {
        guard let id = model.editingText else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var marks = model.marks
        if value.isEmpty {
            marks.removeAll { $0.id == id }
        } else if let index = marks.firstIndex(where: { $0.id == id }) {
            marks[index].text = value
        }
        model.editingText = nil
        model.commit(marks, name: L("Text"))
    }

    private func applyStyleToSelection() {
        guard let id = model.selection, let index = model.marks.firstIndex(where: { $0.id == id }) else { return }
        var marks = model.marks
        marks[index].color = model.cgColor
        marks[index].width = CGFloat(model.width)
        model.commit(marks, name: L("Style"))
    }

    private func selectionBox(_ mark: Mark, frame: CGRect) -> some View {
        var box = mark.bounds
        if mark.tool == .text || mark.tool == .counter {
            let pad: CGFloat = mark.tool == .counter ? 0.03 : 0
            box = CGRect(x: box.minX - pad, y: box.minY - pad, width: max(box.width, 0.12) + pad * 2, height: max(box.height, 0.05) + pad * 2)
        }
        let rect = CGRect(x: frame.minX + box.minX * frame.width - 6, y: frame.minY + box.minY * frame.height - 6,
                          width: box.width * frame.width + 12, height: box.height * frame.height + 12)
        return RoundedRectangle(cornerRadius: 4)
            .stroke(LookStore.shared.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
    }

    private func textField(for mark: Mark, frame: CGRect) -> some View {
        let scale = frame.width / model.size.width * max(model.size.width, model.size.height) / 1000
        let fontSize = (16 + mark.width * 2.2) * scale
        let origin = CGPoint(x: frame.minX + mark.points[0].x * frame.width, y: frame.minY + mark.points[0].y * frame.height)
        return TextField(L("Text"), text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundColor(Color(cgColor: mark.color))
            .focused($textFocused)
            .frame(width: max(160, frame.maxX - origin.x - 8), alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 3).stroke(LookStore.shared.accent, lineWidth: 1))
            .position(x: origin.x + max(160, frame.maxX - origin.x - 8) / 2, y: origin.y + fontSize * 0.65)
            .onSubmit { finishText() }
    }
}
