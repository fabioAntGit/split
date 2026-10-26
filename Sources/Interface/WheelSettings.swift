import AppKit
import SwiftUI

/// Settings › Wheels: what each wheel shows and in which order, the groups that gather several
/// slices behind one, and how big the wheel is, with a preview drawn by the wheel itself.
struct WheelSettings: View {
    @State private var wheel: WheelKind = .convert
    @State private var source: SourceKind = .image
    @State private var draft = WheelDraft()
    @State private var selection: Set<String> = []
    /// The group being edited; nil lists the whole wheel.
    @State private var group: String?
    @State private var size = Settings.wheelSize
    @State private var names = Settings.wheelNames

    private var scope: WheelScope {
        switch wheel {
        case .convert: return .convert(source)
        case .tools: return .tools
        case .actions: return .actions
        }
    }

    private var choices: [WheelChoice] { WheelCatalog.choices(for: scope) }
    private var defaultGroups: [WheelGroup] { WheelCatalog.defaultGroups(for: scope) }
    private var arrangement: WheelArrangement { draft.arrangement(ids: choices.map(\.id), defaultGroups: defaultGroups) }
    private var wheelTitle: String { wheel == .convert ? source.title : wheel.title }
    private var openGroup: WheelEntry? { group.flatMap { draft.entry($0) }.flatMap { $0.isGroup ? $0 : nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Picker(L("Wheel"), selection: $wheel) {
                    ForEach(WheelKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 290)
                Spacer()
                if wheel == .convert {
                    Picker(L("Files"), selection: $source) {
                        ForEach(WheelCatalog.arrangeableKinds) { Text($0.title).tag($0) }
                    }
                    .frame(width: 210)
                }
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    if let openGroup {
                        groupEditor(openGroup)
                    } else {
                        wheelList
                    }
                }
                .frame(width: 284)
                VStack(alignment: .leading, spacing: 14) {
                    preview
                    appearance
                }
                .frame(width: 240)
            }
            Text(openGroup == nil
                 ? L("Drag the slices to change their order: the first sits at the top of the wheel and the rest follow clockwise. Unchecked slices don’t appear.")
                    + " " + L("To put several slices behind one that opens them, select them (⌘-click) and click Group.")
                 : L("These slices open from the group’s slice, in this order. A group left with one slice shows that slice on the wheel instead."))
                .font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: load)
        .onChange(of: wheel) { _ in load() }
        .onChange(of: source) { _ in load() }
    }

    // MARK: The wheel

    private var wheelList: some View {
        Group {
            List(selection: $selection) {
                ForEach(Array(draft.entries.enumerated()), id: \.element.id) { index, entry in
                    row(entry, position: index + 1)
                        .tag(entry.id)
                        .contextMenu { menu(for: entry) }
                }
                .onMove { offsets, destination in
                    draft.moveEntries(from: offsets, to: destination)
                    save()
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            HStack {
                Button(L("Group")) { makeGroup(of: chosenSlices) }
                    .disabled(chosenSlices.count < 2)
                Spacer()
                Button(L("Restore Defaults")) {
                    draft = WheelDraft(WheelArrangement(), ids: choices.map(\.id), defaultGroups: defaultGroups)
                    selection = []
                    save()
                }
                .disabled(arrangement.isDefault)
            }
        }
    }

    private func row(_ entry: WheelEntry, position: Int) -> some View {
        guard let members = entry.members else {
            let choice = choice(entry.id)
            return SliceRow(title: choice?.title ?? entry.id, symbol: choice?.symbol, position: position, shown: shown(entry.id),
                            move: { move(entry.id, $0) })
        }
        let titles = members.compactMap { choice($0)?.title }
        return SliceRow(title: title(of: entry), symbol: symbol(of: entry) ?? "square.stack", detail: titles.joined(separator: ", "),
                        position: position, shown: shown(entry.id), move: { move(entry.id, $0) },
                        open: { open(entry.id) })
    }

    @ViewBuilder
    private func menu(for entry: WheelEntry) -> some View {
        if entry.isGroup {
            Button(L("Open Group")) { open(entry.id) }
            Button(L("Ungroup")) {
                draft.ungroup(entry.id)
                save()
            }
            Divider()
        } else {
            let slices = selection.contains(entry.id) && chosenSlices.count > 1 ? chosenSlices : [entry.id]
            Button(L("New Group")) { makeGroup(of: slices) }
            let groups = draft.entries.filter(\.isGroup)
            if !groups.isEmpty {
                Menu(L("Add to Group")) {
                    ForEach(groups) { group in
                        Button(title(of: group)) {
                            slices.forEach { draft.add($0, to: group.id) }
                            selection = []
                            save()
                        }
                    }
                }
            }
            Divider()
        }
        moveButtons(entry.id)
    }

    // MARK: A group

    private func groupEditor(_ entry: WheelEntry) -> some View {
        let members = entry.members ?? []
        let loose = draft.entries.filter { !$0.isGroup }
        return Group {
            Button {
                close()
            } label: {
                Label(wheelTitle, systemImage: "chevron.backward")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L("Back to %@", wheelTitle))
            TextField(L("Group name"), text: name(of: entry), prompt: Text(WheelCatalog.groupTitle(entry.id, name: nil, first: members.first.flatMap { choice($0)?.title })))
                .textFieldStyle(.roundedBorder)
            List(selection: $selection) {
                ForEach(Array(members.enumerated()), id: \.element) { index, id in
                    SliceRow(title: choice(id)?.title ?? id, symbol: choice(id)?.symbol, position: index + 1, shown: shown(id),
                             move: { move(id, $0) })
                        .tag(id)
                        .contextMenu {
                            Button(L("Remove from Group")) { takeOut(id, from: entry.id) }
                            Divider()
                            moveButtons(id)
                        }
                }
                .onMove { offsets, destination in
                    draft.moveMembers(of: entry.id, from: offsets, to: destination)
                    save()
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            HStack {
                Menu(L("Add Slice")) {
                    ForEach(loose) { slice in
                        Button(choice(slice.id)?.title ?? slice.id) {
                            draft.add(slice.id, to: entry.id)
                            save()
                        }
                    }
                }
                .disabled(loose.isEmpty)
                .fixedSize()
                Button(L("Remove from Group")) {
                    for id in members where selection.contains(id) { takeOut(id, from: entry.id) }
                }
                .disabled(!members.contains { selection.contains($0) })
                Spacer()
                Button(L("Ungroup")) {
                    draft.ungroup(entry.id)
                    close()
                    save()
                }
            }
        }
    }

    // MARK: Preview and look

    private var preview: some View {
        let style = WheelStyle(size: size, names: names)
        let offered = choices.map { WheelItem(id: $0.id, title: $0.title, symbol: $0.symbol) }
        var items = WheelCatalog.arranged(offered, arrangement, defaultGroups: defaultGroups)
        var title = wheel.title
        var back: String?
        if let openGroup {
            items = (openGroup.members ?? []).filter { !draft.hidden.contains($0) }.compactMap { id in offered.first { $0.id == id } }
            title = self.title(of: openGroup)
            back = wheel.title
        }
        let highlighted = selection.count == 1 ? items.firstIndex { selection.contains($0.id) } : nil
        let side = 240 * WheelLayout.windowSize(size) / WheelLayout.windowSize(.extraLarge)
        return VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.32), Color(white: 0.16)], startPoint: .topLeading, endPoint: .bottomTrailing))
                if let image = WheelView.picture(items: items, title: title, subtitle: wheel == .convert ? source.title : "",
                                                 highlighted: highlighted, style: style, back: back) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: side, height: side)
                        .animation(Motion.standard, value: size)
                }
            }
            .frame(width: 240, height: 240)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            .accessibilityElement()
            .accessibilityLabel(L("Preview of the wheel"))
            .accessibilityValue(items.map(\.title).joined(separator: ", "))
            Text(L("A file shows only the slices that apply to it."))
                .font(.system(size: 11)).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("Size"))
                Spacer()
                Text(size.label).foregroundColor(.secondary)
            }
            Slider(value: Binding(get: { Double(size.rawValue) }, set: { value in
                let chosen = WheelSize(rawValue: Int(value.rounded())) ?? .medium
                guard chosen != size else { return }
                size = chosen
                Settings.wheelSize = chosen
            }), in: 0...Double(WheelSize.allCases.count - 1), step: 1) {
                Text(L("Size"))
            } minimumValueLabel: {
                Image(systemName: "circle").font(.system(size: 9)).accessibilityHidden(true)
            } maximumValueLabel: {
                Image(systemName: "circle").font(.system(size: 15)).accessibilityHidden(true)
            }
            .labelsHidden()
            .accessibilityLabel(L("Size"))
            .accessibilityValue(size.label)
            Toggle(L("Names under icons"), isOn: Binding(get: { names }, set: { show in
                names = show
                Settings.wheelNames = show
            }))
            Text(L("A name too long for its slice ends in “…”; the centre shows it whole."))
                .font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Changes

    private func load() {
        draft = WheelDraft(scope.arrangement, ids: choices.map(\.id), defaultGroups: defaultGroups)
        selection = []
        group = nil
    }

    /// Whatever matches the app's defaults is saved as nothing, so it keeps following them.
    private func save() {
        scope.arrangement = arrangement
    }

    /// The selected slices that aren't in a group, in wheel order.
    private var chosenSlices: [String] {
        draft.entries.filter { !$0.isGroup && selection.contains($0.id) }.map(\.id)
    }

    private func makeGroup(of slices: [String]) {
        guard let id = draft.makeGroup(of: slices) else { return }
        save()
        open(id)
    }

    private func takeOut(_ id: String, from group: String) {
        draft.takeOut(id)
        selection.remove(id)
        if draft.entry(group) == nil { close() }
        save()
    }

    private func open(_ id: String) {
        withAnimation(Motion.standard) { group = id }
        selection = []
    }

    private func close() {
        let left = group
        withAnimation(Motion.standard) { group = nil }
        selection = left.map { [$0] } ?? []
    }

    private func move(_ id: String, _ move: WheelDraft.Move) {
        withAnimation(Motion.standard) { draft.move(id, move) }
        selection = [id]
        save()
    }

    @ViewBuilder
    private func moveButtons(_ id: String) -> some View {
        Button(L("Move to Top")) { move(id, .top) }
        Button(L("Move Up")) { move(id, .up) }
        Button(L("Move Down")) { move(id, .down) }
        Button(L("Move to Bottom")) { move(id, .bottom) }
    }

    // MARK: Lookups

    private func choice(_ id: String) -> WheelChoice? { choices.first { $0.id == id } }

    private func title(of entry: WheelEntry) -> String {
        WheelCatalog.groupTitle(entry.id, name: draft.names[entry.id], first: entry.members?.first.flatMap { choice($0)?.title })
    }

    private func symbol(of entry: WheelEntry) -> String? {
        WheelCatalog.groupSymbol(entry.id, first: entry.members?.first.flatMap { choice($0)?.symbol })
    }

    private func shown(_ id: String) -> Binding<Bool> {
        Binding(get: { !draft.hidden.contains(id) }, set: { show in
            if show { draft.hidden.remove(id) } else { draft.hidden.insert(id) }
            save()
        })
    }

    private func name(of entry: WheelEntry) -> Binding<String> {
        Binding(get: { draft.names[entry.id] ?? "" }, set: { name in
            draft.names[entry.id] = name
            save()
        })
    }
}

