import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct PageItem: Identifiable, Equatable {
    let id = UUID()
    let source: Int        // index into the model's documents
    let page: Int          // page index inside that document
    var rotation = 0       // extra rotation in degrees (multiples of 90)

    static func == (a: PageItem, b: PageItem) -> Bool { a.id == b.id && a.rotation == b.rotation }
}

enum PDFOrganizer {
    /// Builds the new document from the page list (pages are copied, rotations added).
    static func build(_ items: [PageItem], documents: [PDFDocument]) throws -> PDFDocument {
        let result = PDFDocument()
        for item in items {
            guard documents.indices.contains(item.source), let page = documents[item.source].page(at: item.page)?.copy() as? PDFPage else {
                throw Problem(L("One of the pages is no longer available in its source document."))
            }
            page.rotation = ((page.rotation + item.rotation) % 360 + 360) % 360
            result.insert(page, at: result.pageCount)
        }
        guard result.pageCount > 0 else { throw Problem(L("The document would have no pages left."), suggestion: L("Keep at least one page.")) }
        return result
    }

    /// PDFs as they are; images become one page each.
    static func load(_ url: URL) throws -> PDFDocument {
        if Format.detect(url) == .pdf { return try PDFTools.open(url) }
        let image = try ImageConverter.loadImage(url)
        let document = PDFDocument()
        guard let page = PDFPage(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))) else {
            throw Problem(L("Couldn’t turn “%@” into a PDF page.", url.lastPathComponent))
        }
        document.insert(page, at: 0)
        return document
    }

    static func write(_ document: PDFDocument, to out: URL) throws {
        let temp = Output.tempSibling(of: out)
        guard document.write(to: temp) else {
            Output.discard(temp)
            throw Problem(L("PDFKit couldn’t save the PDF."), suggestion: FileCheck.privacyHint(for: out.deletingLastPathComponent()))
        }
        try Output.commit(temp, to: out)
    }
}

final class PDFOrganizerModel: ObservableObject {
    let first: URL
    @Published var documents: [PDFDocument] = []
    @Published var names: [String] = []
    @Published var items: [PageItem] = []
    @Published var selection = Set<UUID>()
    @Published var thumbnails: [UUID: NSImage] = [:]
    @Published var note: String?
    private var original: [PageItem] = []

    init(urls: [URL]) throws {
        first = urls[0]
        for url in urls { try add(url) }
        original = items
    }

    var hasChanges: Bool { items != original }

    func add(_ url: URL) throws {
        let document = try PDFOrganizer.load(url)
        let index = documents.count
        documents.append(document)
        names.append(url.lastPathComponent)
        for page in 0..<document.pageCount {
            let item = PageItem(source: index, page: page)
            items.append(item)
            if let pdfPage = document.page(at: page) {
                thumbnails[item.id] = pdfPage.thumbnail(of: NSSize(width: 240, height: 300), for: .mediaBox)
            }
        }
    }

    func addFiles(_ urls: [URL]) {
        var failed: [String] = []
        for url in Intake.resolve(urls) {
            do { try add(url) } catch { failed.append("\(url.lastPathComponent): \(Explain.error(error, file: url).message)") }
        }
        note = failed.isEmpty ? nil : L("Couldn’t add: %@", failed.joined(separator: " · "))
    }

    private var targets: Set<UUID> { selection.isEmpty ? Set(items.map(\.id)) : selection }

    func rotate(by degrees: Int) {
        let targets = self.targets
        items = items.map { item in
            guard targets.contains(item.id) else { return item }
            var copy = item
            copy.rotation = (item.rotation + degrees + 360) % 360
            return copy
        }
    }

    func removeSelected() {
        guard !selection.isEmpty else { return }
        if selection.count == items.count {
            note = L("You can’t delete every page: the PDF would be empty.")
            return
        }
        items.removeAll { selection.contains($0.id) }
        selection = []
    }

    func duplicateSelection() {
        var result: [PageItem] = []
        for item in items {
            result.append(item)
            if selection.contains(item.id) {
                var copy = PageItem(source: item.source, page: item.page)
                copy.rotation = item.rotation
                result.append(copy)
                thumbnails[copy.id] = thumbnails[item.id]
            }
        }
        items = result
    }

    func move(_ id: UUID, before target: UUID) {
        guard id != target, let from = items.firstIndex(where: { $0.id == id }), let to = items.firstIndex(where: { $0.id == target }) else { return }
        let item = items.remove(at: from)
        items.insert(item, at: to)
    }

    func toggle(_ id: UUID, extend: Bool) {
        if extend {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = selection == [id] ? [] : [id]
        }
    }

