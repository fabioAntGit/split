import AppKit

/// The kinds of file the conversion wheel is arranged for. PDF has its own arrangement:
/// it turns into pictures and text, while the other documents turn into each other.
enum SourceKind: String, CaseIterable, Identifiable {
    case image, pdf, document, spreadsheet, presentation, audio, video, subtitle, archive, data

    init(_ format: Format) {
        switch format.group {
        case .image: self = .image
        case .document: self = format == .pdf ? .pdf : .document
        case .spreadsheet: self = .spreadsheet
        case .presentation: self = .presentation
        case .audio: self = .audio
        case .video: self = .video
        case .subtitle: self = .subtitle
        case .archive: self = .archive
        case .data: self = .data
        }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .image: return L("Images")
        case .pdf: return "PDF"
        case .document: return L("Documents")
        case .spreadsheet: return L("Spreadsheets")
        case .presentation: return L("Presentations")
        case .audio: return L("Audio")
        case .video: return L("Video")
        case .subtitle: return L("Subtitles")
        case .archive: return L("Archives")
        case .data: return L("Data")
        }
    }

    var formats: [Format] { Format.allCases.filter { SourceKind($0) == self } }
}

/// Each wheel keeps one arrangement, and the conversion wheel one per kind of file, since an
/// image and a spreadsheet offer different formats.
enum WheelScope: Hashable {
    case convert(SourceKind), tools, actions

    /// The arrangement used for these files; nil when the conversion wheel can't place them.
    init?(_ kind: WheelKind, for urls: [URL]) {
        switch kind {
        case .convert:
            guard let format = urls.first.flatMap(Format.detect) else { return nil }
            self = .convert(SourceKind(format))
        case .tools: self = .tools
        case .actions: self = .actions
        }
    }

    var kind: WheelKind {
        switch self {
        case .convert: return .convert
        case .tools: return .tools
        case .actions: return .actions
        }
    }

    var key: String {
        switch self {
        case .convert(let source): return "convert.\(source.rawValue)"
        case .tools: return "tools"
        case .actions: return "actions"
        }
    }

    var arrangement: WheelArrangement {
        get { Settings.wheelArrangement(key) }
        nonmutating set { Settings.setWheelArrangement(newValue, for: key) }
    }
}

/// A slice as Settings lists it, before any file is chosen, with what it does.
struct WheelChoice: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String?
    let explanation: String
}

/// The groups the wheels start with: variants of one task behind a single slice, so a wheel
/// stays short. Each one can be renamed, changed or dissolved in Settings › Wheels.
enum StandardGroup: String, CaseIterable {
    case compress = "group.compress", background = "group.background", pdf = "group.pdf", sound = "group.sound"
    /// On the video wheel: every audio format, so the video formats stay in view.
    case audio = "group.audio"

    var scope: WheelScope { self == .audio ? .convert(.video) : .tools }

    var title: String {
        switch self {
        case .compress: return L("Compress")
        case .background: return L("Background")
        case .pdf: return "PDF"
        case .sound: return L("Sound")
        case .audio: return L("Audio")
        }
    }

    /// The conversion wheel shows names only.
    var symbol: String? {
        switch self {
        case .compress: return QuickTool.compress.symbol
        case .background: return EditorTool.background.symbol
        case .pdf: return EditorTool.pdfPages.symbol
        case .sound: return "waveform"
        case .audio: return nil
        }
    }

    var members: [String] {
        switch self {
        case .compress: return [QuickTool.compress, .compressToSize, .zip].map(\.rawValue)
        case .background: return [QuickTool.removeBackground.rawValue, EditorTool.background.rawValue]
        case .pdf: return [EditorTool.pdfPages.rawValue, QuickTool.combinePDF.rawValue, QuickTool.splitPages.rawValue]
        case .sound: return [QuickTool.normalize, .mono, .trimSilence, .mute].map(\.rawValue)
        case .audio: return Format.allCases.filter { $0.group == .audio }.map(\.rawValue)
        }
    }
}

/// What each wheel offers, and in which order.
enum WheelCatalog {
    /// The slices for these files: in the user's order, without the hidden ones, and grouped.
    static func items(_ kind: WheelKind, for urls: [URL]) -> [WheelItem] {
        let offered = offered(kind, for: urls)
        guard let scope = WheelScope(kind, for: urls) else { return offered }
        return arranged(offered, scope.arrangement, defaultGroups: defaultGroups(for: scope))
    }