/// One slice or group in the list: whether it shows, where it sits, and ways to move it without
/// dragging. A group lists its slices and opens with the chevron.
private struct SliceRow: View {
    let title: String
    let symbol: String?
    var detail: String?
    let position: Int
    @Binding var shown: Bool
    let move: (WheelDraft.Move) -> Void
    var open: (() -> Void)?

    init(title: String, symbol: String?, detail: String? = nil, position: Int, shown: Binding<Bool>,
         move: @escaping (WheelDraft.Move) -> Void, open: (() -> Void)? = nil) {
        self.title = title
        self.symbol = symbol
        self.detail = detail
        self.position = position
        _shown = shown
        self.move = move
        self.open = open
    }

    var body: some View {
        HStack(spacing: 8) {
            Toggle(title, isOn: $shown)
                .toggleStyle(.checkbox)
                .labelsHidden()
            if let symbol {
                Image(systemName: symbol).frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundColor(shown ? .primary : .secondary)
                if let detail {
                    Text(detail).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 4)
            Text("\(position)").font(.system(size: 11).monospacedDigit()).foregroundColor(.secondary)
            if let open {
                Button(action: open) {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .help(L("Open Group"))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: L("Move Up")) { move(.up) }
        .accessibilityAction(named: L("Move Down")) { move(.down) }
        .modifier(OpenAction(open: open))
    }
}

private struct OpenAction: ViewModifier {
    let open: (() -> Void)?

    func body(content: Content) -> some View {
        if let open {
            content.accessibilityAction(named: L("Open Group"), open)
        } else {
            content
        }
    }
}
