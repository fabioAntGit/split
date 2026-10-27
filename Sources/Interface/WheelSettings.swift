import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Wheels: what each wheel shows, where each slice sits (dragged on a live preview of
/// the wheel, or from the list onto it), the groups that gather several slices behind one, what
/// each slice does, and how the wheel and the windows look.
struct WheelSettings: View {
    @ObservedObject private var look = LookStore.shared
    @State private var wheel: WheelKind = .convert
    @State private var source: SourceKind = .image
    @State private var draft = WheelDraft()
    @State private var selection: Set<String> = []
    /// The group being edited; nil lists the whole wheel.
    @State private var group: String?
    @State private var size = Settings.wheelSize
    @State private var names = Settings.wheelNames
    /// A slice being dragged on the preview, and the place it would take.
    @State private var drag: PreviewDrag?
    /// A row of the list being dragged, by its slice or group.
    @State private var listDrag: String?

    /// The preview's square, and the size of the wheel in it: always the same, since it is there
    /// to arrange the slices, whatever size the wheel opens at.
    static let previewSide: CGFloat = 330
    private static let previewSize = WheelSize.extraLarge
    private var scale: CGFloat { WheelSettings.previewSide / WheelLayout.windowSize(WheelSettings.previewSize) }

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
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    if let openGroup {
                        groupEditor(openGroup)
                    } else {
                        wheelList
                    }
                    Divider().padding(.vertical, 2)
                    appearance
                }
                .frame(width: 300)
                VStack(alignment: .leading, spacing: 12) {
                    preview
                    about
                }
                .frame(width: WheelSettings.previewSide)
            }
            Text(openGroup == nil
                 ? L("Drag the slices on the wheel, or rows from the list onto it, to put them where you want them. Unchecked slices don’t appear.")
                    + " " + L("To put several slices behind one that opens them, select them (⌘-click) and click Group.")
                 : L("These slices open from the group’s slice: drag them on the wheel, or from the list onto it, to change their order. A group left with one slice shows that slice on the wheel instead."))
                .font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: load)
        .onChange(of: wheel) { _ in load() }
        .onChange(of: source) { _ in load() }
    }

    // MARK: The list: what shows, and groups

    private var wheelList: some View {
        Group {
            List(selection: $selection) {
                ForEach(draft.entries) { entry in
                    row(entry)
                        .tag(entry.id)
                        .contextMenu { menu(for: entry) }
                        .onDrag { dragFromList(entry.id) }
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

    private func row(_ entry: WheelEntry) -> some View {
        guard let members = entry.members else {
            let choice = choice(entry.id)
            return SliceRow(title: choice?.title ?? entry.id, symbol: choice?.symbol, shown: shown(entry.id), move: { move(entry.id, $0) })
        }
        let titles = members.compactMap { choice($0)?.title }
        return SliceRow(title: title(of: entry), symbol: symbol(of: entry) ?? "square.stack", detail: titles.joined(separator: ", "),
                        shown: shown(entry.id), move: { move(entry.id, $0) }, open: { open(entry.id) })
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
                ForEach(members, id: \.self) { id in
                    SliceRow(title: choice(id)?.title ?? id, symbol: choice(id)?.symbol, shown: shown(id), move: { move(id, $0) })
                        .tag(id)
                        .contextMenu {
                            Button(L("Remove from Group")) { takeOut(id, from: entry.id) }
                            Divider()
                            moveButtons(id)
                        }
                        .onDrag { dragFromList(id) }
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

    // MARK: The wheel, live

    /// What the preview shows: the wheel as it opens, or the open group, and the slice or group
    /// of the draft each of its slices stands for.
    private struct Shown {
        var items: [WheelItem]
        var title: String
        var back: String?
        var owner: (String) -> String
    }

    /// `revealed` is an unchecked slice or group shown anyway, while its row is dragged over the wheel.
    private func shown(revealing revealed: String? = nil) -> Shown {
        var draft = self.draft
        if let revealed { draft.hidden.remove(revealed) }
        let offered = choices.map { WheelItem(id: $0.id, title: $0.title, symbol: $0.symbol) }
        if let openGroup {
            let items = (openGroup.members ?? []).filter { !draft.hidden.contains($0) }.compactMap { id in offered.first { $0.id == id } }
            return Shown(items: items, title: title(of: openGroup), back: wheel.title, owner: { $0 })
        }
        let arrangement = draft.arrangement(ids: choices.map(\.id), defaultGroups: defaultGroups)
        let items = WheelCatalog.arranged(offered, arrangement, defaultGroups: defaultGroups)
        // A group left with one slice shows that slice in its place, so the slice moves the group.
        let saved = draft
        let owner: (String) -> String = { id in saved.entry(id) == nil ? saved.group(of: id) ?? id : id }
        // A wheel holding a single group shows that group's slices: they move inside it.
        let single = items.count > 1 && Set(items.map { owner($0.id) }).count == 1
        return Shown(items: items, title: wheel.title, back: nil, owner: single ? { $0 } : owner)
    }

    private var preview: some View {
        let shown = self.shown(revealing: drag?.revealed)
        var items = shown.items
        var highlighted = selection.count == 1 ? items.firstIndex { selection.contains($0.id) } : nil
        if let drag, let from = items.firstIndex(where: { $0.id == drag.id }) {
            items.insert(items.remove(at: from), at: drag.to)
            highlighted = drag.to
        }
        let side = WheelSettings.previewSide
        let size = WheelSettings.previewSize
        let disc = (WheelLayout.outerRadius(size) + WheelLayout.rimMargin) * 2 * scale
        let picture = WheelView.picture(items: items, title: shown.title, subtitle: wheel == .convert ? source.title : "",
                                        highlighted: highlighted, style: WheelStyle(size: size, names: names), back: shown.back, backdrop: false)
        return ZStack {
            DesktopBehind()
                .frame(width: side, height: side)
                .clipped()
            LiveBackdrop(glass: look.glassWheel && !Motion.reduceTransparency, color: look.color, intensity: look.glassIntensity)
                .frame(width: disc, height: disc)
            if let picture {
                Image(nsImage: picture)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: WheelLayout.windowSize(size) * scale, height: WheelLayout.windowSize(size) * scale)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .contentShape(Rectangle())
        .gesture(dragging(shown))
        .onDrop(of: [.plainText], delegate: ListDrop(active: listDrag != nil, hover: { location in
            let next = listDrag.flatMap { landing($0, at: location) }
            if let next, next != drag { Haptics.snap() }
            drag = next
        }, leave: {
            drag = nil
        }, land: { id, location in
            drag = nil
            defer { listDrag = nil }
            guard let id, id == listDrag, let landing = landing(id, at: location) else { return }
            drop(landing, self.shown(revealing: landing.revealed))
        }))
        .onContinuousHover { phase in
            guard drag == nil else { return }
            if case .active(let location) = phase, slice(at: location, of: shown) != nil {
                NSCursor.openHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .accessibilityElement()
        .accessibilityLabel(L("Preview of the wheel"))
        .accessibilityValue(shown.items.map(\.title).joined(separator: ", "))
    }

    /// A press that moves becomes a drag of the slice under it, following the pointer slice by
    /// slice; one that doesn't is a click, which chooses the slice or opens the group as the
    /// wheel would (the centre of an open group goes back).
    private func dragging(_ shown: Shown) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if drag == nil {
                    guard hypot(value.translation.width, value.translation.height) > 4,
                          let start = slice(at: value.startLocation, of: shown) else { return }
                    drag = PreviewDrag(id: shown.items[start].id, to: start)
                    NSCursor.closedHand.set()
                }
                if let to = slice(at: value.location, of: shown), to != drag?.to {
                    drag?.to = to
                    Haptics.snap()
                }
            }
            .onEnded { value in
                guard let drag else { return click(at: value.location, shown) }
                self.drag = nil
                drop(drag, shown)
                NSCursor.openHand.set()
            }
    }

    private func offset(_ location: CGPoint) -> CGPoint {
        let middle = WheelSettings.previewSide / 2
        return CGPoint(x: (location.x - middle) / scale, y: (middle - location.y) / scale)
    }

    private func slice(at location: CGPoint, of shown: Shown) -> Int? {
        WheelLayout.slice(at: offset(location), count: shown.items.count, size: WheelSettings.previewSize)
    }

    /// A row taken from the list, to be dropped on the wheel.
    private func dragFromList(_ id: String) -> NSItemProvider {
        listDrag = id
        return NSItemProvider(object: id as NSString)
    }

    /// Where a row of the list would land on the wheel: the slice under the pointer. An unchecked
    /// slice or group shows on the wheel while it is over it, and stays there once dropped.
    private func landing(_ id: String, at location: CGPoint) -> PreviewDrag? {
        let revealed = draft.hidden.contains(id) ? id : nil
        let shown = self.shown(revealing: revealed)
        guard let item = shown.items.first(where: { shown.owner($0.id) == id }),
              let to = slice(at: location, of: shown) else { return nil }
        return PreviewDrag(id: item.id, to: to, revealed: revealed)
    }

    private func drop(_ drag: PreviewDrag, _ shown: Shown) {
        var order = shown.items.map(\.id)
        selection = [drag.id]
        guard let from = order.firstIndex(of: drag.id), from != drag.to || drag.revealed != nil else { return }
        if let revealed = drag.revealed { draft.hidden.remove(revealed) }
        order.insert(order.remove(at: from), at: drag.to)
        let next = drag.to + 1 < order.count ? order[drag.to + 1] : nil
        draft.place(shown.owner(drag.id), before: next.map(shown.owner))
        save()
        Haptics.commit()
    }

    private func click(at location: CGPoint, _ shown: Shown) {
        if let index = slice(at: location, of: shown) {
            let item = shown.items[index]
            if item.isGroup { open(item.id) } else { selection = [item.id] }
        } else if group != nil, WheelLayout.isOnHub(offset(location), size: WheelSettings.previewSize) {
            close()
        }
    }

    // MARK: What the chosen slice does

    /// The chosen slice or group; with a group open and nothing chosen, the group.
    private var focused: String? { selection.count == 1 ? selection.first : group }

    @ViewBuilder
    private var about: some View {
        if let id = focused, let entry = draft.entry(id), let members = entry.members {
            AboutCard(title: title(of: entry), symbol: symbol(of: entry) ?? "square.stack",
                      text: L("Opens a wheel of its own with: %@.", listed(members.compactMap { choice($0)?.title })),
                      shown: shown(id), open: group == id ? nil : { open(id) })
        } else if let id = focused, let choice = choice(id) {
            AboutCard(title: choice.title, symbol: choice.symbol, text: choice.explanation, shown: shown(id))
        } else {
            Text(L("Click a slice to see what it does. A file shows only the slices that apply to it."))
                .font(.system(size: 12)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        }
    }

    // MARK: Look

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
            Picker(L("Color"), selection: $look.color) {
                ForEach(LookColor.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle(L("Glass background"), isOn: $look.glassWheel)
            HStack(spacing: 8) {
                Text(L("Intensity"))
                Slider(value: $look.glassIntensity, in: 0...1) {
                    Text(L("Intensity"))
                }
                .labelsHidden()
            }
            .disabled(!look.glassWheel || Motion.reduceTransparency)
            Text(L("Black or white for the wheel, the editors and every window. With glass, the desktop shows through the wheel and the editors, tinted with that colour as strongly as the intensity says; with “Reduce transparency” on in the Accessibility settings, they stay solid."))
                .font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Changes

    private func load() {
        draft = WheelDraft(scope.arrangement, ids: choices.map(\.id), defaultGroups: defaultGroups)
        selection = []
        group = nil
        drag = nil
        listDrag = nil
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

private struct PreviewDrag: Equatable {
    let id: String
    var to: Int
    /// An unchecked slice or group dragged in from the list, shown while it is over the wheel.
    var revealed: String?
}

/// A row of the list dropped on the preview. Its id comes back as text, and only a row still
/// being dragged from the list counts.
private struct ListDrop: DropDelegate {
    let active: Bool
    let hover: (CGPoint) -> Void
    let leave: () -> Void
    let land: (String?, CGPoint) -> Void

    func validateDrop(info: DropInfo) -> Bool { active && info.hasItemsConforming(to: [.plainText]) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        hover(info.location)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { leave() }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        let location = info.location
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            let id = (object as? NSString).map { $0 as String }
            DispatchQueue.main.async { land(id, location) }
        }
        return true
    }
}

/// One slice or group in the list: whether it shows, and ways to move it without dragging. A
/// group lists its slices and opens with the chevron.
private struct SliceRow: View {
    let title: String
    let symbol: String?
    var detail: String?
    @Binding var shown: Bool
    let move: (WheelDraft.Move) -> Void
    var open: (() -> Void)?

    init(title: String, symbol: String?, detail: String? = nil, shown: Binding<Bool>,
         move: @escaping (WheelDraft.Move) -> Void, open: (() -> Void)? = nil) {
        self.title = title
        self.symbol = symbol
        self.detail = detail
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

/// What one slice or group does, with the switch that takes it off the wheel.
private struct AboutCard: View {
    let title: String
    let symbol: String?
    let text: String
    @Binding var shown: Bool
    var open: (() -> Void)?

    init(title: String, symbol: String?, text: String, shown: Binding<Bool>, open: (() -> Void)? = nil) {
        self.title = title
        self.symbol = symbol
        self.text = text
        _shown = shown
        self.open = open
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 17))
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.08)))
                        .accessibilityHidden(true)
                }
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            Text(text)
                .font(.system(size: 12)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Toggle(L("Show on the wheel"), isOn: $shown)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Spacer()
                if let open {
                    Button(L("Open Group"), action: open)
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        .accessibilityElement(children: .contain)
    }
}

/// The wheel's own backdrop, live: glass takes on what is behind it, which no picture can capture.
private struct LiveBackdrop: NSViewRepresentable {
    let glass: Bool
    let color: LookColor
    let intensity: Double

    func makeNSView(context: Context) -> BackdropHost { BackdropHost() }

    func updateNSView(_ host: BackdropHost, context: Context) {
        host.look = (glass, color)
        host.intensity = intensity
    }
}

/// Builds the backdrop again when glass or the colour changes; a new intensity only tints it.
private final class BackdropHost: NSView {
    var look: (glass: Bool, color: LookColor)? {
        didSet { needsLayout = true }
    }
    var intensity: Double? {
        didSet { if intensity != oldValue { subviews.first.map(WheelBackdrop.tint) } }
    }
    private var built: (glass: Bool, color: LookColor, side: CGFloat)?

    override func layout() {
        super.layout()
        guard let look, bounds.width > 0,
              built?.glass != look.glass || built?.color != look.color || built?.side != bounds.width else { return }
        subviews.forEach { $0.removeFromSuperview() }
        addSubview(WheelBackdrop.make(frame: bounds, glass: look.glass))
        built = (look.glass, look.color, bounds.width)
    }
}

/// The desktop picture behind the preview, so the wheel is seen over what it will really
/// cover; a plain gradient when there's none to read.
private struct DesktopBehind: View {
    var body: some View {
        if let picture = DesktopPicture.image {
            Image(nsImage: picture)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            LinearGradient(colors: [Color(white: 0.42), Color(white: 0.2)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

enum DesktopPicture {
    /// Read once, small. A picture kept in a protected folder isn't read, so opening Settings
    /// never asks for permission.
    private static let thumbnail: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 900,
    ]

    static let image: NSImage? = {
        guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen), url.isFileURL else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let protected = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents"].map { "\(home)/\($0)/" }
        guard !protected.contains(where: url.path.hasPrefix),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnail as CFDictionary) else { return nil }
        return NSImage(cgImage: picture, size: .zero)
    }()
}
