import Foundation

enum ArchiveTools: ConversionFamily {
    static func targets(from source: Format) -> [Format] {
        source.group == .archive ? [.zip, .tar, .tgz] : []
    }

    static func convert(_ url: URL, from source: Format, to target: Format) throws -> [URL] {
        let workspace = try Output.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try unpack(url, from: source, into: workspace)
        removeEscapingLinks(in: workspace)
        let items = try FileManager.default.contentsOfDirectory(at: workspace, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != "__MACOSX" }
        let out = Output.url(for: url, ext: target.ext)
        try pack(items, as: target, to: out)
        return [out]
    }

    static func unpack(_ url: URL, from source: Format, into directory: URL) throws {
        if source == .zip {
            try runChecked("/usr/bin/ditto", ["-x", "-k", url.path, directory.path], what: L("Extracting the ZIP"))
        } else {
            // macOS tar is libarchive: it also reads RAR and 7z.
            try runChecked("/usr/bin/tar", ["-xf", url.path, "-C", directory.path], what: L("Extracting the archive"))
        }
    }

    /// Symbolic links that point outside the extracted tree (to /etc, to the home folder…) are dropped:
    /// once moved next to the archive they would give a hostile archive a way out. Links inside the tree stay.
    static func removeEscapingLinks(in root: URL) {
        let base = root.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { continue }
            let resolved = URL(fileURLWithPath: destination, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
                .resolvingSymlinksInPath().path
            if !(resolved == base || resolved.hasPrefix(base + "/")) {
                try? FileManager.default.removeItem(at: url)
                Fidelity.note(L("Shortcuts in the archive that pointed outside it were left out, for safety."))
            }
        }
    }

    /// Extracts next to the archive; a single top-level folder is lifted out, like Archive Utility.
    static func extract(_ url: URL) throws -> [URL] {
        guard let source = Format.detect(url), source.group == .archive else {
            throw Problem(L("“%@” isn’t a ZIP, TAR, RAR or 7z archive.", url.lastPathComponent), suggestion: FileCheck.mismatch(url))
        }
        let destination = Output.folder(for: url, suffix: "")
        let workspace = try Output.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try unpack(url, from: source, into: workspace)
        removeEscapingLinks(in: workspace)
        let items = try FileManager.default.contentsOfDirectory(at: workspace, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { $0.lastPathComponent != "__MACOSX" && $0.lastPathComponent != ".DS_Store" }
        guard !items.isEmpty else { throw Problem(L("“%@” opened, but there is nothing inside.", url.lastPathComponent)) }
        if items.count == 1 {
            let single = items[0]
            let target = Output.unique(url.deletingLastPathComponent().appendingPathComponent(single.lastPathComponent),
                                       isDirectory: single.hasDirectoryPath)
            try FileManager.default.moveItem(at: single, to: target)
            return [target]
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in items {
            try FileManager.default.moveItem(at: item, to: destination.appendingPathComponent(item.lastPathComponent))
        }
        return [destination]
    }

    /// Creates a zip/tar/tar.gz with the items' names relative to their folder.
    static func pack(_ items: [URL], as format: Format, to out: URL) throws {
        guard !items.isEmpty else { throw Problem(L("There are no files to put in the archive.")) }
        var staging: URL?
        defer { if let staging { try? FileManager.default.removeItem(at: staging) } }
        var parent = items[0].deletingLastPathComponent()
        if !items.allSatisfy({ $0.deletingLastPathComponent().path == parent.path }) {
            let dir = try Output.scratchDirectory()
            staging = dir
            for item in items {
                try FileManager.default.copyItem(at: item, to: Output.unique(dir.appendingPathComponent(item.lastPathComponent)))
            }
            parent = dir
        }
        let names = try staging.map { try FileManager.default.contentsOfDirectory(atPath: $0.path) } ?? items.map(\.lastPathComponent)
        let temp = Output.tempSibling(of: out)
        do {
            switch format {
            case .zip:
                try runChecked("/usr/bin/zip", ["-r", "-y", "-q", temp.path] + names + ["-x", "*.DS_Store", "__MACOSX/*"], cwd: parent, what: L("Creating the ZIP"))
            case .tar:
                try runChecked("/usr/bin/tar", ["--exclude", ".DS_Store", "-cf", temp.path, "-C", parent.path] + names, what: L("Creating the TAR"))
            case .tgz:
                try runChecked("/usr/bin/tar", ["--exclude", ".DS_Store", "-czf", temp.path, "-C", parent.path] + names, what: L("Creating the TAR.GZ"))
            default:
                throw Problem(L("Split only creates ZIP, TAR and TAR.GZ archives (not %@).", format.label), suggestion: L("RAR and 7z are closed formats or need their own apps."))
            }
        } catch {
            Output.discard(temp)
            throw error
        }
        try Output.commit(temp, to: out)
    }
}
