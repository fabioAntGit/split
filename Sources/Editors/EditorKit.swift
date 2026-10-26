import AppKit
import CoreImage
import SwiftUI

// MARK: - Windows

/// What an editor tells its window: whether closing would lose work.
final class EditorHost {
    weak var window: NSWindow?
    var hasChanges: () -> Bool = { false }

    func close() {
        hasChanges = { false }
        window?.close()
    }
}

/// Owns editor and settings windows. While one is open the app becomes a regular app
/// (Dock icon, menu bar, ⌘-Tab), as Mac windows are expected to behave.
final class Windows: NSObject, NSWindowDelegate {
    static let shared = Windows()
    private var open: [NSWindow] = []
    private var hosts: [ObjectIdentifier: EditorHost] = [:]

    @discardableResult
    func show<Content: View>(title: String, size: NSSize, minSize: NSSize, id: String? = nil, host: EditorHost? = nil,
                             resizable: Bool = true, content: Content) -> NSWindow {
        if let id, let existing = open.first(where: { $0.identifier?.rawValue == id }) {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return existing
        }
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = minSize
        window.tabbingMode = .disallowed
        if let id { window.identifier = NSUserInterfaceItemIdentifier(id) }
        let hosting = NSHostingController(rootView: content.themed())
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(size)
        window.center()
        if let host {
            host.window = window
            hosts[ObjectIdentifier(window)] = host
        }
        open.append(window)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    var openCount: Int { open.count }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let host = hosts[ObjectIdentifier(sender)], host.hasChanges() else { return true }
        // Closing an editor throws away edits: the one case worth a confirmation.
        let alert = NSAlert()
        alert.messageText = L("Discard the changes?")
        alert.informativeText = L("The edits haven’t been saved and will be lost.")
        alert.addButton(withTitle: L("Discard"))
        alert.addButton(withTitle: L("Cancel"))
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: sender) { response in
            if response == .alertFirstButtonReturn {
                host.hasChanges = { false }
                sender.close()
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        open.removeAll { $0 === window }
        hosts[ObjectIdentifier(window)] = nil
        if open.isEmpty {
            DispatchQueue.main.async {
                guard self.open.isEmpty else { return }
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

// MARK: - Main menu (shown while a window is open)

enum MainMenu {
    static func install(target: AnyObject, settings: Selector, about: Selector) {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Split")
        let aboutItem = NSMenuItem(title: L("About Split"), action: about, keyEquivalent: "")
        aboutItem.target = target
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: L("Settings…"), action: settings, keyEquivalent: ",")
        settingsItem.target = target
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: L("Hide Split"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let others = NSMenuItem(title: L("Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(others)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: L("Quit Split"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: L("Edit"))
        edit.addItem(NSMenuItem(title: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: L("Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: L("Window"))
        window.addItem(NSMenuItem(title: L("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        window.addItem(NSMenuItem(title: L("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }
}

// MARK: - Images for editors

/// Shared Core Image context (GPU), reused by every editor and tool.
enum Imaging {
    static let context = CIContext(options: [.cacheIntermediates: false])
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func cgImage(_ image: CIImage, extent: CGRect? = nil) -> CGImage? {
        context.createCGImage(image, from: extent ?? image.extent, format: .RGBA8, colorSpace: sRGB)
    }

    /// Normalised rect (top-left origin, 0…1) → pixel rect in a CGImage of `size` (also top-left).
    static func pixels(_ rect: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: rect.minX * size.width, y: rect.minY * size.height, width: rect.width * size.width, height: rect.height * size.height)
    }

    /// Image rect that fits `size` inside `container`, centred, with a margin.
    static func fit(_ size: CGSize, in container: CGSize, margin: CGFloat = 24) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let available = CGSize(width: max(1, container.width - margin * 2), height: max(1, container.height - margin * 2))
        let scale = min(available.width / size.width, available.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: (container.width - fitted.width) / 2, y: (container.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
    }

    static func color(hex: String) -> CGColor {
        var value: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
        return CGColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

enum ImageSaver {
    /// Saves an edited image next to `source`, in the source's format when it can hold the
    /// result (PNG when transparency must survive, or when the source format can't be written).
    static func save(_ image: CGImage, like source: URL, suffix: String, needsAlpha: Bool = false) throws -> URL {
        let sourceFormat = Format.detect(source) ?? .png
        var format = sourceFormat
        if [.svg, .ico, .pdf, .gif, .bmp].contains(format) { format = .png }
        if needsAlpha && [.jpg, .bmp].contains(format) { format = .png }
        let out = Output.url(for: source, ext: format.ext, suffix: suffix)
        let metadata = (try? ImageConverter.open(source)).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        if format == .webp {
            try ImageConverter.writeWebP(image, to: out)
        } else {
            try ImageConverter.write(image, metadata: metadata, to: out, as: format)
        }
        return out
    }
}

struct EditorPreview {
    let url: URL
    let image: CGImage

    /// The image at a size that keeps editing fluid; the full resolution is used only when saving.
    static func load(_ url: URL, maxPixelSize: Int = 1800) throws -> EditorPreview {
        try FileCheck.preflight(url, waitForDownload: false)
        return EditorPreview(url: url, image: try ImageConverter.loadImage(url, maxPixelSize: maxPixelSize))
    }
}

// MARK: - Layout

/// Every editor: the work area on the left, a grouped inspector on the right,
/// Cancel / primary action at the bottom right (macOS dialog order).
struct EditorScaffold<Canvas: View, Inspector: View>: View {
    var saveTitle: String
    var canSave: Bool = true
    var onReset: (() -> Void)?
    var onCancel: () -> Void
    var onSave: () -> Void
    @ViewBuilder var canvas: () -> Canvas
    @ViewBuilder var inspector: () -> Inspector

    var body: some View {
        HStack(spacing: 0) {
            canvas()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
                .clipped()
            Divider()
            VStack(spacing: 0) {
                Form { inspector() }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                Divider()
                HStack(spacing: 8) {
                    if let onReset {
                        Button(L("Reset"), action: onReset).buttonStyle(SecondaryButtonStyle())
                    }
                    Spacer()
                    Button(L("Cancel"), action: onCancel)
                        .buttonStyle(SecondaryButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button(saveTitle, action: onSave)
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                }
                .padding(12)
            }
            .frame(width: 290)
            .background(VisualEffect(material: .sidebar, blending: .behindWindow))
        }
    }
}

/// Inspector row with a slider and its value, labels on the left like System Settings.
struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var format: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Slider(value: $value, in: range)
                .labelsHidden()
        }
    }
}

/// Square swatch used for colours and gradients; the selected one gets a ring.
struct Swatch<Fill: ShapeStyle>: View {
    let fill: Fill
    let selected: Bool
    let help: String
    let action: () -> Void
    @ObservedObject var look = LookStore.shared

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(fill)
                .frame(width: 30, height: 30)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .padding(3)
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(selected ? look.accent : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .iconLabel(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Checkerboard behind images with transparency (Preview/Photos convention).
struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 8
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.92)))
            var path = Path()
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 0 : tile
                while x < size.width {
                    path.addRect(CGRect(x: x, y: y, width: tile, height: tile))
                    x += tile * 2
                }
                y += tile
                row += 1
            }
            context.fill(path, with: .color(Color(white: 0.8)))
        }
    }
}

/// A short status line under the inspector controls (explicit, never a silent no-op).
struct InspectorNote: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