    func save(onlySelection: Bool) {
        let chosen = onlySelection ? items.filter { selection.contains($0.id) } : items
        let documents = self.documents
        let first = self.first
        let suffix = " (" + (onlySelection ? L("extracted pages") : L("organized")) + ")"
        JobRunner.shared.single(title: onlySelection ? L("Extracting pages…") : L("Saving the PDF…"), item: first.lastPathComponent) {
            let document = try PDFOrganizer.build(chosen, documents: documents)
            let out = Output.url(for: first, ext: "pdf", suffix: suffix)
            try PDFOrganizer.write(document, to: out)
            return [out]
        }
    }
}

struct PDFOrganizerView: View {
    @ObservedObject var model: PDFOrganizerModel
    let host: EditorHost
    @ObservedObject var look = LookStore.shared
    @State private var dragged: UUID?

    var body: some View {
        EditorScaffold(saveTitle: L("Save PDF"), canSave: !model.items.isEmpty,
                       onCancel: host.close,
                       onSave: { model.save(onlySelection: false); host.close() }) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 18)], spacing: 22) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        pageCell(item, number: index + 1)
                            .onDrag {
                                dragged = item.id
                                return NSItemProvider(object: item.id.uuidString as NSString)
                            }
                            .onDrop(of: [UTType.text], delegate: PageDropDelegate(target: item.id, model: model, dragged: $dragged))
                    }
                }
                .padding(24)
            }
            .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                loadFiles(providers)
                return true
            }
        } inspector: {
            Section(L("Pages")) {
                LabeledContent(L("Total"), value: "\(model.items.count)")
                LabeledContent(L("Selected"), value: model.selection.isEmpty ? L("none (applies to all)") : "\(model.selection.count)")
                HStack(spacing: 6) {
                    Button { model.rotate(by: -90) } label: { Image(systemName: "rotate.left") }
                        .buttonStyle(ToolButtonStyle(selected: false)).iconLabel(L("Rotate Left"))
                    Button { model.rotate(by: 90) } label: { Image(systemName: "rotate.right") }
                        .buttonStyle(ToolButtonStyle(selected: false)).iconLabel(L("Rotate Right"))
                    Button { model.duplicateSelection() } label: { Image(systemName: "plus.square.on.square") }
                        .buttonStyle(ToolButtonStyle(selected: false)).iconLabel(L("Duplicate the Selected Pages")).disabled(model.selection.isEmpty)
                    Button { model.removeSelected() } label: { Image(systemName: "trash") }
                        .buttonStyle(ToolButtonStyle(selected: false)).iconLabel(L("Delete the Selected Pages (⌫)")).disabled(model.selection.isEmpty)
                        .keyboardShortcut(.delete, modifiers: [])
                }
                Button(L("Select All Pages")) { model.selection = Set(model.items.map(\.id)) }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut("a", modifiers: .command)
            }
            Section(L("Combine")) {
                Button(L("Add PDFs or Images…")) { chooseFiles() }.buttonStyle(SecondaryButtonStyle())
                InspectorNote(text: L("You can also drag files from Finder onto the grid. Drag pages to change their order."))
                if let note = model.note { InspectorNote(text: note) }
            }
            Section(L("Extract")) {
                Button(L("Save Only the Selected Pages…")) { model.save(onlySelection: true); host.close() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.selection.isEmpty)
            }
        }
    }

    private func pageCell(_ item: PageItem, number: Int) -> some View {
        let selected = model.selection.contains(item.id)
        return VStack(spacing: 6) {
            ZStack {
                if let thumbnail = model.thumbnails[item.id] {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .rotationEffect(.degrees(Double(item.rotation)))
                        .animation(Motion.standard, value: item.rotation)
                } else {
                    Rectangle().fill(Color.white)
                }
            }
            .frame(width: 130, height: 160)
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? look.accent.opacity(0.18) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? look.accent : .clear, lineWidth: 2))
            .opacity(dragged == item.id ? 0.4 : 1)
            Text("\(number)")
                .font(.system(size: 11, weight: selected ? .semibold : .regular).monospacedDigit())
                .foregroundColor(selected ? .primary : .secondary)
            if model.documents.count > 1 {
                Text(model.names[item.source]).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle).frame(width: 130)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.toggle(item.id, extend: NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift)) }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf, .image]
        panel.prompt = L("Add")
        if panel.runModal() == .OK { model.addFiles(panel.urls) }
    }

    private func loadFiles(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { model.addFiles([url]) }
            }
        }
    }
}

private struct PageDropDelegate: DropDelegate {
    let target: UUID
    let model: PDFOrganizerModel
    @Binding var dragged: UUID?

    func dropEntered(info: DropInfo) {
        guard let dragged else { return }
        withAnimation(Motion.standard) { model.move(dragged, before: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragged = nil
        return true
    }
}
