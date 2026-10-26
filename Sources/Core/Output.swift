import Foundation

// MARK: - Output naming (results are saved beside the originals, which stay untouched)

enum Output {
    static func baseName(_ source: URL) -> String {
        var name = source.deletingPathExtension().lastPathComponent
        if name.lowercased().hasSuffix(".tar") { name = String(name.dropLast(4)) }
        return name
    }

    static func url(for source: URL, ext: String, suffix: String = "", in directory: URL? = nil) -> URL {
        let folder = directory ?? source.deletingLastPathComponent()
        return unique(folder.appendingPathComponent(baseName(source) + suffix + "." + ext))
    }

    static func folder(for source: URL, suffix: String) -> URL {
        unique(source.deletingLastPathComponent().appendingPathComponent(baseName(source) + suffix), isDirectory: true)
    }

    /// Names handed out but not written yet: parallel jobs must not pick the same output.
    private static var reserved = Set<String>()
    private static let reservationLock = NSLock()

    static func unique(_ url: URL, isDirectory: Bool = false) -> URL {
        reservationLock.lock()
        defer { reservationLock.unlock() }
        let fm = FileManager.default
        func taken(_ candidate: URL) -> Bool { fm.fileExists(atPath: candidate.path) || reserved.contains(candidate.path) }
        if !taken(url) {
            reserved.insert(url.path)
            return url
        }
        let directory = url.deletingLastPathComponent()
        var base = url.lastPathComponent
        var ext = ""
        if !isDirectory {
            if base.lowercased().hasSuffix(".tar.gz") {
                ext = "tar.gz"
                base = String(base.dropLast(7))
            } else if !url.pathExtension.isEmpty {
                ext = url.pathExtension
                base = url.deletingPathExtension().lastPathComponent
            }
        }
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !taken(candidate) {
                reserved.insert(candidate.path)
                return candidate
            }
            index += 1
        }
    }

    /// Hidden temp file next to the final output; renamed only when the engine succeeds.
    static func tempSibling(of final: URL) -> URL {
        final.deletingLastPathComponent()
            .appendingPathComponent(".split-\(UUID().uuidString.prefix(8))-\(final.lastPathComponent)")
    }

    static func commit(_ temp: URL, to final: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: temp.path) else {
            throw Problem(L("The engine finished without errors but didn’t create the output file."),
                          suggestion: L("This usually happens when the source has no usable content (for example, a video without pictures). Try another format."))
        }
        try fm.moveItem(at: temp, to: final)
    }

    static func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        reservationLock.lock()
        reserved.remove(url.path)
        reservationLock.unlock()
    }

    static func scratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("split-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
