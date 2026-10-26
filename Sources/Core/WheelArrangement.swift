import Foundation

/// How the user arranged one wheel: the order of its slices, the ones left out, and the groups
/// that gather several slices behind one. Slices are kept by identifier, so one the user never
/// placed (a format added later, or an engine installed since) still shows up: in its usual
/// group, or right after the slice it follows by default.
struct WheelArrangement: Equatable {
    /// The top level of the wheel: slices and groups.
    var order: [String] = []
    var hidden: Set<String> = []
    /// The user's groups; nil follows the app's own.
    var groups: [WheelGroup]?

    var isDefault: Bool { order.isEmpty && hidden.isEmpty && groups == nil }

    /// Every item, hidden ones included, in the chosen order. `items` come in the default order.
    func sorted<Item>(_ items: [Item], id: (Item) -> String) -> [Item] {
        guard !order.isEmpty else { return items }
        let position = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        var anchor = -1
        var offset = 0
        let keyed = items.enumerated().map { index, item -> (anchor: Int, offset: Int, index: Int, item: Item) in
            if let placed = position[id(item)] {
                anchor = placed
                offset = 0
            } else {
                offset += 1
            }
            return (anchor, offset, index, item)
        }
        return keyed.sorted { ($0.anchor, $0.offset, $0.index) < ($1.anchor, $1.offset, $1.index) }.map(\.item)
    }

    /// What the wheel shows: the chosen order, without the hidden items.
    func apply<Item>(_ items: [Item], id: (Item) -> String) -> [Item] {
        sorted(items, id: id).filter { !hidden.contains(id($0)) }
    }

    /// The wheel in order, hidden entries included: each slice, and each group with its slices
    /// in order. `ids` are the slices on offer, in the default order, and `defaultGroups` the
    /// app's groups. A group sits where its first slice would; one with nothing on offer is left out.
    func entries(_ ids: [String], defaultGroups: [WheelGroup]) -> [WheelEntry] {
        let offered = Set(ids)
        var owner: [String: String] = [:]
        var members: [String: [String]] = [:]
        for group in groups ?? defaultGroups where members[group.id] == nil {
            var list: [String] = []
            for id in group.members where offered.contains(id) && owner[id] == nil {
                owner[id] = group.id
                list.append(id)
            }
            members[group.id] = list
        }
        // A slice the user never placed joins its usual group, if the user kept that group.
        if groups != nil {
            let placed = Set(order)
            for group in defaultGroups {
                guard var list = members[group.id] else { continue }
                for (position, id) in group.members.enumerated() where offered.contains(id) && owner[id] == nil && !placed.contains(id) {
                    let before = group.members[..<position].last { list.contains($0) }
                    list.insert(id, at: before.flatMap { list.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
                    owner[id] = group.id
                }
                members[group.id] = list
            }
        }
        var skeleton: [WheelEntry] = []
        var seen: Set<String> = []
        for id in ids {
            guard let group = owner[id] else {
                skeleton.append(WheelEntry(id: id))
                continue
            }
            if seen.insert(group).inserted { skeleton.append(WheelEntry(id: group, members: members[group])) }
        }
        return sorted(skeleton, id: \.id)
    }
}

/// Slices gathered behind one slice of the wheel, which opens them as a wheel of their own.
struct WheelGroup: Codable, Equatable {
    var id: String
    /// The user's name for it; nil keeps the app's.
    var name: String?
    var members: [String]
}

/// One place on a wheel: a slice, or a group and its slices.
struct WheelEntry: Equatable, Identifiable {
    let id: String
    /// nil for a slice.
    var members: [String]?

    var isGroup: Bool { members != nil }
}
