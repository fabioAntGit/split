import AppKit

enum WheelKind: String, CaseIterable {
    case convert, tools, actions

    var title: String {
        switch self {
        case .convert: return L("Conversion")
        case .tools: return L("Tools")
        case .actions: return L("Actions")
        }
    }

    var summary: String {
        switch self {
        case .convert: return L("to another format")
        case .tools: return L("edit, compress, PDF, audio…")
        case .actions: return L("AirDrop, copy, move, shelf")
        }
    }

    /// The message of the open panel from the menu bar.
    var choosePrompt: String {
        switch self {
        case .convert: return L("Choose the files to convert.")
        case .tools: return L("Choose the files for the tools.")
        case .actions: return L("Choose the files for the actions.")
        }
    }

    // Defaults: ⇧ converts, ⌘ opens the tools and ⌥ the actions. All three can be changed.
    var defaultModifier: NSEvent.ModifierFlags {
        switch self {
        case .convert: return .shift
        case .tools: return .command
        case .actions: return .option
        }
    }
}

enum FileAction: String, CaseIterable {
    case sendAirDrop, shelf, copy, copyPaths, move, terminal

    var title: String {
        switch self {
        case .sendAirDrop: return "AirDrop"
        case .shelf: return L("Shelf")
        case .copy: return L("Copy")
        case .copyPaths: return L("Copy Paths")
        case .move: return L("Move To…")
        case .terminal: return L("Open Terminal")
        }
    }

    var symbol: String {
        switch self {
        case .sendAirDrop: return "dot.radiowaves.left.and.right"
        case .shelf: return "tray.and.arrow.down"
        case .copy: return "doc.on.clipboard"
        case .copyPaths: return "link"
        case .move: return "folder"
        case .terminal: return "terminal"
        }
    }

    var detail: String {
        switch self {
        case .sendAirDrop: return L("Send to someone nearby")
        case .shelf: return L("Hold for a moment")
        case .copy: return L("To paste somewhere else")
        case .copyPaths: return L("Full path as text")
        case .move: return L("Choose another folder")
        case .terminal: return L("Terminal in this folder")
        }
    }

    func perform(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        switch self {
        case .sendAirDrop:
            guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
                HUD.shared.showNotice(Problem(L("AirDrop isn’t available right now."),
                                                      suggestion: L("Turn on Wi-Fi and Bluetooth and, in Control Center, set AirDrop to “Contacts Only” or “Everyone”.")))
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            service.perform(withItems: urls)
        case .copy:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects(urls as [NSURL])
            HUD.shared.showMessage(urls.count == 1 ? L("File copied") : L("%@ files copied", urls.count))
        case .copyPaths:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            HUD.shared.showMessage(urls.count == 1 ? L("Path copied") : L("%@ paths copied", urls.count))
        case .shelf:
            Shelf.shared.show(adding: urls)
        case .move:
            move(urls)
        case .terminal:
            let folder = urls[0].hasDirectoryPath ? urls[0] : urls[0].deletingLastPathComponent()
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                HUD.shared.showNotice(Problem(L("The Terminal app couldn’t be found."), suggestion: L("It is usually in Applications › Utilities.")))
                return
            }
            NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func move(_ urls: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("Move")
        panel.message = urls.count == 1 ? L("Choose where to move “%@”.", urls[0].lastPathComponent) : L("Choose where to move %@ items.", urls.count)
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        var moved: [URL] = []
        var failures: [JobFailure] = []
        for url in urls {
            let target = Output.unique(destination.appendingPathComponent(url.lastPathComponent), isDirectory: url.hasDirectoryPath)
            if destination.path.hasPrefix(url.path + "/") || destination.path == url.path {
                failures.append(JobFailure(file: url.lastPathComponent, error: Problem(L("A folder can’t be moved into itself."))))
                continue
            }
            if destination.path == url.deletingLastPathComponent().path {
                failures.append(JobFailure(file: url.lastPathComponent, error: Problem(L("It is already in that folder."))))
                continue
            }
            do {
                try FileManager.default.moveItem(at: url, to: target)
                moved.append(target)
            } catch {
                failures.append(JobFailure(file: url.lastPathComponent, error: Explain.error(error, file: url)))
            }
        }
        HUD.shared.showDone(outputs: moved, message: failures.isEmpty ? (moved.count == 1 ? L("Moved") : L("%@ items moved", moved.count))
                                : (moved.isEmpty ? L("Nothing was moved") : L("%@ of %@ moved", moved.count, urls.count)),
                            failures: failures, total: urls.count)
    }
}
