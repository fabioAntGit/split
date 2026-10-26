import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The shelf: a small floating panel that holds files for a moment, so they can be
/// collected from several folders and dragged out together.
final class ShelfModel: ObservableObject {
    @Published var items: [URL] = []

    func add(_ urls: [URL]) {
        for url in urls where !items.contains(url) { items.append(url) }
    }

    func remove(_ url: URL) { items.removeAll { $0 == url } }

    /// Files moved or deleted elsewhere disappear from the shelf.
    func prune() { items.removeAll { !FileManager.default.fileExists(atPath: $0.path) } }
}

final class Shelf: NSObject, NSWindowDelegate {
    static let shared = Shelf()
    let model = ShelfModel()
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(adding urls: [URL] = []) {
        model.add(urls)
        model.prune()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible {
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 20, y: frame.midY - panel.frame.height / 2))
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.reduceMotion ? 0.12 : 0.2
                panel.animator().alphaValue = 1
            }
        }
    }

    func toggle() {
        if isVisible { panel?.close() } else { show() }
    }

    /// Internal (not private) so the tests can check the window it builds.
    func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 380),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = L("Shelf")
        panel.titlebarAppearsTransparent = true
        // Moved by its title bar only: dragging files out of the shelf must never drag the window too.
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentMinSize = NSSize(width: 240, height: 220)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ShelfView(model: model).themed())
        return panel
    }
}

struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    @State private var targeted = false
    @State private var hovered: URL?
    @ObservedObject var look = LookStore.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.items.isEmpty ? L("Shelf") : (model.items.count == 1 ? L("1 item") : L("%@ items", model.items.count)))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if !model.items.isEmpty {
                    Menu {
                        Button(L("Convert…")) { (NSApp.delegate as? AppDelegate)?.showWheel(.convert, urls: model.items, clickMode: true) }
                        Button(L("Tools…")) { (NSApp.delegate as? AppDelegate)?.showWheel(.tools, urls: model.items, clickMode: true) }
                        Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting(model.items) }
                        Divider()
                        Button(L("Empty the Shelf")) { withAnimation(Motion.standard) { model.items = [] } }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 28)
                    .iconLabel(L("Actions"))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 30)
            .padding(.bottom, 8)

            if model.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 28, weight: .light))
                        .foregroundColor(targeted ? look.accent : .secondary)
                    Text(L("Drop files here to collect them"))
                        .font(.system(size: 12, weight: .medium))
                    Text(L("Then drag them all at once to wherever you need them."))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(targeted ? look.accent : Color.primary.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                .padding(12)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.items, id: \.self) { url in
                            row(url)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                Divider()
                // The whole bar is the handle, so any press on it starts the drag of every file.
                DragAllHandle(urls: model.items)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisualEffect(material: .hudWindow, blending: .behindWindow))
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { withAnimation(Motion.standard) { model.add([url]) } }
                }
            }
            return true
        }
    }

    private func row(_ url: URL) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Text(url.deletingLastPathComponent().lastPathComponent).font(.system(size: 10.5)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovered == url {
                Button { withAnimation(Motion.standard) { model.remove(url) } } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .iconLabel(L("Remove from the shelf (the file isn’t deleted)"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovered == url ? Color.primary.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside ? url : (hovered == url ? nil : hovered) }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
    }
}

/// Starts one drag session carrying every file on the shelf.
struct DragAllHandle: NSViewRepresentable {
    let urls: [URL]

    func makeNSView(context: Context) -> DragAllView {
        let view = DragAllView()
        view.urls = urls
        return view
    }

    func updateNSView(_ view: DragAllView, context: Context) { view.urls = urls }
}

final class DragAllView: NSView, NSDraggingSource {
    var urls: [URL] = [] { didSet { needsDisplay = true } }

    /// A press here starts a file drag, never a window move.
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let icon = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: L("Drag All"))?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        var x: CGFloat = 16
        if let tinted = icon?.tinted(Palette.accent) {
            tinted.draw(in: NSRect(x: x, y: (bounds.height - tinted.size.height) / 2, width: tinted.size.width, height: tinted.size.height))
            x += tinted.size.width + 12
        }
        let title = NSAttributedString(string: L("Drag All"), attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor])
        let detail = NSAttributedString(string: L("Drop in another app or folder"), attributes: [
            .font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor.secondaryLabelColor])
        let width = bounds.width - x - 12
        let titleHeight = ceil(title.size().height)
        let detailHeight = ceil(detail.size().height)
        let top = (bounds.height + titleHeight + detailHeight + 1) / 2
        let truncating: NSString.DrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        title.draw(with: NSRect(x: x, y: top - titleHeight, width: width, height: titleHeight), options: truncating)
        detail.draw(with: NSRect(x: x, y: top - titleHeight - 1 - detailHeight, width: width, height: detailHeight), options: truncating)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard !urls.isEmpty else { return }
        let items = urls.enumerated().map { index, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let offset = CGFloat(min(index, 4)) * 3
            let origin = convert(event.locationInWindow, from: nil)
            item.setDraggingFrame(NSRect(x: origin.x - 16 + offset, y: origin.y - 16 - offset, width: 32, height: 32),
                                  contents: NSWorkspace.shared.icon(forFile: url.path))
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .link, .generic] : .generic
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { L("Drag All") }
}
