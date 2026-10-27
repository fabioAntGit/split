import AppKit
import SwiftUI

/// Tools that open a window, listed first in the tools wheel.
enum EditorTool: String, CaseIterable {
    case crop, annotate, adjust, background, collage, media, pdfPages

    var title: String {
        switch self {
        case .crop: return L("Crop")
        case .annotate: return L("Annotate and Cover")
        case .adjust: return L("Adjust")
        case .background: return L("Add Background")
        case .collage: return L("Collage")
        case .media: return L("Edit Media")
        case .pdfPages: return L("Organize PDF")
        }
    }

    var symbol: String {
        switch self {
        case .crop: return "crop.rotate"
        case .annotate: return "pencil.tip.crop.circle"
        case .adjust: return "slider.horizontal.3"
        case .background: return "square.on.square.dashed"
        case .collage: return "square.grid.2x2"
        case .media: return "timeline.selection"
        case .pdfPages: return "doc.richtext"
        }
    }

    var detail: String {
        switch self {
        case .crop: return L("Crop, rotate, flip")
        case .annotate: return L("Arrows, text, blur")
        case .adjust: return L("Light, color and filters")
        case .background: return L("Frame and background")
        case .collage: return L("Several images in one")
        case .media: return L("Trim, speed, cover")
        case .pdfPages: return L("Reorder, rotate, delete")
        }
    }

    /// What it does and which files it takes, for Settings.
    var explanation: String {
        switch self {
        case .crop: return L("Crop, straighten, rotate or flip pictures, several at once. For images.")
        case .annotate: return L("Draw arrows, shapes and text, or blur and cover what shouldn’t be seen. For up to 4 images.")
        case .adjust: return L("Change light, colour and sharpness, or apply a filter. For images.")
        case .background: return L("Put a picture on a coloured background or in a frame, with rounded corners and a shadow. For images.")
        case .collage: return L("Arrange several pictures into one image. For 2 to 30 images.")
        case .media: return L("Trim, change the speed and volume, fade, crop or cover parts of a video or a sound. For audio and video.")
        case .pdfPages: return L("Reorder, rotate, duplicate, delete and insert pages, or save some apart. For PDFs.")
        }
    }

    func applies(to urls: [URL]) -> Bool {
        let formats = urls.compactMap(Format.detect)
        guard formats.count == urls.count, !formats.isEmpty else { return false }
        let images = formats.allSatisfy { $0.group == .image }
        switch self {
        case .crop, .adjust, .background: return images && urls.count <= 100
        case .annotate: return images && urls.count <= 4
        case .collage: return images && urls.count >= 2 && urls.count <= 30
        case .media: return formats.allSatisfy { [.audio, .video].contains($0.group) } && urls.count <= 3
        case .pdfPages:
            return formats.contains(.pdf) && formats.allSatisfy { $0 == .pdf || $0.group == .image } && urls.count <= 20
        }
    }

    static func available(for urls: [URL]) -> [EditorTool] { allCases.filter { $0.applies(to: urls) } }

    private func windowTitle(_ urls: [URL]) -> String {
        let subject = urls.count == 1 ? urls[0].lastPathComponent : (urls.allSatisfy { Format.detect($0)?.group == .image } ? L("%@ images", urls.count) : L("%@ files", urls.count))
        return "\(title) — \(subject)"
    }

    /// Opens the editor; a file that can't be read is explained instead of opening an empty window.
    func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let size = NSSize(width: 1120, height: 740)
        let minimum = NSSize(width: 780, height: 500)
        do {
            switch self {
            case .crop:
                let model = CropModel(urls: urls, preview: try EditorPreview.load(urls[0]).image)
                let host = EditorHost()
                host.hasChanges = { [weak model] in !(model?.settings.isIdentity ?? true) }
                Windows.shared.show(title: windowTitle(urls), size: size, minSize: minimum, host: host, content: CropScreen(model: model, host: host))
            case .annotate:
                for url in urls {
                    let model = AnnotateModel(url: url, preview: try EditorPreview.load(url, maxPixelSize: 1600).image)
                    let host = EditorHost()
                    host.hasChanges = { [weak model] in !(model?.marks.isEmpty ?? true) }
                    Windows.shared.show(title: windowTitle([url]), size: size, minSize: minimum, host: host, content: AnnotateScreen(model: model, host: host))
                }
            case .adjust:
                let model = AdjustModel(urls: urls, preview: try EditorPreview.load(urls[0]).image)
                let host = EditorHost()
                host.hasChanges = { [weak model] in !(model?.adjustments.isNeutral ?? true) }
                Windows.shared.show(title: windowTitle(urls), size: size, minSize: minimum, host: host, content: AdjustScreen(model: model, host: host))
            case .background:
                let model = BackgroundModel(urls: urls, preview: try EditorPreview.load(urls[0]).image)
                let host = EditorHost()
                Windows.shared.show(title: windowTitle(urls), size: size, minSize: minimum, host: host, content: BackgroundScreen(model: model, host: host))
            case .collage:
                for url in urls { try FileCheck.preflight(url, waitForDownload: false) }
                let model = CollageModel(urls: urls)
                if model.thumbnails.isEmpty {
                    throw Problem(L("None of the images could be read."), suggestion: L("Check that they open in Preview."))
                }
                let host = EditorHost()
                Windows.shared.show(title: windowTitle(urls), size: size, minSize: minimum, host: host, content: CollageScreen(model: model, host: host))
            case .media:
                for url in urls {
                    let model = MediaEditorModel(url: url)
                    let host = EditorHost()
                    host.hasChanges = { [weak model] in !(model?.edit.isIdentity ?? true) }
                    Windows.shared.show(title: windowTitle([url]), size: NSSize(width: 1160, height: 760), minSize: minimum, host: host,
                                        content: MediaScreen(model: model, host: host))
                }
            case .pdfPages:
                for url in urls { try FileCheck.preflight(url, waitForDownload: false) }
                let model = try PDFOrganizerModel(urls: urls)
                let host = EditorHost()
                host.hasChanges = { [weak model] in model?.hasChanges ?? false }
                Windows.shared.show(title: windowTitle(urls), size: size, minSize: minimum, host: host, content: PDFOrganizerView(model: model, host: host))
            }
        } catch {
            HUD.shared.showError(Explain.error(error, file: urls.first), title: L("Couldn’t open the editor “%@”", title))
        }
    }
}

/// Items for the tools wheel: editors first, then one-click tools.
enum ToolCatalog {
    static func items(for urls: [URL]) -> [WheelItem] {
        let editors = EditorTool.available(for: urls).map { editor in
            WheelItem(id: editor.rawValue, title: editor.title, symbol: editor.symbol, detail: editor.detail) { editor.open($0) }
        }
        let tools = QuickTool.available(for: urls).map { tool in
            WheelItem(id: tool.rawValue, title: tool.title, symbol: tool.symbol, detail: tool.detail) { chosen in
                guard tool == .compressToSize else { return JobRunner.shared.tool(tool, chosen) }
                // Asked after the wheel closes, so the dialog isn't covered by it.
                DispatchQueue.main.async {
                    guard let bytes = TargetSize.ask(for: chosen) else { return }
                    JobRunner.shared.tool(tool, chosen, targetBytes: bytes)
                }
            }
        }
        return editors + tools
    }
}
