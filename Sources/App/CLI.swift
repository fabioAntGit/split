import AppKit

enum CLI {
    static let commands: Set<String> = ["convert", "targets", "tool", "doctor", "help", "--help", "-h"]

    static func run(_ arguments: [String]) -> Int32 {
        // Printing and HTML import need an NSApplication, even without a UI.
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        let command = arguments[0]
        let rest = Array(arguments.dropFirst())
        switch command {
        case "convert":
            guard rest.count >= 2, let target = Format.parse(rest[0]) else { return usage() }
            let status = each(files(rest.dropFirst())) { try Conversions.convert($0, to: target) }
            OfficeBridge.quitLaunchedApps()
            return status
        case "targets":
            for url in files(rest[...]) {
                let targets = Format.detect(url).map(Conversions.targets(for:)) ?? []
                print("\(url.lastPathComponent): \(targets.isEmpty ? "—" : targets.map(\.ext).joined(separator: " "))")
            }
            return 0
        case "tool":
            guard rest.count >= 2, let tool = QuickTool(rawValue: rest[0]) else { return usage() }
            // `tool compress-to 2MB file…`
            var targetBytes: Int?
            var paths = rest.dropFirst()
            if tool == .compressToSize {
                guard let size = paths.first.flatMap(TargetSize.parse) else { return usage() }
                targetBytes = size
                paths = paths.dropFirst()
            }
            let urls = files(paths)
            guard tool.applies(to: urls) else {
                fputs(L("✗ The tool “%@” doesn’t apply to these files. %@\n", tool.title, Explain.noTargets(urls, tools: true).suggestion ?? ""), stderr)
                return 1
            }
            do {
                let (result, notes) = try Fidelity.collect { try tool.run(urls, targetBytes: targetBytes) }
                result.outputs.forEach { print("✓ \($0.path)") }
                for note in notes { print("  ! \(note)") }
                if let message = result.message { print(message) }
                return 0
            } catch {
                fputs("✗ \(Explain.error(error, file: urls.count == 1 ? urls[0] : nil).fullText)\n", stderr)
                return 1
            }
        case "doctor":
            doctor()
            return 0
        default:
            return usage()
        }
    }

    static func files(_ paths: ArraySlice<String>) -> [URL] {
        Intake.resolve(paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) })
    }

    static func each(_ urls: [URL], _ work: (URL) throws -> [URL]) -> Int32 {
        var failures: Int32 = 0
        for url in urls {
            do {
                let (outputs, notes) = try Fidelity.collect { try work(url) }
                print("✓ \(url.lastPathComponent) → \(outputs.map(\.lastPathComponent).joined(separator: ", "))")
                for note in notes { print("  ! \(note)") }
            } catch {
                fputs("✗ \(url.lastPathComponent): \(Explain.error(error, file: url).fullText)\n", stderr)
                failures += 1
            }
        }
        return failures == 0 ? 0 : 1
    }

    static func doctor() {
        print(Doctor.report())
    }

    @discardableResult
    static func usage() -> Int32 {
        print(L("""
        Split — a local file converter

        Usage:
          splitapp convert <format> <files…>     converts (e.g. convert webp *.heic)
          splitapp targets <files…>              lists the possible formats
          splitapp tool <tool> <files…>          %@
          splitapp doctor                        checks the installed engines

        Without arguments it opens the app in the menu bar.
        """, QuickTool.allCases.map(\.rawValue).joined(separator: " | ")))
        return 2
    }
}

enum Doctor {
    static func report() -> String {
        func line(_ name: String, _ ok: Bool, _ detail: String) -> String {
            "\(ok ? "✓" : "✗") \(name) — \(detail)"
        }
        return [
            line("ffmpeg", Engines.path("ffmpeg") != nil, L("audio, video, GIF, subtitles (brew install ffmpeg)")),
            line("cwebp / gif2webp", Engines.path("cwebp") != nil, "WebP (brew install webp)"),
            line("cjxl / djxl", Engines.path("cjxl") != nil, "JPEG XL (brew install jpeg-xl)"),
            line("exiftool", Engines.path("exiftool") != nil, L("removing image metadata (brew install exiftool)")),
            line("Pages", Engines.pages, L("opening and creating .pages files")),
            line("Numbers", Engines.numbers, L("XLS and .numbers")),
            line("Keynote", Engines.keynote, L("Keynote and PPTX → PDF")),
            line("Word", Engines.word, L("DOCX/DOC → PDF with the exact layout")),
            line("Excel", Engines.excel, L("XLS/XLSX → PDF and XLSX")),
            line("PowerPoint", Engines.powerPoint, "PPTX/PPT → PDF"),
            line("LibreOffice", Engines.soffice != nil, L("an alternative for ODS/ODP/PPT (brew install --cask libreoffice)")),
            L("✓ macOS — ImageIO, PDFKit, Vision and the Cocoa text converter"),
            (Tools.canRemoveBackground ? "✓ " : "✗ ") + L("Vision — remove background (macOS 14 or later)"),
        ].joined(separator: "\n")
    }
}

/// The `splitapp` command in Terminal: a link to the app's own executable, in Homebrew's
/// folder when it can be written without an administrator, otherwise in /usr/local/bin.
enum CommandLineTool {
    static let locations = ["/opt/homebrew/bin/splitapp", "/usr/local/bin/splitapp"]

    static var executable: String { Bundle.main.executablePath ?? "/Applications/Split.app/Contents/MacOS/Split" }

    static var isInstalled: Bool {
        let app = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        return locations.contains { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == app }
    }

    /// For the user to paste in Terminal; the path is quoted for the shell.
    static var installCommand: String {
        let target = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        if FileManager.default.isWritableFile(atPath: "/opt/homebrew/bin") {
            return "ln -sf \(target) /opt/homebrew/bin/splitapp"
        }
        return "sudo mkdir -p /usr/local/bin && sudo ln -sf \(target) /usr/local/bin/splitapp"
    }
}