    /// Lays `offered` out as `arrangement` says. A group shows as one slice only when it still
    /// holds two or more (otherwise its slice stands on its own), and a wheel that would hold
    /// nothing but one group shows that group's slices straight away.
    static func arranged(_ offered: [WheelItem], _ arrangement: WheelArrangement, defaultGroups: [WheelGroup]) -> [WheelItem] {
        let byID = Dictionary(offered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let names = Dictionary((arrangement.groups ?? []).compactMap { group in group.name.map { (group.id, $0) } }, uniquingKeysWith: { first, _ in first })
        var result: [WheelItem] = []
        for entry in arrangement.entries(offered.map(\.id), defaultGroups: defaultGroups) where !arrangement.hidden.contains(entry.id) {
            guard let members = entry.members else {
                if let item = byID[entry.id] { result.append(item) }
                continue
            }
            let children = members.filter { !arrangement.hidden.contains($0) }.compactMap { byID[$0] }
            if children.count > 1 {
                result.append(WheelItem(id: entry.id, title: groupTitle(entry.id, name: names[entry.id], first: children[0].title),
                                        symbol: groupSymbol(entry.id, first: children[0].symbol),
                                        detail: children.map(\.title).joined(separator: ", "), children: children))
            } else {
                result += children
            }
        }
        if result.count == 1, result[0].isGroup { return result[0].children }
        return result
    }

    static func defaultGroups(for scope: WheelScope) -> [WheelGroup] {
        StandardGroup.allCases.filter { $0.scope == scope }.map { WheelGroup(id: $0.rawValue, members: $0.members) }
    }

    /// The user's name for a group, else the app's, else the name of its first slice.
    static func groupTitle(_ id: String, name: String?, first: String?) -> String {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        return StandardGroup(rawValue: id)?.title ?? first ?? L("New Group")
    }

    static func groupSymbol(_ id: String, first: String?) -> String? {
        guard let standard = StandardGroup(rawValue: id) else { return first }
        return standard.symbol
    }

    /// Everything that applies to these files, in the default order.
    static func offered(_ kind: WheelKind, for urls: [URL]) -> [WheelItem] {
        switch kind {
        case .convert:
            return Conversions.targets(for: urls).map { format in
                WheelItem(id: format.rawValue, title: format.label, symbol: nil, detail: L("Convert to %@", format.label)) {
                    JobRunner.shared.convert($0, to: format)
                }
            }
        case .tools:
            return ToolCatalog.items(for: urls)
        case .actions:
            return FileAction.allCases.map { action in
                WheelItem(id: action.rawValue, title: action.title, symbol: action.symbol, detail: action.detail) { action.perform($0) }
            }
        }
    }

    /// Every slice that can appear on a wheel, in the default order.
    static func choices(for scope: WheelScope) -> [WheelChoice] {
        switch scope {
        case .convert(let source):
            return merged(source.formats.map { Conversions.targets(for: $0) }).map { target in
                let from = source.formats.filter { Conversions.targets(for: $0).contains(target) }.map(\.label)
                return WheelChoice(id: target.rawValue, title: target.label, symbol: nil,
                                   explanation: target.summary + " " + L("Offered for %@.", listed(from)))
            }
        case .tools:
            return EditorTool.allCases.map { WheelChoice(id: $0.rawValue, title: $0.title, symbol: $0.symbol, explanation: $0.explanation) }
                + QuickTool.allCases.filter { $0 != .removeBackground || Tools.canRemoveBackground }
                    .map { WheelChoice(id: $0.rawValue, title: $0.title, symbol: $0.symbol, explanation: $0.explanation) }
        case .actions:
            return FileAction.allCases.map { WheelChoice(id: $0.rawValue, title: $0.title, symbol: $0.symbol, explanation: $0.explanation) }
        }
    }

    /// The kinds of file worth arranging: those that offer more than one format at a time.
    static var arrangeableKinds: [SourceKind] {
        SourceKind.allCases.filter { source in source.formats.contains { Conversions.targets(for: $0).count > 1 } }
    }

    /// One list with every item of `lists`, keeping each list's order: an item not seen yet goes
    /// right after the one it follows in its list, or first when it leads its list.
    static func merged<Item: Hashable>(_ lists: [[Item]]) -> [Item] {
        var result: [Item] = []
        for list in lists {
            for (index, item) in list.enumerated() where !result.contains(item) {
                let position = index == 0 ? 0 : (result.firstIndex(of: list[index - 1]).map { $0 + 1 } ?? result.count)
                result.insert(item, at: position)
            }
        }
        return result
    }
}
