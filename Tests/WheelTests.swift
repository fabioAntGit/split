import AppKit

/// The user's arrangement of the wheels: order, hidden slices and what Settings lists.
func registerWheelTests() {
    test("Wheels", "An arrangement moves and hides slices; one never placed sits after its neighbour") {
        check(WheelArrangement().sorted(["a", "b", "c"], id: { $0 }) == ["a", "b", "c"], "no arrangement keeps the default order")
        check(WheelArrangement(order: ["c", "a", "b"]).sorted(["a", "b", "c", "d"], id: { $0 }) == ["c", "d", "a", "b"],
              "“d” follows “c” by default, so it stays right after it")
        check(WheelArrangement(order: ["b", "a"]).sorted(["x", "a", "y", "b", "z"], id: { $0 }) == ["x", "b", "z", "a", "y"],
              "items never placed keep their default neighbours")
        check(WheelArrangement(order: ["gone", "b", "a"]).sorted(["a", "b"], id: { $0 }) == ["b", "a"], "slices that no longer exist are ignored")
        check(WheelArrangement(order: ["b", "a"], hidden: ["a"]).apply(["a", "b", "c"], id: { $0 }) == ["b", "c"], "hidden slices are left out")
    }

    test("Wheels", "Without an arrangement every wheel keeps its default order, with the app's groups") {
        func flat(_ items: [WheelItem]) -> [String] { items.flatMap { $0.isGroup ? $0.children : [$0] }.map(\.id) }
        try withoutArrangements {
            for format in Format.allCases {
                let url = URL(fileURLWithPath: "/tmp/sample.\(format.ext)")
                let items = WheelCatalog.items(.convert, for: [url])
                let targets = Conversions.targets(for: format).map(\.rawValue)
                check(Set(flat(items)) == Set(targets) && flat(items).count == targets.count, "\(format.label): slices went missing or doubled")
                check(flat(items).filter { !$0.hasPrefix("group.") } == targets.filter(flat(items).contains), "\(format.label): the wheel changed order")
                if format.group == .video {
                    let audio = items.first { $0.id == StandardGroup.audio.rawValue }
                    check(audio?.children.count ?? 0 > 1 && items.count < targets.count, "\(format.label): the audio formats should sit behind one slice")
                } else {
                    check(!items.contains(where: \.isGroup), "\(format.label): only the video wheel groups formats")
                }
            }
            check(WheelCatalog.items(.actions, for: [Fixtures.url("photo.jpg")]).map(\.id) == FileAction.allCases.map(\.rawValue), "actions changed order")
            let photo = [Fixtures.url("photo.jpg")]
            let tools = WheelCatalog.items(.tools, for: photo)
            let offered = ToolCatalog.items(for: photo).map(\.id)
            check(Set(flat(tools)) == Set(offered), "tools went missing: \(Set(offered).subtracting(flat(tools)).sorted())")
            check(tools.count < offered.count, "grouping should make the tools wheel shorter")
            let compress = tools.first { $0.id == StandardGroup.compress.rawValue }
            check(compress?.children.map(\.id) == ["compress", "compress-to", "zip"], "compressing sits behind one slice: \(compress?.children.map(\.id) ?? [])")
            check(compress?.title == L("Compress") && compress?.detail?.contains(QuickTool.zip.title) == true, "the group is named and lists its slices")
        }
    }

    test("Wheels", "A group shows as one slice only with two or more slices; a lone group opens straight away") {
        let items = ["a", "b", "c", "d"].map { WheelItem(id: $0, title: $0.uppercased(), symbol: nil) }
        let groups = [WheelGroup(id: "g", members: ["b", "c"])]
        let grouped = WheelCatalog.arranged(items, WheelArrangement(), defaultGroups: groups)
        check(grouped.map(\.id) == ["a", "g", "d"] && grouped[1].children.map(\.id) == ["b", "c"], "b and c sit behind g: \(grouped.map(\.id))")
        check(grouped[1].title == "B", "a group with no name of its own takes its first slice's name")
        let one = WheelCatalog.arranged(items, WheelArrangement(hidden: ["c"]), defaultGroups: groups)
        check(one.map(\.id) == ["a", "b", "d"], "a group left with one slice shows that slice: \(one.map(\.id))")
        let gone = WheelCatalog.arranged(items, WheelArrangement(hidden: ["g"]), defaultGroups: groups)
        check(gone.map(\.id) == ["a", "d"], "hiding a group hides its slices: \(gone.map(\.id))")
        let lone = WheelCatalog.arranged(Array(items[1...2]), WheelArrangement(), defaultGroups: groups)
        check(lone.map(\.id) == ["b", "c"], "a wheel with nothing but one group shows its slices: \(lone.map(\.id))")
        let named = WheelCatalog.arranged(items, WheelArrangement(groups: [WheelGroup(id: "g", name: "Mine", members: ["c", "b"])]), defaultGroups: groups)
        check(named[1].title == "Mine" && named[1].children.map(\.id) == ["c", "b"], "the user's name and order win")
    }

    test("Wheels", "Arrangement entries: groups sit where their first slice would, new slices join their usual group") {
        let groups = [WheelGroup(id: "g", members: ["b", "c", "x"])]
        let entries = WheelArrangement().entries(["a", "b", "c", "d"], defaultGroups: groups)
        check(entries == [WheelEntry(id: "a"), WheelEntry(id: "g", members: ["b", "c"]), WheelEntry(id: "d")], "\(entries)")
        check(WheelArrangement().entries(["a", "d"], defaultGroups: groups).map(\.id) == ["a", "d"], "a group with nothing on offer is left out")
        // The user kept g with only c in it, before "b" existed: b joins g, before c as in the app's order.
        let saved = WheelArrangement(order: ["d", "g", "a"], groups: [WheelGroup(id: "g", members: ["c"])])
        let later = saved.entries(["a", "b", "c", "d"], defaultGroups: groups)
        check(later == [WheelEntry(id: "d"), WheelEntry(id: "g", members: ["b", "c"]), WheelEntry(id: "a")], "\(later)")
        // A slice the user placed outside the group stays there.
        let out = WheelArrangement(order: ["b", "g", "a", "d"], groups: [WheelGroup(id: "g", members: ["c"])])
        check(out.entries(["a", "b", "c", "d"], defaultGroups: groups).first == WheelEntry(id: "b"), "a slice taken out of a group stays out")
        // The user dissolved every group: nothing comes back.
        let none = WheelArrangement(groups: [])
        check(none.entries(["a", "b", "c", "d"], defaultGroups: groups).allSatisfy { !$0.isGroup }, "dissolved groups stay dissolved")
    }

    test("Wheels", "Settings drafts: group, add, take out, ungroup, rename and move, saved as little as possible") {
        let ids = ["a", "b", "c", "d", "e"]
        let groups = [WheelGroup(id: "g", members: ["c", "d"])]
        var draft = WheelDraft(WheelArrangement(), ids: ids, defaultGroups: groups)
        check(draft.entries.map(\.id) == ["a", "b", "g", "e"], "\(draft.entries.map(\.id))")
        check(draft.arrangement(ids: ids, defaultGroups: groups).isDefault, "an untouched draft saves nothing")

        let made = try unwrap(draft.makeGroup(of: ["e", "a"]), "no group was made")
        check(draft.entries.map(\.id) == [made, "b", "g"] && draft.entry(made)?.members == ["a", "e"], "the new group takes the first slice's place: \(draft.entries)")
        draft.add("b", to: made)
        check(draft.entry(made)?.members == ["a", "e", "b"] && draft.group(of: "b") == made, "b joins the end of the group")
        draft.move("b", .top)
        check(draft.entry(made)?.members == ["b", "a", "e"], "moving inside a group: \(draft.entry(made)?.members ?? [])")
        draft.names[made] = "  Mine  "
        let saved = draft.arrangement(ids: ids, defaultGroups: groups)
        check(saved.groups?.first { $0.id == made }?.name == "Mine", "names are saved trimmed")
        var expected = draft
        expected.names[made] = "Mine"
        check(WheelDraft(saved, ids: ids, defaultGroups: groups) == expected, "the draft comes back as it was saved")

        draft.takeOut("a")
        check(draft.entries.map(\.id) == [made, "a", "g"], "a taken out goes right after its group: \(draft.entries.map(\.id))")
        draft.takeOut("b")
        draft.takeOut("e")
        check(draft.entry(made) == nil && draft.names[made] == nil, "a group left empty goes away")
        draft.ungroup("g")
        check(draft.entries.map(\.id) == ["e", "b", "a", "c", "d"] && !draft.entries.contains(where: \.isGroup), "\(draft.entries.map(\.id))")
        let dissolved = draft.arrangement(ids: ids, defaultGroups: groups)
        check(dissolved.groups == [], "dissolving the app's group is remembered")

        var plain = WheelDraft(WheelArrangement(), ids: ids, defaultGroups: groups)
        plain.move("e", .top)
        let moved = plain.arrangement(ids: ids, defaultGroups: groups)
        check(moved.order == ["e", "a", "b", "g"] && moved.groups == nil, "moving alone keeps following the app's groups: \(moved)")
        plain.move("e", .bottom)
        check(plain.arrangement(ids: ids, defaultGroups: groups).isDefault, "moved back, it saves nothing again")
    }

    test("Wheels", "Settings lists every slice a file can show, in the order the wheel uses") {
        for source in SourceKind.allCases {
            let choices = WheelCatalog.choices(for: .convert(source)).map(\.id)
            check(Set(choices).count == choices.count, "\(source.rawValue): a format is listed twice")
            for format in source.formats {
                let targets = Conversions.targets(for: format).map(\.rawValue)
                check(Set(targets).isSubset(of: choices), "\(format.label): \(Set(targets).subtracting(choices).sorted()) missing from Settings")
                // Pages exports through Pages, in its own order; every other format follows the list.
                guard format != .pages else { continue }
                check(choices.filter(targets.contains) == targets, "\(format.label): Settings lists \(choices.filter(targets.contains)), the wheel shows \(targets)")
            }
        }
        check(WheelCatalog.arrangeableKinds.contains(.image) && WheelCatalog.arrangeableKinds.contains(.video), "images and video can be arranged")
        check(!WheelCatalog.arrangeableKinds.contains(.subtitle), "subtitles offer one format at a time, so there is nothing to arrange")
        for scope in [WheelScope.tools, .actions] {
            let ids = WheelCatalog.choices(for: scope).map(\.id)
            check(Set(ids).count == ids.count, "\(scope.key): two slices share an identifier")
        }
    }

    test("Wheels", "Slice identifiers are the same in every language") {
        defer { Localizer.shared.language = .en }
        let scopes: [WheelScope] = [.tools, .actions, .convert(.image), .convert(.document)]
        let english = scopes.map { WheelCatalog.choices(for: $0).map(\.id) }
        for language in [Language.pt, .fr, .es] {
            Localizer.shared.language = language
            check(scopes.map { WheelCatalog.choices(for: $0).map(\.id) } == english, "\(language.rawValue): identifiers changed with the language")
        }
    }

    test("Wheels", "PDF moved to the top comes first on every image wheel; hiding everything is explained") {
        try withoutArrangements {
            let scope = WheelScope.convert(.image)
            var order = WheelCatalog.choices(for: scope).map(\.id)
            order.removeAll { $0 == "pdf" }
            order.insert("pdf", at: 0)
            scope.arrangement = WheelArrangement(order: order)
            for name in ["photo.jpg", "quadrants.png", "animated.gif"] {
                let items = WheelCatalog.items(.convert, for: [Fixtures.url(name)]).map(\.id)
                check(items.first == "pdf", "\(name): PDF should be first, got \(items.prefix(3))")
                check(Set(items) == Set(Conversions.targets(for: Format.detect(Fixtures.url(name))!).map(\.rawValue)), "\(name): slices went missing")
            }
            check(WheelCatalog.items(.convert, for: [Fixtures.url("report.pdf")]).first?.id != "pdf", "the PDF wheel has its own arrangement")
            scope.arrangement = WheelArrangement(order: order, hidden: ["pdf", "webp"])
            let shown = WheelCatalog.items(.convert, for: [Fixtures.url("photo.jpg")]).map(\.id)
            check(!shown.contains("pdf") && !shown.contains("webp") && shown.first == "png", "hidden slices still show: \(shown)")
            scope.arrangement = WheelArrangement(hidden: Set(WheelCatalog.choices(for: scope).map(\.id)))
            check(WheelCatalog.items(.convert, for: [Fixtures.url("photo.jpg")]).isEmpty, "every slice is hidden")
            check(!WheelCatalog.offered(.convert, for: [Fixtures.url("photo.jpg")]).isEmpty, "the wheel still knows what it could offer")
            let message = Explain.allHidden(wheel: WheelKind.convert.title)
            check(message.message.contains(WheelKind.convert.title) && message.suggestion?.contains("Settings › Wheels") == true,
                  "the notice should name the wheel and where to show the slices: \(message.fullText)")
        }
    }

    test("Wheels", "The preview picture pops the chosen slice out in white") {
        LookStore.shared.glassWheel = false
        let items = (0..<6).map { index in WheelItem(id: "\(index)", title: "Item \(index)", symbol: nil) }
        let image = try unwrap(WheelView.picture(items: items, title: "Wheel", subtitle: "", highlighted: 2, style: WheelStyle()), "no picture")
        let rep = try unwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)), "the picture has no pixels")
        let layout = WheelLayout.make(titles: items.map(\.title), symbols: items.map(\.symbol), style: WheelStyle())
        let scale = CGFloat(rep.pixelsWide) / image.size.width
        func brightness(slice: Int) -> CGFloat {
            let angle = (CGFloat(slice) + 0.5) * layout.step
            let radius = layout.inner + 16
            let x = image.size.width / 2 + radius * sin(angle)
            let y = image.size.height / 2 + radius * cos(angle)
            return rep.colorAt(x: Int(x * scale), y: Int((image.size.height - y) * scale))?.usingColorSpace(.deviceRGB)?.brightnessComponent ?? -1
        }
        check(brightness(slice: 2) > 0.9, "the chosen slice should be white, brightness \(brightness(slice: 2))")
        check(brightness(slice: 0) < 0.25, "the other slices stay black, brightness \(brightness(slice: 0))")
    }
}

/// Runs `body` with no saved arrangement, putting back whatever the Mac had before.
private func withoutArrangements(_ body: () throws -> Void) throws {
    let defaults = UserDefaults.standard
    let saved = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("wheel.") }
    saved.keys.forEach(defaults.removeObject)
    defer {
        defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("wheel.") }.forEach(defaults.removeObject)
        saved.forEach { defaults.set($0.value, forKey: $0.key) }
    }
    try body()
}

private func unwrap<Value>(_ value: Value?, _ message: String) throws -> Value {
    guard let value else { throw Problem(message) }
    return value
}
