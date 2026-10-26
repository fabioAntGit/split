import AppKit

// Office formats are converted by asking the apps that own them (AppleScript):
// Pages/Numbers/Keynote, Word/Excel/PowerPoint, with LibreOffice as a headless fallback.
enum OfficeApp: String, CaseIterable {
    case pages = "Pages", numbers = "Numbers", keynote = "Keynote"
    case word = "Microsoft Word", excel = "Microsoft Excel", powerPoint = "Microsoft PowerPoint"

    var bundleID: String {
        switch self {
        case .pages: return "com.apple.iWork.Pages"
        case .numbers: return "com.apple.iWork.Numbers"
        case .keynote: return "com.apple.iWork.Keynote"
        case .word: return "com.microsoft.Word"
        case .excel: return "com.microsoft.Excel"
        case .powerPoint: return "com.microsoft.Powerpoint"
        }
    }

    var shortName: String { rawValue.replacingOccurrences(of: "Microsoft ", with: "") }
    var isInstalled: Bool { Engines.appInstalled(bundleID) }
    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
    var isMicrosoft: Bool { [.word, .excel, .powerPoint].contains(self) }

    /// Sandboxed apps read and write without prompts only inside their own container
    /// (Office) or in /tmp (iWork's temporary-exception entitlement).
    func stagingFolder() throws -> URL {
        let base: URL
        if isMicrosoft {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers/\(bundleID)/Data/tmp", isDirectory: true)
        } else {
            base = URL(fileURLWithPath: "/tmp", isDirectory: true)
        }
        let folder = base.appendingPathComponent("split-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

enum OfficeBridge {
    static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Apps this job launched; they are closed when the batch ends, not after every file.
    private static var launched = Set<OfficeApp>()
    private static let lock = NSLock()

    static func quitLaunchedApps() {
        lock.lock()
        let apps = launched
        launched.removeAll()
        lock.unlock()
        for app in apps where app.isRunning {
            _ = try? runProcess("/usr/bin/osascript", ["-e", "tell application \"\(app.rawValue)\" to quit saving no"], timeout: 30)
        }
    }

    /// Opens `source` in `app`, runs `exportCommand` (which writes to `dst`) and moves the result to `destination`.
    static func export(with app: OfficeApp, source: URL, destination: URL, exportCommand: String) throws {
        guard app.isInstalled else {
            throw Problem(L("%@ isn’t installed.", app.rawValue))
        }
        let staging = try app.stagingFolder()
        defer { try? FileManager.default.removeItem(at: staging) }
        // A copy inside the sandbox avoids the "grant access" dialog and keeps the original untouched.
        let stagedSource = staging.appendingPathComponent("origem." + source.pathExtension)
        try FileManager.default.copyItem(at: source, to: stagedSource)
        let stagedOutput = staging.appendingPathComponent("resultado." + destination.pathExtension)
        if !app.isRunning {
            lock.lock(); launched.insert(app); lock.unlock()
        }
        let opener: String
        let document: String
        switch app {
        case .word:
            opener = "open src"
            document = "active document"
        case .excel:
            opener = "open workbook workbook file name (src as string) update links do not update links"
            document = "active workbook"
        case .powerPoint:
            opener = "open src"
            document = "active presentation"
        default:
            opener = "set d to open src"
            document = "d"
        }
        let wait = app.isMicrosoft ? """
                repeat 120 times
                    try
                        get name of \(document)
                        exit repeat
                    end try
                    delay 0.5
                end repeat
                set d to \(document)
            """ : ""
        let script = """
        set src to POSIX file \(appleScriptString(stagedSource.path))
        set dst to (POSIX file \(appleScriptString(stagedOutput.path))) as string
        with timeout of 600 seconds
            tell application "\(app.rawValue)"
                \(opener)
                \(wait)
                \(exportCommand)
                close d saving no
            end tell
        end timeout
        """
        try runChecked("/usr/bin/osascript", ["-e", script], what: L("Exporting with %@", app.shortName), app: app.shortName)
        guard FileManager.default.fileExists(atPath: stagedOutput.path) else {
            throw Problem(L("%@ opened the file but didn’t save the result.", app.shortName),
                                  suggestion: L("Open “%@” in %@: if a warning appears (protected document, compatibility mode, external links), deal with it and try again.", source.lastPathComponent, app.shortName))
        }
        let temp = Output.tempSibling(of: destination)
        try FileManager.default.moveItem(at: stagedOutput, to: temp)
        try Output.commit(temp, to: destination)
    }

    // MARK: Pages

    static func pages(_ url: URL, from source: Format, to target: Format) throws -> [URL] {
        guard Engines.pages else {
            throw Problem(L("Converting from or to Pages needs Pages, which isn’t installed."),
                                  suggestion: L("Install it for free from the App Store."))
        }
        let out = Output.url(for: url, ext: target.ext)
        let kinds: [Format: String] = [
            .pdf: "PDF", .docx: "Microsoft Word", .epub: "EPUB", .txt: "unformatted text", .rtf: "formatted text",
        ]
        if target == .pages {
            try export(with: .pages, source: url, destination: out, exportCommand: "save d in file dst")
        } else if let kind = kinds[target] {
            try export(with: .pages, source: url, destination: out, exportCommand: "export d to file dst as \(kind)")
        } else {
            throw Problem(L("Pages doesn’t export to %@.", target.label), suggestion: L("Choose PDF, DOCX, EPUB, TXT or RTF."))
        }
        return [out]
    }

    // MARK: Word documents

    static var canUseWord: Bool { Settings.useOfficeApps && Engines.word }

    static func wordToPDF(_ url: URL) throws -> URL {
        let out = Output.url(for: url, ext: "pdf")
        try export(with: .word, source: url, destination: out, exportCommand: "save as d file name dst file format format PDF")
        return out
    }

    // MARK: Spreadsheets

    /// Formats the own XLSX reader can't parse become .xlsx first.
    static func spreadsheetToXLSX(_ url: URL, from source: Format, into directory: URL) throws -> URL {
        let out = directory.appendingPathComponent(Output.baseName(url) + ".xlsx")
        if source == .numbers || (source == .xls && Engines.numbers && !(Settings.useOfficeApps && Engines.excel)) {
            guard Engines.numbers else { throw Explain.noTargets([url], tools: false) }
            try export(with: .numbers, source: url, destination: out, exportCommand: "export d to file dst as Microsoft Excel")
            return out
        }
        if Engines.excel && source != .numbers {
            try export(with: .excel, source: url, destination: out, exportCommand: "save workbook as d filename dst file format Excel XML file format")
            return out
        }
        return try sofficeConvert(url, to: "xlsx", into: directory)
    }

    static func spreadsheetToPDF(_ url: URL, from source: Format) throws -> URL {
        let out = Output.url(for: url, ext: "pdf")
        if Settings.useOfficeApps && Engines.excel && source != .numbers {
            try export(with: .excel, source: url, destination: out, exportCommand: "save workbook as d filename dst file format PDF file format")
            return out
        }
        if Engines.numbers && source != .ods {
            try export(with: .numbers, source: url, destination: out, exportCommand: "export d to file dst as PDF")
            return out
        }
        let dir = try Output.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.moveItem(at: try sofficeConvert(url, to: "pdf", into: dir), to: out)
        return out
    }

    // MARK: Presentations

    static func presentationApp(for source: Format) -> OfficeApp? {
        let powerPoint = Engines.powerPoint && source != .key
        let keynote = Engines.keynote && source != .odp
        if powerPoint && (Settings.useOfficeApps || !keynote) && source != .odp { return .powerPoint }
        if keynote { return .keynote }
        if powerPoint { return .powerPoint }
        return nil
    }

    static func presentationToPDF(_ url: URL, from source: Format) throws -> [URL] {
        let out = Output.url(for: url, ext: "pdf")
        switch presentationApp(for: source) {
        case .powerPoint?:
            try export(with: .powerPoint, source: url, destination: out, exportCommand: "save d in dst as save as PDF")
        case .keynote?:
            try export(with: .keynote, source: url, destination: out, exportCommand: "export d to file dst as PDF")
        default:
            let dir = try Output.scratchDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            try FileManager.default.moveItem(at: try sofficeConvert(url, to: "pdf", into: dir), to: out)
        }
        return [out]
    }

    static func sofficeConvert(_ url: URL, to ext: String, into directory: URL) throws -> URL {
        guard let soffice = Engines.soffice else {
            throw Explain.noTargets([url], tools: false)
        }
        try runChecked(soffice, ["--headless", "--convert-to", ext, "--outdir", directory.path, url.path], what: L("Converting with LibreOffice"))
        let out = directory.appendingPathComponent(Output.baseName(url) + "." + ext)
        guard FileManager.default.fileExists(atPath: out.path) else {
            throw Problem(L("LibreOffice finished but didn’t create the %@.", ext.uppercased()),
                                  suggestion: L("Quit LibreOffice if it is open (its windowless mode doesn’t work while it is open) and try again."))
        }
        return out
    }
}

/// Slides only become PDF, through whichever presentation app is installed.
enum PresentationConverter: ConversionFamily {
    static func targets(from source: Format) -> [Format] {
        guard source.group == .presentation else { return [] }
        return OfficeBridge.presentationApp(for: source) != nil || Engines.soffice != nil ? [.pdf] : []
    }

    static func convert(_ url: URL, from source: Format, to target: Format) throws -> [URL] {
        let outputs = try OfficeBridge.presentationToPDF(url, from: source)
        Fidelity.note(L("The PDF shows the slides; speaker notes, animations and videos stay in the presentation."))
        return outputs
    }
}
