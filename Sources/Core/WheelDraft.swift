import Foundation

/// One wheel as Settings › Wheels edits it: what sits on the wheel, what each group holds and
/// what is left out. It turns back into the arrangement that is saved.
struct WheelDraft: Equatable {
    enum Move { case top, up, down, bottom }

    /// The top level, in order; a group carries its slices in order.
    var entries: [WheelEntry] = []
    var hidden: Set<String> = []
    /// The user's names for groups, as typed.
    var names: [String: String] = [:]

    init() {}

    init(_ arrangement: WheelArrangement, ids: [String], defaultGroups: [WheelGroup]) {
        entries = arrangement.entries(ids, defaultGroups: defaultGroups)
        hidden = arrangement.hidden
        for group in arrangement.groups ?? [] { names[group.id] = group.name }
    }

    /// What is saved. Whatever matches the app's defaults is saved as nothing, so the wheel keeps
    /// following them, also when the app adds slices or groups later.
    func arrangement(ids: [String], defaultGroups: [WheelGroup]) -> WheelArrangement {
        let standard = WheelArrangement().entries(ids, defaultGroups: defaultGroups)
        let groups = entries.compactMap { entry in
            entry.members.map { WheelGroup(id: entry.id, name: WheelDraft.cleaned(names[entry.id]), members: $0) }
        }
        let standardGroups = standard.compactMap { entry in entry.members.map { WheelGroup(id: entry.id, name: nil, members: $0) } }
        let custom = groups.sorted { $0.id < $1.id } != standardGroups.sorted { $0.id < $1.id }
        let order = entries.map(\.id)
        return WheelArrangement(order: !custom && order == standard.map(\.id) ? [] : order, hidden: hidden, groups: custom ? groups : nil)
    }

    func entry(_ id: String) -> WheelEntry? { entries.first { $0.id == id } }

    /// The group a slice is in, if any.
    func group(of id: String) -> String? { entries.first { $0.members?.contains(id) == true }?.id }

    // MARK: Order

    mutating func moveEntries(from offsets: IndexSet, to destination: Int) {
        entries = WheelDraft.moved(entries, from: offsets, to: destination)
    }

    mutating func moveMembers(of group: String, from offsets: IndexSet, to destination: Int) {
        guard let index = entries.firstIndex(where: { $0.id == group }), let members = entries[index].members else { return }
        entries[index].members = WheelDraft.moved(members, from: offsets, to: destination)
    }

    /// One step, or to an end, within the list the slice or group is in.
    mutating func move(_ id: String, _ move: Move) {
        if let group = group(of: id), let index = entries.firstIndex(where: { $0.id == group }), let members = entries[index].members,
           let from = members.firstIndex(of: id) {
            entries[index].members = WheelDraft.moved(members, from: IndexSet(integer: from), to: WheelDraft.destination(from, move, count: members.count))
        } else if let from = entries.firstIndex(where: { $0.id == id }) {
            moveEntries(from: IndexSet(integer: from), to: WheelDraft.destination(from, move, count: entries.count))
        }
    }

    /// Puts a slice or group right before `neighbour` in the list it is in (the top level, or
    /// its group), or last without one. A wheel shows only what isn't hidden, so a drop on it
    /// is said by the slice that is to follow, and hidden ones keep their places.
    mutating func place(_ id: String, before neighbour: String?) {
        guard id != neighbour else { return }
        if let group = group(of: id), let index = entries.firstIndex(where: { $0.id == group }), var members = entries[index].members {
            members.removeAll { $0 == id }
            members.insert(id, at: neighbour.flatMap { members.firstIndex(of: $0) } ?? members.count)
            entries[index].members = members
        } else if let from = entries.firstIndex(where: { $0.id == id }) {
            let entry = entries.remove(at: from)
            entries.insert(entry, at: neighbour.flatMap { next in entries.firstIndex { $0.id == next } } ?? entries.count)
        }
    }

    // MARK: Groups

    /// Puts top-level slices in a new group, where the first of them was, and returns its identifier.
    @discardableResult
    mutating func makeGroup(of ids: [String], name: String? = nil) -> String? {
        let chosen = entries.filter { !$0.isGroup && ids.contains($0.id) }.map(\.id)
        guard let first = chosen.first, let at = entries.firstIndex(where: { $0.id == first }) else { return nil }
        let used = Set(entries.map(\.id))
        let id = (1...).lazy.map { "group.\($0)" }.first { !used.contains($0) }!
        let position = entries[..<at].filter { !chosen.contains($0.id) }.count
        entries.removeAll { !$0.isGroup && chosen.contains($0.id) }
        entries.insert(WheelEntry(id: id, members: chosen), at: position)
        names[id] = name
        return id
    }

    /// Moves a top-level slice to the end of a group.
    mutating func add(_ id: String, to group: String) {
        guard let from = entries.firstIndex(where: { $0.id == id && !$0.isGroup }), entry(group)?.isGroup == true else { return }
        entries.remove(at: from)
        if let index = entries.firstIndex(where: { $0.id == group }) { entries[index].members?.append(id) }
    }

    /// Takes a slice out of its group and puts it right after the group. A group left empty goes away.
    mutating func takeOut(_ id: String) {
        guard let group = group(of: id), let index = entries.firstIndex(where: { $0.id == group }) else { return }
        entries[index].members?.removeAll { $0 == id }
        entries.insert(WheelEntry(id: id), at: index + 1)
        if entries[index].members?.isEmpty == true { forget(group, at: index) }
    }

    /// Dissolves a group: its slices take its place.
    mutating func ungroup(_ group: String) {
        guard let index = entries.firstIndex(where: { $0.id == group }), let members = entries[index].members else { return }
        forget(group, at: index)
        entries.insert(contentsOf: members.map { WheelEntry(id: $0) }, at: index)
    }

    private mutating func forget(_ group: String, at index: Int) {
        entries.remove(at: index)
        names[group] = nil
        hidden.remove(group)
    }

    // MARK: Helpers

    private static func cleaned(_ name: String?) -> String? {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func destination(_ from: Int, _ move: Move, count: Int) -> Int {
        switch move {
        case .top: return 0
        case .up: return max(from - 1, 0)
        case .down: return min(from + 2, count)
        case .bottom: return count
        }
    }

    /// Like moving rows in a list: `destination` counts the items before the move.
    private static func moved<Item>(_ list: [Item], from offsets: IndexSet, to destination: Int) -> [Item] {
        let moving = offsets.map { list[$0] }
        var rest = list.indices.filter { !offsets.contains($0) }.map { list[$0] }
        rest.insert(contentsOf: moving, at: destination - offsets.filter { $0 < destination }.count)
        return rest
    }
}
