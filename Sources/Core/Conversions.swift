import Foundation

/// A family of conversions (images, media, documents…). Each family says what it can
/// produce from a source format with the engines installed right now, and does the work.
/// A new format plugs in by adding a family to `Conversions.families`; nothing else routes.
protocol ConversionFamily {
    static func targets(from source: Format) -> [Format]
    static func convert(_ url: URL, from source: Format, to target: Format) throws -> [URL]
}

enum Conversions {
    /// The order is the order of the wheel, and the first family that offers a target converts to it.
    static let families: [any ConversionFamily.Type] = [
        ImageConverter.self, MediaConverter.self, DocumentPipeline.self, SpreadsheetConverter.self,
        PresentationConverter.self, ArchiveTools.self, JSONConverter.self,
    ]

    static func targets(for source: Format) -> [Format] {
        var seen: Set<Format> = [source]
        return families.flatMap { $0.targets(from: source) }.filter { seen.insert($0).inserted }
    }

    /// Targets valid for every dropped file, in the order of the first file's list.
    static func targets(for urls: [URL]) -> [Format] {
        let formats = urls.map(Format.detect)
        guard !formats.isEmpty, !formats.contains(where: { $0 == nil }) else { return [] }
        let lists = formats.compactMap { $0 }.map { targets(for: $0) }
        guard var common = lists.first else { return [] }
        for list in lists.dropFirst() { common = common.filter(list.contains) }
        return common
    }

    static func convert(_ url: URL, to target: Format) throws -> [URL] {
        try FileCheck.preflight(url)
        guard let source = Format.detect(url) else { throw Explain.noTargets([url], tools: false) }
        guard target != source, let family = families.first(where: { $0.targets(from: source).contains(target) }) else {
            let targets = targets(for: source)
            if targets.isEmpty { throw Explain.noTargets([url], tools: false) }
            throw Problem(L("Split doesn’t convert %@ to %@.", source.label, target.label),
                          suggestion: L("From %@ it can make: %@.", source.label, targets.map(\.label).joined(separator: ", ")))
        }
        return try family.convert(url, from: source, to: target)
    }
}
