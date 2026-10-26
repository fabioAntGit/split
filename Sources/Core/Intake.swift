import Foundation

/// Files as they arrive (drags, "Open With", the command line). Finder aliases and symbolic
/// links are followed to the file they point at, so the work happens on the real file and its
/// result lands next to it; the same file reached twice is only handled once.
enum Intake {
    /// Aliases can point at other aliases; a few hops is plenty and stops a loop.
    static let maxHops = 8

    static func resolve(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.map(resolve).filter { seen.insert($0.path).inserted }
    }

    static func resolve(_ url: URL) -> URL {
        guard url.isFileURL else { return url }
        var current = url.standardizedFileURL
        for _ in 0..<maxHops {
            guard let next = target(of: current), next != current else { break }
            current = next
        }
        return current
    }

    /// One hop: where a symbolic link or an alias points, or nil for an ordinary file.
    private static func target(of url: URL) -> URL? {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey])
        if values?.isSymbolicLink == true {
            // A dangling link stays as it is; the file check then explains that it is missing.
            let resolved = url.resolvingSymlinksInPath()
            return FileManager.default.fileExists(atPath: resolved.path) ? resolved.standardizedFileURL : nil
        }
        if values?.isAliasFile == true {
            // Never show UI or mount a server just to follow an alias.
            return (try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting]))?.standardizedFileURL
        }
        return nil
    }
}
