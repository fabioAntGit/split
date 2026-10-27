import AppKit
import SwiftUI

/// The interface, tested without touching the screen: offscreen windows, synthetic events,
/// colour maths and snapshots saved to build/test-run/_captures for a visual review.
func registerUITests() {
    test("Interface", "Every SF Symbol used exists") {
        var names = Set<String>()
        let pattern = try NSRegularExpression(pattern: "(?:systemName|systemSymbolName|symbol|systemImage):\\s*\"([^\"]+)\"")
        for file in Hostile.sources() {
            let text = Files.text(file)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text) { names.insert(String(text[range])) }
            }
        }
        QuickTool.allCases.forEach { names.insert($0.symbol) }
        EditorTool.allCases.forEach { names.insert($0.symbol) }
        FileAction.allCases.forEach { names.insert($0.symbol) }
        MarkupTool.allCases.forEach { names.insert($0.symbol) }
        CollageLayout.allCases.forEach { names.insert($0.symbol) }
        check(names.count >= 40, "only \(names.count) symbols found: did the search stop working?")
        for name in names.sorted() {
            check(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "the symbol “\(name)” doesn’t exist on this macOS")
        }
    }

    test("Interface", "Black and white: text on the selection ≥ 4.5:1, controls ≥ 3:1, in dark and light windows") {
        for name in [NSAppearance.Name.darkAqua, .aqua] {
            let appearance = NSAppearance(named: name)!
            let window = NSColor.windowBackgroundColor.cgColor(for: appearance)
            let selection = Palette.selection.cgColor(for: appearance)
            let onSelection = Palette.onSelection.cgColor(for: appearance)
            let accent = Palette.accent.cgColor(for: appearance)
            let tint = Palette.controlTint.cgColor(for: appearance)
            check(Contrast.ratio(selection, onSelection) >= 4.5, "\(name.rawValue): text on the selection: \(Contrast.format(selection, onSelection))")
            check(Contrast.ratio(accent, window) >= 3, "\(name.rawValue): accent against the window: \(Contrast.format(accent, window))")
            check(Contrast.ratio(tint, window) >= 3, "\(name.rawValue): control tint against the window: \(Contrast.format(tint, window))")
            check(Contrast.luminance(selection) > 0.95 || Contrast.luminance(selection) < 0.01, "\(name.rawValue): the selection is white or black")
        }
        let color = LookStore.shared.color
        defer { LookStore.shared.color = color }
        for look in LookColor.allCases {
            LookStore.shared.color = look
            let surface = Palette.wheelSurface.cgColor
            let ink = Palette.wheelInk.cgColor
            let appearance = try require(Palette.wheelAppearance, "\(look): no appearance for the wheel")
            check(Contrast.ratio(ink, surface) >= 4.5, "\(look): names on the wheel: \(Contrast.format(ink, surface))")
            check(appearance.isDark == (look == .black), "\(look): the wheel and the windows are \(look == .black ? "dark" : "light")")
            check(NSApp.appearance?.name == appearance.name, "\(look): every window follows the colour")
            // The highlighted slice is a veil of the ink over the surface: see-through, so it is judged as laid on it.
            let veil = Palette.wheelSelection
            let weight = Double(veil.alphaComponent)
            let under = Contrast.components(surface)
            let over = Contrast.components(veil.cgColor)
            let mix = (0..<3).map { (under[$0] * (1 - weight) + over[$0] * weight) / 255 }
            let slice = CGColor(srgbRed: mix[0], green: mix[1], blue: mix[2], alpha: 1)
            check(Contrast.ratio(ink, slice) >= 4.5, "\(look): names on the highlighted slice: \(Contrast.format(ink, slice))")
            check(Contrast.ratio(slice, surface) >= 1.3, "\(look): the highlighted slice against the wheel: \(Contrast.format(slice, surface))")
        }
        LookStore.shared.color = .black
        let black = Palette.wheelSurface.cgColor
        check((0.015...0.04).contains(Contrast.luminance(black)), "black is a soft black, not pitch black: \(Contrast.components(black))")
    }

    test("Interface", "Glass takes on the colour, never less than the floor that keeps the ink legible") {
        let (color, intensity) = (LookStore.shared.color, LookStore.shared.glassIntensity)
        defer {
            LookStore.shared.color = color
            LookStore.shared.glassIntensity = intensity
        }
        for look in LookColor.allCases {
            LookStore.shared.color = look
            for value in [0, 0.25, 1] {
                LookStore.shared.glassIntensity = value
                let tint = Palette.glassTint()
                // 0.75 is where the ink holds 4.5:1 even over a window of the opposite colour, measured on screen.
                check(tint.alphaComponent >= 0.75 && abs(tint.alphaComponent - (0.75 + 0.15 * value)) < 0.001, "\(look) at \(value): the tint is \(tint.alphaComponent) opaque")
                check(tint.whiteComponent == (look == .white ? 1 : 0), "\(look) at \(value): the tint is \(tint)")
            }
        }
        LookStore.shared.glassIntensity = 3
        check(Settings.glassIntensity == 1, "an intensity past the slider's end is kept at the end")
        LookStore.shared.color = .black
        let backdrop = WheelBackdrop.make(frame: NSRect(x: 0, y: 0, width: 200, height: 200), glass: true)
        check(backdrop.appearance?.name == .darkAqua, "black glass is dark glass")
        LookStore.shared.color = .white
        WheelBackdrop.tint(backdrop)
        check(backdrop.appearance?.name == .aqua, "tinted again, the same glass turns light")
    }

    test("Interface", "Wheel: each slice answers in the right place; the centre and outside don’t") {
        for count in 1...16 {
            let view = UIKitchen.wheel(count)
            let (inner, outer, disc) = view.geometry
            for index in 0..<count {
                let start = CGFloat(index) * view.step
                for (angle, radius) in [(start + view.step / 2, (inner + outer) / 2), (start + 0.03, inner + 2), (start + view.step - 0.03, disc + 10)] {
                    let point = UIKitchen.point(view, angle: angle, radius: radius)
                    check(view.index(at: point) == index, "\(count) slices: the point at \(Int(angle * 180 / .pi))° should be \(index), got \(view.index(at: point).map(String.init) ?? "none")")
                }
            }
            check(view.index(at: view.center) == nil, "\(count) slices: the centre should cancel")
            check(view.index(at: UIKitchen.point(view, angle: 0.3, radius: inner - 20)) == nil, "\(count) slices: near the centre should cancel")
            check(view.index(at: UIKitchen.point(view, angle: 0.3, radius: disc + 40)) == nil, "\(count) slices: far from the wheel should cancel")
        }
    }

    test("Interface", "Wheel: the highlighted slice takes the selection where the pointer finds it, on black and on white") {
        LookStore.shared.glassWheel = false
        let color = LookStore.shared.color
        defer { LookStore.shared.color = color }
        for (look, selected, surface) in [(LookColor.black, [80.0, 80, 80], [42.0, 42, 42]), (.white, [206, 206, 206], [245, 245, 245])] {
            LookStore.shared.color = look
            let view = UIKitchen.wheel(6)
            let window = UIKitchen.host(view)
            UIKitchen.key(view, 124)
            UIKitchen.key(view, 124)
            try require(view.highlighted == 1, "two right arrows should highlight slice 1")
            spinRunLoop(0.6)
            let image = try require(UIKitchen.render(view), "the wheel drew nothing")
            let radius = view.geometry.inner + 12
            let inside = UIKitchen.sample(image, view, angle: 1.5 * view.step, radius: radius)
            let neighbour = UIKitchen.sample(image, view, angle: 2.5 * view.step, radius: radius)
            check(UIKitchen.close(inside, selected, 8), "\(look): slice 1 should be \(selected), it is \(inside)")
            check(UIKitchen.close(neighbour, surface, 30), "\(look): slice 2 should keep the wheel's colour (\(neighbour))")
            // The platter sits inside its slice: a little in from the divider, and short of the rim.
            let middle = view.geometry.inner + 40
            let nearDivider = UIKitchen.sample(image, view, angle: view.step + 2.5 / middle, radius: middle)
            let inDivider = UIKitchen.sample(image, view, angle: view.step + 8 / middle, radius: middle)
            let pastRim = UIKitchen.sample(image, view, angle: 1.5 * view.step, radius: view.geometry.outer + 8)
            check(UIKitchen.close(nearDivider, surface, 30) && UIKitchen.close(inDivider, selected, 12), "\(look): the platter should start between 2.5 and 8 pt from the divider (\(nearDivider), \(inDivider))")
            check(UIKitchen.close(pastRim, surface, 30), "\(look): the platter shouldn’t reach the rim (\(pastRim))")
            window.close()
        }
    }

    test("Interface", "Wheel: icons share one ring and names sit under them, clear of the lines, at every size") {
        let samples = ["quadrants.jpg", "quadrants.png", "animated.gif", "drawing.svg", "clip.mp4", "tone.mp3", "report.pdf", "letter.docx",
                       "sales.xlsx", "prices.csv", "folder.zip", "notes.txt", "page.html", "book.epub", "subs.srt", "data.json"]
        defer { Localizer.shared.language = .en }
        var wheels = 0
        var slices = 0
        var truncatedAtMedium = 0
        var truncatedAtLargest: [String] = []
        var iconsOnlyFrom: [String] = []
        for language in [Language.en, .pt, .fr, .es] {
            Localizer.shared.language = language
            var sets: [(String, [WheelItem])] = []
            for sample in samples {
                let urls = [Fixtures.url(sample)]
                sets.append(("\(sample) convert", Conversions.targets(for: urls).map { WheelItem(title: $0.label, symbol: nil) }))
                // The tools wheel as it opens, and each of its groups.
                let tools = WheelCatalog.arranged(ToolCatalog.items(for: urls), WheelArrangement(), defaultGroups: WheelCatalog.defaultGroups(for: .tools))
                sets.append(("\(sample) tools", tools))
                for group in tools where group.isGroup { sets.append(("\(sample) \(group.title)", group.children)) }
            }
            sets.append(("actions", FileAction.allCases.map { WheelItem(title: $0.title, symbol: $0.symbol, detail: $0.detail) }))
            // The crowded cases: every tool ungrouped, and many long titles.
            sets.append(("all tools", QuickTool.allCases.map { WheelItem(title: $0.title, symbol: $0.symbol) }))
            sets.append(("editors", EditorTool.allCases.map { WheelItem(title: $0.title, symbol: $0.symbol) }))
            for size in WheelSize.allCases {
                for names in [true, false] {
                    let style = WheelStyle(size: size, names: names)
                    for (name, items) in sets where !items.isEmpty {
                        wheels += 1
                        let layout = WheelLayout.make(titles: items.map(\.title), symbols: items.map(\.symbol), style: style)
                        let label = "\(language.rawValue), \(size.label), names \(names ? "on" : "off"), \(name)"
                        check(layout.size == WheelLayout.windowSize(size), "\(label): the wheel isn’t the size chosen in Settings")
                        for (index, item) in items.enumerated() {
                            let slice = layout.slices[index]
                            let title = "\(label): “\(item.title)”"
                            if let icon = slice.icon {
                                check(abs(hypot(icon.x, icon.y - layout.iconLift) - layout.iconRadius) < 0.01, "\(title): the icon is off the ring the others share")
                                let box = CGRect(x: icon.x - layout.iconBox.width / 2, y: icon.y - layout.iconBox.height / 2,
                                                 width: layout.iconBox.width, height: layout.iconBox.height)
                                check(layout.clear(box, index: index), "\(title): the icon touches a divider, the hub or the rim")
                                if layout.style.names {
                                    guard let text = slice.text else { check(false, "\(title): the name is missing"); continue }
                                    check(text.maxY <= box.minY - WheelLayout.symbolGap + 0.5 && abs(text.midX - icon.x) < 0.5, "\(title): the name isn’t right under its icon")
                                } else {
                                    check(slice.text == nil, "\(title): names are off, but it shows one")
                                }
                            } else {
                                guard slice.text != nil else { check(false, "\(title): a slice without an icon must show its name"); continue }
                            }
                            if let text = slice.text {
                                check(layout.clear(text, index: index), "\(title): the name touches a divider, the hub or the rim")
                                if slice.truncated { check(text.width >= 2 * layout.fontSize - 1, "\(title): the name has no room left at all") }
                            }
                            let shift = CGPoint(x: WheelLayout.pop * sin(layout.angle(of: index)), y: WheelLayout.pop * cos(layout.angle(of: index)))
                            let boxes = [slice.text, slice.icon.map { CGRect(x: $0.x - layout.iconBox.width / 2, y: $0.y - layout.iconBox.height / 2,
                                                                             width: layout.iconBox.width, height: layout.iconBox.height) }]
                            let corners = boxes.compactMap { $0?.offsetBy(dx: shift.x, dy: shift.y) }.flatMap { box in
                                [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)]
                            }
                            check(corners.allSatisfy { hypot($0.x, $0.y) <= layout.outer }, "\(title): leaves the ring when its slice pops out")
                            for other in items.indices where other > index {
                                check(!layout.frame(of: index).intersects(layout.frame(of: other)), "\(title) overlaps “\(items[other].title)”")
                            }
                            if names, !name.hasPrefix("all tools") {
                                if size == .medium { slices += 1 }
                                if slice.truncated, size == .medium { truncatedAtMedium += 1 }
                                if slice.truncated, size == .extraLarge, language == .en { truncatedAtLargest.append(title) }
                            }
                            if names, !layout.style.names, size.rawValue >= WheelSize.medium.rawValue, !name.hasPrefix("all tools") { iconsOnlyFrom.append(title) }
                        }
                    }
                }
            }
        }
        check(wheels > 1000, "only \(wheels) wheels were checked")
        check(truncatedAtMedium * 20 <= slices, "at the usual size few names should be shortened: \(truncatedAtMedium) of \(slices)")
        check(truncatedAtLargest.isEmpty, "on the largest wheel every English name shows whole: \(truncatedAtLargest.prefix(6))")
        check(iconsOnlyFrom.isEmpty, "from the usual size up, every wheel has room for its names: \(iconsOnlyFrom.prefix(6))")
    }

    test("Interface", "Wheel: a small wheel shortens long names with “…” and keeps the icons in line") {
        let items = ["Compress to Size", "Remove Background", "Annotate and Cover", "Organize PDF", "Normalize Volume", "Make Mono", "Trim Silence",
                     "Remove Audio", "Strip Metadata", "Extract Frames"].map { WheelItem(title: $0, symbol: "circle") }
        let small = WheelLayout.make(titles: items.map(\.title), symbols: items.map(\.symbol), style: WheelStyle(size: .extraSmall, names: true))
        let large = WheelLayout.make(titles: items.map(\.title), symbols: items.map(\.symbol), style: WheelStyle(size: .extraLarge, names: true))
        check(small.slices.contains(where: \.truncated), "ten long names on the smallest wheel should not all fit whole")
        check(small.slices.filter(\.truncated).count > large.slices.filter(\.truncated).count, "a bigger wheel shortens fewer names")
        check(small.fontSize < large.fontSize && small.symbolSize < large.symbolSize, "text and icons follow the size of the wheel")
        check(Set(small.slices.compactMap { $0.icon.map { (hypot($0.x, $0.y - small.iconLift) * 100).rounded() } }).count == 1, "the icons share one ring")
        let iconsOnly = WheelLayout.make(titles: items.map(\.title), symbols: items.map(\.symbol), style: WheelStyle(size: .extraSmall, names: false))
        check(iconsOnly.symbolSize > small.symbolSize, "without names the icons grow")
        check(abs(iconsOnly.iconRadius - (iconsOnly.inner + iconsOnly.outer) / 2) < 0.01, "without names the icons sit mid-ring")
        // The drawn name really ends in an ellipsis: a cut-short box is narrower than the whole name.
        if let index = small.slices.firstIndex(where: \.truncated), let box = small.slices[index].text {
            let whole = WheelLayout.Measurer.attributed(items[index].title, fontSize: small.fontSize, bold: false)
                .boundingRect(with: NSSize(width: box.width, height: 1000), options: [.usesLineFragmentOrigin])
            check(whole.height > box.height + 1, "“\(items[index].title)” is marked shortened but fits its box")
        }
    }

    test("Interface", "Wheel: keyboard (arrows, Return, Esc) and mouse (press highlights, release confirms)") {
        let view = UIKitchen.wheel(5, clickMode: true)
        let window = UIKitchen.host(view)
        var performed: [Int] = []
        var cancelled = 0
        view.onPerform = { item, _ in performed.append(UIKitchen.option(item)) }
        view.onCancel = { cancelled += 1 }

        UIKitchen.key(view, 36)
        check(performed.isEmpty, "Return without a highlight does nothing")
        UIKitchen.key(view, 124)
        check(view.highlighted == 0, "→ starts at the first slice")
        UIKitchen.key(view, 126)
        check(view.highlighted == 1, "↑ moves clockwise")
        UIKitchen.key(view, 123)
        UIKitchen.key(view, 123)
        check(view.highlighted == 4, "← wraps round to the last slice (\(view.highlighted.map(String.init) ?? "none"))")
        UIKitchen.key(view, 36)
        check(performed == [4], "Return confirms the highlighted one: \(performed)")
        UIKitchen.key(view, 49)
        check(performed == [4, 4], "Space confirms too")
        UIKitchen.key(view, 53)
        check(cancelled == 1, "Esc cancels")

        func at(_ index: Int) -> NSPoint {
            UIKitchen.point(view, angle: (CGFloat(index) + 0.5) * view.step, radius: (view.geometry.inner + view.geometry.outer) / 2)
        }
        UIKitchen.mouse(view, .leftMouseDown, at(2))
        check(view.highlighted == 2 && performed.count == 2, "pressing highlights but doesn’t confirm yet")
        UIKitchen.mouse(view, .leftMouseDragged, at(3))
        check(view.highlighted == 3, "dragging moves the highlight")
        UIKitchen.mouse(view, .leftMouseUp, at(3))
        check(performed.last == 3, "releasing confirms where it is released: \(performed)")
        UIKitchen.mouse(view, .leftMouseDown, view.center)
        UIKitchen.mouse(view, .leftMouseUp, view.center)
        check(performed.count == 3 && cancelled == 2, "clicking the centre closes the wheel and does nothing")
        let outside = NSPoint(x: 4, y: 4)
        UIKitchen.mouse(view, .leftMouseDown, outside)
        UIKitchen.mouse(view, .leftMouseUp, outside)
        check(cancelled == 3, "clicking outside the wheel closes it")
        UIKitchen.mouse(view, .leftMouseDown, at(1))
        UIKitchen.mouse(view, .leftMouseUp, view.center)
        check(performed.count == 3 && cancelled == 3, "pressing a slice and releasing on the centre does nothing")
        UIKitchen.mouse(view, .mouseMoved, at(1))
        check(view.highlighted == 1, "hovering highlights")
        window.close()
    }

    test("Interface", "Wheel: VoiceOver sees each slice as a button that can be pressed") {
        let view = UIKitchen.wheel(4)
        let window = UIKitchen.host(view)
        var performed: [Int] = []
        view.onPerform = { item, _ in performed.append(UIKitchen.option(item)) }
        let children = (view.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
        try require(children.count == 4, "4 slices → \(children.count) accessibility elements")
        check(children.map { $0.accessibilityLabel() ?? "" } == ["Option 1", "Option 2", "Option 3", "Option 4"], "labels: \(children.map { $0.accessibilityLabel() ?? "" })")
        check(children.allSatisfy { $0.accessibilityRole() == .button }, "each slice is a button")
        check(children[2].accessibilityHelp() == "Detail 3", "the detail is the help text")
        check(children[2].accessibilityFrame().width > 0, "each slice has a place on screen")
        check(children[2].accessibilityPerformPress() && performed == [2], "pressing the third slice performs it: \(performed)")
        check(view.accessibilityRole() == .group && view.accessibilityLabel()?.contains("Test") == true, "the wheel is a named group")
        window.close()
    }

    test("Interface", "Wheel: a group opens as a wheel of its own; Esc, Delete and the centre go back") {
        let children = (0..<3).map { WheelItem(title: "Option \($0 + 1)", symbol: "circle") }
        let items = [WheelItem(title: "Option 1", symbol: "circle"),
                     WheelItem(id: "group", title: "Group", symbol: "square.stack", children: children),
                     WheelItem(title: "Option 3", symbol: "circle")]
        let view = WheelView(items: items, title: "Tools", subtitle: "file.txt", urls: [Fixtures.url("notes.txt")], clickMode: true)
        let window = UIKitchen.host(view)
        var performed: [String] = []
        var cancelled = 0
        view.onPerform = { item, _ in performed.append(item.title) }
        view.onCancel = { cancelled += 1 }
        func at(_ index: Int) -> NSPoint {
            UIKitchen.point(view, angle: (CGFloat(index) + 0.5) * view.step, radius: (view.geometry.inner + view.geometry.outer) / 2)
        }

        let size = view.frame.size
        UIKitchen.mouse(view, .leftMouseDown, at(1))
        UIKitchen.mouse(view, .leftMouseUp, at(1))
        check(performed.isEmpty && view.isInGroup && view.items.count == 3 && view.title == "Group", "clicking a group opens it")
        check(view.parentTitle == "Tools" && view.frame.size == size, "the open group knows its wheel, and the wheel keeps its size")
        let elements = (view.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
        check(elements.count == 4 && elements.first?.accessibilityLabel() == L("Back to %@", "Tools"), "VoiceOver gets a Back button first")
        UIKitchen.mouse(view, .leftMouseDown, at(2))
        UIKitchen.mouse(view, .leftMouseUp, at(2))
        check(performed == ["Option 3"], "a slice of the group is performed: \(performed)")

        UIKitchen.key(view, 53)
        check(!view.isInGroup && view.items.count == 3 && view.highlighted == 1 && cancelled == 0, "Esc goes back to the wheel, onto the group")
        UIKitchen.key(view, 36)
        check(view.isInGroup, "Return opens the highlighted group")
        UIKitchen.key(view, 51)
        check(!view.isInGroup, "Delete goes back")
        UIKitchen.key(view, 49)
        check(view.isInGroup, "Space opens it too")
        UIKitchen.mouse(view, .leftMouseDown, view.center)
        UIKitchen.mouse(view, .leftMouseUp, view.center)
        check(!view.isInGroup && cancelled == 0, "clicking the centre of a group goes back")
        UIKitchen.key(view, 53)
        check(cancelled == 1, "at the top, Esc closes the wheel")
        check(elements.first?.accessibilityPerformPress() == false, "an old Back button does nothing once back")
        window.close()
    }

    test("Interface", "Wheel: every change is drawn at once, also going back without moving the mouse") {
        let children = (0..<3).map { WheelItem(title: "Option \($0 + 1)", symbol: "circle") }
        let items = [WheelItem(title: "Option 1", symbol: "circle"),
                     WheelItem(id: "group", title: "Group", symbol: "square.stack", children: children)]
        let view = WheelView(items: items, title: "Tools", subtitle: "", urls: [], clickMode: true)
        let window = UIKitchen.host(view)
        let group = UIKitchen.point(view, angle: 1.5 * view.step, radius: (view.geometry.inner + view.geometry.outer) / 2)
        func openGroup() {
            UIKitchen.mouse(view, .leftMouseDown, group)
            UIKitchen.mouse(view, .leftMouseUp, group)
            spinRunLoop(0.6)
        }

        openGroup()
        var drawn = view.drawCount
        UIKitchen.mouse(view, .leftMouseDown, view.center)
        UIKitchen.mouse(view, .leftMouseUp, view.center)
        // Off screen, layer-backed views draw when the run loop turns.
        spinRunLoop(0.05)
        check(!view.isInGroup && view.drawCount > drawn, "clicking the centre redraws the wheel it goes back to (\(drawn) → \(view.drawCount) draws)")

        openGroup()
        drawn = view.drawCount
        UIKitchen.mouse(view, .mouseMoved, view.center)
        spinRunLoop(0.05)
        check(view.hubHighlighted && view.drawCount > drawn, "pointing at the centre of a group lights it up")
        window.close()
    }

    test("Interface", "Wheel: resting a drag on a group opens it, and on the centre goes back") {
        let children = (0..<2).map { WheelItem(title: "Option \($0 + 1)", symbol: "circle") }
        let items = [WheelItem(title: "Option 1", symbol: "circle"), WheelItem(id: "group", title: "Group", symbol: "circle", children: children)]
        let view = WheelView(items: items, title: "Tools", subtitle: "", urls: [], clickMode: false)
        let window = UIKitchen.host(view)
        view.dragMoved(to: UIKitchen.point(view, angle: 1.5 * view.step, radius: (view.geometry.inner + view.geometry.outer) / 2))
        check(view.highlighted == 1 && !view.isInGroup, "a drag highlights the group without opening it yet")
        spinRunLoop(WheelView.springDelay + 0.3)
        check(view.isInGroup && view.items.count == 2, "after a moment on the group, it opens")
        view.dragMoved(to: view.center)
        spinRunLoop(WheelView.springDelay + 0.3)
        check(!view.isInGroup, "after a moment on the centre, it goes back")
        window.close()
    }

    test("Interface", "Motion: critically damped springs, no bounce, interruptible") {
        var spring = SpringValue()
        spring.target = 1
        var peak: CGFloat = 0
        var time: CGFloat = 0
        while !spring.isSettled || time == 0 {
            spring.step(1 / 120)
            peak = max(peak, spring.value)
            time += 1 / 120
            if time > 3 { break }
        }
        check(spring.value == 1, "the spring should settle on its target (\(spring.value))")
        check(peak <= 1.001, "a critical spring doesn’t bounce (peak \(peak))")
        check(time < 0.7, "it took \(time) s to settle (0.26 s response)")

        var moving = SpringValue()
        moving.target = 1
        for _ in 0..<10 { moving.step(1 / 120) }
        let before = moving.value
        moving.target = 0
        moving.step(1 / 120)
        check(abs(moving.value - before) < 0.05, "changing target halfway can’t jump (\(before) → \(moving.value))")
        check(moving.value >= before - 0.001, "the motion keeps the speed it had before turning")

        if !Motion.reduceMotion, let animation = Motion.spring("opacity", from: 0, to: 1) as? CASpringAnimation {
            let critical = 2 * (animation.stiffness * animation.mass).squareRoot()
            check(abs(animation.damping - critical) < 0.01, "damping \(animation.damping) ≠ critical \(critical)")
            check(animation.duration > 0.2 && animation.duration < 1, "duration \(animation.duration) s")
        }
    }

    test("Interface", "HUD: states, texts, notes and plurals") {
        let hud = HUD.shared
        let out = [Fixtures.url("quadrants.png")]
        hud.showProgress(title: "Converting", item: "photo.heic", index: 1, count: 4)
        check(hud.model.state == .progress && hud.model.detail == "2 of 4 · photo.heic" && hud.model.fraction == 0.25, "progress: \(hud.model.detail)")
        hud.updateProgress(0.5)
        check(hud.model.fraction == 0.5, "progress should move on")
        let job = UUID()
        hud.showDone(outputs: out, message: "1 file converted", jobID: job)
        check(hud.model.state == .success && hud.model.detail.contains("quadrants.png") && hud.model.detail.contains("next to the original"), hud.model.detail)
        check(hud.model.undoJob == job, "a finished job can be undone from the banner")
        hud.updateProgress(0.9)
        check(hud.model.fraction == nil, "late progress can’t reopen a result")
        hud.showDone(outputs: out, message: "1 file converted", notes: ["JPG has no transparency."])
        check(hud.model.state == .warning && hud.model.detail.contains("JPG has no transparency."), "notes are shown: \(hud.model.detail)")
        check(hud.model.undoJob == nil, "without a job there is nothing to undo")
        let problem = Problem("The disk filled up.", suggestion: "Free some space.")
        hud.showDone(outputs: out, message: "1 of 3 converted", failures: [JobFailure(file: "a.mov", error: problem), JobFailure(file: "b.mov", error: problem)], total: 3)
        check(hud.model.state == .warning && hud.model.detail.contains("a.mov") && hud.model.detail.contains("1 more"), "warning: \(hud.model.detail)")
        hud.showDone(outputs: [], message: "Nothing converted", failures: [JobFailure(file: "a.mov", error: problem)], total: 1)
        check(hud.model.state == .failure && hud.model.detail.contains("Free some space"), "a single failure shows the suggestion: \(hud.model.detail)")
        hud.showNotice(Problem("Folders can’t be converted.", suggestion: "Use Create ZIP."))
        check(hud.model.state == .warning && hud.model.detail == "Use Create ZIP.", "a notice, without the error sound")
        hud.hide()

        let verbs = [JobRunner.phrase(1, (L("1 file converted"), L("%@ files converted"))), JobRunner.phrase(3, (L("1 file converted"), L("%@ files converted")))]
        check(verbs == ["1 file converted", "3 files converted"], "plurals: \(verbs)")
    }

    test("Interface", "HUD: the window draws the shadow, so the card’s shadow is never clipped") {
        let panel = HUD.shared.makePanel()
        check(panel.hasShadow && !panel.isOpaque && panel.backgroundColor == .clear, "the panel should be clear with a window shadow")
        let model = HUDModel()
        model.state = .success
        model.title = "3 files converted"
        model.detail = "The results are next to the originals."
        let view = HUDView(model: model, reveal: {}, open: {}, details: {}, activity: {}, cancel: {}, undo: {}, close: {})
        let image = try require(UIKitchen.renderClear(view, size: NSSize(width: 344 + 2 * HUD.inset, height: 110)), "the HUD drew nothing")
        let corner = Pixels.at(image, 1, 1)
        check(corner[3] == 0, "nothing is drawn in the margin around the card (it would be cut off): \(corner)")
        check(HUD.inset >= 6, "room for the close button on the corner")
    }

    test("Interface", "Wheels: options are short, unique and explained") {
        let samples = ["quadrants.jpg", "quadrants.png", "animated.gif", "drawing.svg", "clip.mp4", "tone.mp3", "report.pdf", "letter.docx",
                       "sales.xlsx", "prices.csv", "folder.zip", "notes.txt", "page.html", "book.epub", "subs.srt", "data.json"]
        for sample in samples {
            let urls = [Fixtures.url(sample)]
            let wheels: [(String, [(String, String?)])] = [
                ("convert", Conversions.targets(for: urls).map { ($0.label, L("Convert to %@", $0.label)) }),
                ("tools", ToolCatalog.items(for: urls).map { ($0.title, $0.detail) }),
                ("actions", FileAction.allCases.map { ($0.title, $0.detail) }),
            ]
            for (wheel, items) in wheels {
                let limit = items.allSatisfy { $0.0.count <= 7 } ? 16 : 14
                check(items.count <= limit, "\(sample), \(wheel) wheel: \(items.count) options are too many to read at a glance")
                check(Set(items.map(\.0)).count == items.count, "\(sample), \(wheel) wheel: repeated titles")
                for (title, detail) in items {
                    check(!title.isEmpty && title.count <= 22, "\(sample), \(wheel) wheel: the title “\(title)” is empty or too long")
                    check(!(detail ?? "").isEmpty, "\(sample), \(wheel) wheel: “\(title)” has no explanation")
                }
            }
        }
        for kind in WheelKind.allCases {
            check(!kind.title.isEmpty && !kind.summary.isEmpty && !kind.choosePrompt.isEmpty, "\(kind): title, summary and prompt")
        }
    }

    test("Interface", "Menus: the standard Mac shortcuts, in English and Portuguese") {
        final class Target: NSObject {
            @objc func settings() {}
            @objc func about() {}
        }
        let target = Target()
        let previous = NSApp.mainMenu
        defer {
            NSApp.mainMenu = previous
            Localizer.shared.language = .en
        }
        let english: [(String, NSEvent.ModifierFlags, String)] = [
            (",", [.command], "Settings"), ("q", [.command], "Quit"), ("h", [.command], "Hide"), ("w", [.command], "Close"),
            ("m", [.command], "Minimize"), ("z", [.command], "Undo"), ("z", [.command, .shift], "Redo"),
            ("x", [.command], "Cut"), ("c", [.command], "Copy"), ("v", [.command], "Paste"), ("a", [.command], "Select All"),
        ]
        let portuguese = ["Definições", "Sair", "Ocultar", "Fechar", "Minimizar", "Desfazer", "Refazer", "Cortar", "Copiar", "Colar", "Selecionar tudo"]
        for (language, titles) in [(Language.en, english.map(\.2)), (.pt, portuguese)] {
            Localizer.shared.language = language
            MainMenu.install(target: target, settings: #selector(Target.settings), about: #selector(Target.about))
            var items: [NSMenuItem] = []
            func walk(_ menu: NSMenu) {
                for item in menu.items {
                    items.append(item)
                    if let submenu = item.submenu { walk(submenu) }
                }
            }
            if let menu = NSApp.mainMenu { walk(menu) }
            for ((key, modifiers, _), title) in zip(english, titles) {
                let match = items.first { $0.keyEquivalent == key && $0.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == modifiers }
                check(match?.title.hasPrefix(title) == true, "\(language.rawValue): ⌘\(modifiers.contains(.shift) ? "⇧" : "")\(key.uppercased()) should be “\(title)”, it is “\(match?.title ?? "nothing")”")
            }
            var seen = Set<String>()
            for item in items where !item.keyEquivalent.isEmpty {
                let key = "\(item.keyEquivalent)-\(item.keyEquivalentModifierMask.rawValue)"
                check(!seen.contains(key), "\(language.rawValue): repeated shortcut: \(item.title)")
                seen.insert(key)
            }
        }
    }

    test("Shelf", "Dragging all the files never moves the window") {
        let panel = Shelf.shared.makePanel()
        check(!panel.isMovableByWindowBackground, "the shelf moves by its title bar only")
        check(!DragAllView().mouseDownCanMoveWindow, "a press on “Drag All” starts a file drag, not a window move")
        check(DragAllView().accessibilityRole() == .button && DragAllView().accessibilityLabel() == L("Drag All"), "“Drag All” is a button for VoiceOver")
        let model = ShelfModel()
        model.add([Fixtures.url("quadrants.png"), Fixtures.url("quadrants.png"), Fixtures.url("notes.txt")])
        check(model.items.count == 2, "the same file is held once")
        model.add([Fixtures.url("does-not-exist.txt")])
        model.prune()
        check(model.items.count == 2, "files that are gone disappear from the shelf")
    }

    test("Activity", "Waiting, running and finished; cancelling; undo moves only the new files away") {
        let log = ActivityLog.shared
        let folder = Fixtures.root.appendingPathComponent("_activity", isDirectory: true)
        let trash = folder.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let previous = ActivityLog.moveToTrash
        ActivityLog.moveToTrash = { url in try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent)) }
        defer { ActivityLog.moveToTrash = previous }

        let source = try Fixtures.isolated("quadrants.png", in: "activity")
        let token = CancelToken()
        let waiting = log.add(title: "Waiting job", files: [source], token: token)
        check(log.entry(waiting)?.state == .queued && log.active.contains { $0.id == waiting }, "a new job waits")
        log.cancel(waiting)
        check(log.entry(waiting)?.state == .cancelled && token.isCancelled, "a waiting job is cancelled straight away")

        let id = log.add(title: "Converting to JPG", files: [source], token: CancelToken())
        log.start(id)
        log.progress(id, fraction: 0.5, detail: "half way")
        check(log.entry(id)?.state == .running && log.entry(id)?.fraction == 0.5 && log.entry(id)?.detail == "half way", "progress is recorded")
        let output = folder.appendingPathComponent("quadrants.jpg")
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.copyItem(at: Fixtures.url("quadrants.jpg"), to: output)
        log.finish(id, state: .succeeded, summary: "1 file converted", outputs: [output, source], notes: ["A note"])
        let entry = try require(log.entry(id), "the finished job")
        check(!entry.state.isActive && entry.notes == ["A note"] && log.finished.contains { $0.id == id }, "the job is listed as finished, with its notes")
        check(ActivityLog.undoable(entry) == [output], "undo never touches a source file: \(ActivityLog.undoable(entry))")
        check(log.undo(id).isEmpty, "undo worked")
        check(!FileManager.default.fileExists(atPath: output.path) && FileManager.default.fileExists(atPath: trash.appendingPathComponent("quadrants.jpg").path),
              "the new file went to the Trash")
        check(FileManager.default.fileExists(atPath: source.path), "the original stays")
        check(log.entry(id)?.undone == true && ActivityLog.undoable(log.entry(id)!).isEmpty, "a job is undone once")
        log.clearFinished()
        check(log.finished.isEmpty, "Clear empties the finished list")
    }

    test("Activity", "A real job: listed, finished with notes, cancellable while it runs") {
        let log = ActivityLog.shared
        let png = try Fixtures.isolated("quadrants.png", in: "job")
        JobRunner.shared.convert([png], to: .jpg)
        check(waitUntil(20) { log.finished.contains { $0.files == [png] } }, "the conversion should finish")
        if let entry = log.finished.first(where: { $0.files == [png] }) {
            check(entry.state == .succeeded && entry.outputs.count == 1, "succeeded: \(entry.summary)")
            check(entry.notes.contains { $0.contains("transparency") }, "the transparency note reaches the activity list: \(entry.notes)")
            check(HUD.shared.model.undoJob == entry.id, "the banner can undo it")
        }
        let long = try Fixtures.isolated("long.mp4", in: "job-cancel")
        JobRunner.shared.convert([long], to: .webm)
        check(waitUntil(10) { log.active.contains { $0.files == [long] && $0.state == .running } }, "the long job starts")
        if let running = log.active.first(where: { $0.files == [long] }) {
            spinRunLoop(0.5)
            log.cancel(running.id)
            check(waitUntil(15) { log.entry(running.id)?.state == .cancelled }, "cancelling stops the job: \(log.entry(running.id)?.state as Any)")
            check(!FileManager.default.fileExists(atPath: long.deletingPathExtension().appendingPathExtension("webm").path), "a cancelled job leaves no half-made file")
        }
    }

    test("Interface", "The logo: six slices apart from each other around an open centre; the menu bar's is a template") {
        let center = CGPoint(x: 100, y: 100)
        let step = 2 * CGFloat.pi / CGFloat(Logo.slices)
        func at(_ angle: CGFloat, _ radius: CGFloat) -> CGPoint { CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle)) }
        for index in 0..<Logo.slices {
            let path = Logo.slice(index, center: center, radius: 80)
            let middle = .pi / 2 - (CGFloat(index) + 0.5) * step
            let border = .pi / 2 - CGFloat(index) * step
            check(path.contains(at(middle, 50)), "slice \(index) misses its own middle")
            check(!path.contains(at(border, 50)) && !path.contains(at(border - step, 50)), "slice \(index) reaches over a gap")
            check(!path.contains(center) && !path.contains(at(middle, 20)), "slice \(index) closes the centre")
            check(!path.contains(at(middle, 81)) && path.contains(at(middle, 78)), "slice \(index) doesn’t end at the rim")
        }
        let icon = Logo.menuBarImage()
        check(icon.isTemplate && icon.size == NSSize(width: 18, height: 18), "the menu bar icon should be an 18 pt template")
    }

    test("Interface", "Editors wear the wheel's dark grey, and glass when it is on") {
        let (color, intensity) = (LookStore.shared.color, LookStore.shared.glassIntensity)
        defer {
            LookStore.shared.glassWheel = false
            LookStore.shared.color = color
            LookStore.shared.glassIntensity = intensity
        }
        LookStore.shared.glassWheel = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let window = LookWindow(content: content, contentRect: content.bounds, styleMask: [.titled, .fullSizeContentView])
        window.isReleasedWhenClosed = false
        check(window.isOpaque && window.backgroundColor == Palette.wheelSurface && window.contentView === content, "glass off: the window is dark grey")
        LookStore.shared.color = .white
        check(window.backgroundColor == Palette.wheelSurface && window.appearance?.name == .aqua, "white: the open editor turns white at once")
        LookStore.shared.color = .black
        check(window.appearance?.name == .darkAqua, "black again: the editor is dark")
        LookStore.shared.glassWheel = true
        if Motion.reduceTransparency {
            check(window.isOpaque, "with Reduce Transparency on, the editor stays dark grey")
        } else {
            // Glass any deeper than the content view smears the title bar's buttons and title.
            let glass = window.contentView
            check(!window.isOpaque && glass !== content && (content.superview === glass || (glass != nil && content.isDescendant(of: glass!))), "glass on: the glass is the window's content view, and holds the content")
            check(glass?.frame.size == window.frame.size && content.frame.size == window.frame.size, "the glass covers the whole window, and so does the content")
            LookStore.shared.glassIntensity = 0.8
            check(window.contentView === glass, "a new intensity shades the same glass rather than building another")
        }
        LookStore.shared.glassWheel = false
        check(window.isOpaque && window.contentView === content && content.frame.size == window.frame.size, "glass off again: the backdrop goes away")
        window.close()
    }

    test("Interface", "Snapshots: wheels, HUD, editors, settings and help draw in every language") {
        let folder = Fixtures.root.appendingPathComponent("_captures", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var made: [String] = []
        func save(_ name: String, _ image: CGImage?) {
            guard let image else { check(false, "\(name): nothing was drawn"); return }
            let spread = UIKitchen.spread(image)
            check(spread > 8, "\(name): the image is almost uniform (\(spread)) — was the view empty?")
            try? UIKitchen.png(image, to: folder.appendingPathComponent("\(name).png"))
            made.append(name)
        }
        let color = LookStore.shared.color
        defer {
            Localizer.shared.language = .en
            LookStore.shared.glassWheel = false
            LookStore.shared.color = color
        }
        for language in [Language.en, .pt, .fr, .es] {
            Localizer.shared.language = language
            for (look, glass) in [(LookColor.black, false), (.black, true), (.white, false), (.white, true)] {
                LookStore.shared.color = look
                LookStore.shared.glassWheel = glass
                let urls = [Fixtures.url("quadrants.jpg")]
                let view = WheelView(items: UIKitchen.tools(urls), title: WheelKind.tools.title, subtitle: "quadrants.jpg", urls: urls, clickMode: true)
                let window = UIKitchen.host(view, appearance: .darkAqua)
                UIKitchen.key(view, 124)
                UIKitchen.key(view, 124)
                spinRunLoop(0.5)
                save("wheel-tools-\(look)\(glass ? "-glass" : "")-\(language.rawValue)", UIKitchen.render(view, backdrop: true))
                window.close()
            }
            LookStore.shared.color = .black
            LookStore.shared.glassWheel = false
            let video = [Fixtures.url("clip.mp4")]
            let busy = WheelView(items: UIKitchen.tools(video), title: WheelKind.tools.title, subtitle: "clip.mp4", urls: video, clickMode: true)
            let busyWindow = UIKitchen.host(busy, appearance: .darkAqua)
            spinRunLoop(0.3)
            save("wheel-video-tools-\(language.rawValue)", UIKitchen.render(busy, backdrop: true))
            if let sound = busy.items.firstIndex(where: { $0.id == StandardGroup.sound.rawValue }) {
                busy.openGroup(sound)
                spinRunLoop(0.4)
                save("wheel-video-sound-\(language.rawValue)", UIKitchen.render(busy, backdrop: true))
            } else {
                check(false, "the video tools have no Sound group")
            }
            busyWindow.close()
            for (size, names) in [(WheelSize.extraSmall, true), (.extraSmall, false), (.extraLarge, true)] {
                let all = QuickTool.allCases.map { WheelItem(title: $0.title, symbol: $0.symbol) }
                let wheel = WheelView(items: all, title: WheelKind.tools.title, subtitle: "", urls: [], clickMode: true, style: WheelStyle(size: size, names: names))
                let host = UIKitchen.host(wheel, appearance: .darkAqua)
                save("wheel-\(size)-\(names ? "names" : "icons")-\(language.rawValue)", UIKitchen.render(wheel, backdrop: true))
                host.close()
            }
            save("settings-\(language.rawValue)", UIKitchen.render(AnyView(SettingsView()), size: SettingsView.size, appearance: .darkAqua))
            SettingsNavigation.shared.tab = .wheels
            save("settings-wheels-\(language.rawValue)", UIKitchen.render(AnyView(SettingsView()), size: SettingsView.size, appearance: .darkAqua))
            SettingsNavigation.shared.tab = .formats
            save("settings-formats-\(language.rawValue)", UIKitchen.render(AnyView(SettingsView()), size: SettingsView.size, appearance: .darkAqua))
            SettingsNavigation.shared.tab = .general
            save("help-\(language.rawValue)", UIKitchen.render(AnyView(HelpView(close: {})), size: NSSize(width: 540, height: 520), appearance: .darkAqua))
        }
        Localizer.shared.language = .en
        let actions = WheelView(items: FileAction.allCases.map { action in WheelItem(title: action.title, symbol: action.symbol, detail: action.detail) { _ in } },
                                title: WheelKind.actions.title, subtitle: "2 files", urls: [], clickMode: true)
        let actionsWindow = UIKitchen.host(actions, appearance: .darkAqua)
        save("wheel-actions", UIKitchen.render(actions, backdrop: true))
        actionsWindow.close()

        let model = HUDModel()
        let states: [(String, HUDModel.State, String, String, Double?)] = [
            ("progress", .progress, "Converting to PDF", "2 of 4 · report.docx", 0.42),
            ("success", .success, "3 files converted", "The results are next to the originals.", nil),
            ("warning", .warning, "2 of 3 converted", "c.mov: the file is damaged or incomplete.", nil),
            ("error", .failure, "The disk filled up", "Free some space (for example, empty the Trash) and try again.", nil),
        ]
        for (name, state, title, detail, fraction) in states {
            model.state = state
            model.title = title
            model.detail = detail
            model.fraction = fraction
            model.outputs = state == .success ? [Fixtures.url("quadrants.png")] : []
            model.undoJob = state == .success ? UUID() : nil
            save("hud-\(name)", UIKitchen.render(HUDView(model: model, reveal: {}, open: {}, details: {}, activity: {}, cancel: {}, undo: {}, close: {}),
                                                 size: NSSize(width: 380, height: 110), appearance: .darkAqua))
        }

        let photo = Fixtures.url("photo.jpg")
        let preview = try EditorPreview.load(photo).image
        let host = EditorHost()
        let editors: [(String, AnyView)] = [
            ("editor-crop", AnyView(CropScreen(model: CropModel(urls: [photo], preview: preview), host: host))),
            ("editor-annotate", AnyView(AnnotateScreen(model: AnnotateModel(url: photo, preview: preview), host: host))),
            ("editor-adjust", AnyView(AdjustScreen(model: AdjustModel(urls: [photo], preview: preview), host: host))),
            ("editor-background", AnyView(BackgroundScreen(model: BackgroundModel(urls: [Fixtures.url("subject.png")],
                                                                                   preview: try EditorPreview.load(Fixtures.url("subject.png")).image), host: host))),
            ("editor-collage", AnyView(CollageScreen(model: CollageModel(urls: [photo, Fixtures.url("quadrants.png"), Fixtures.url("subject.png")]), host: host))),
            ("editor-pdf", AnyView(PDFOrganizerView(model: try PDFOrganizerModel(urls: [Fixtures.url("report.pdf")]), host: host))),
            ("editor-video", AnyView(MediaScreen(model: MediaEditorModel(url: Fixtures.url("clip.mp4")), host: host))),
            ("editor-audio", AnyView(MediaScreen(model: MediaEditorModel(url: Fixtures.url("tone.wav")), host: host))),
        ]
        for (name, view) in editors {
            save(name, UIKitchen.render(view, size: NSSize(width: 1120, height: 740), appearance: .darkAqua,
                                        settle: name == "editor-video" || name == "editor-audio" ? 1.5 : 0.6))
        }
        SettingsNavigation.shared.tab = .activity
        save("settings-activity", UIKitchen.render(AnyView(SettingsView()), size: SettingsView.size, appearance: .darkAqua))
        // Settings in a light window: the wheel's preview stays dark, everything else turns light.
        for tab in [SettingsTab.general, .wheels, .formats] {
            SettingsNavigation.shared.tab = tab
            save("settings-\(tab.rawValue)-light", UIKitchen.render(AnyView(SettingsView()), size: SettingsView.size, appearance: .aqua))
        }
        SettingsNavigation.shared.tab = .general
        let shelf = ShelfModel()
        shelf.add([photo, Fixtures.url("report.pdf"), Fixtures.url("clip.mp4")])
        save("shelf", UIKitchen.render(ShelfView(model: shelf), size: NSSize(width: 300, height: 360), appearance: .darkAqua))
        check(made.count >= 44, "only \(made.count) snapshots")
    }
}

// MARK: - Helpers

enum Contrast {
    static func components(_ color: CGColor) -> [Double] {
        let srgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil) ?? color
        let c = (srgb.components ?? [0, 0, 0, 1]).map(Double.init)
        let rgb = c.count >= 3 ? Array(c.prefix(3)) : [c[0], c[0], c[0]]
        return rgb.map { ($0 * 255).rounded() }
    }

    /// WCAG relative luminance.
    static func luminance(_ color: CGColor) -> Double {
        let linear = components(color).map { value -> Double in
            let v = value / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    static func ratio(_ a: CGColor, _ b: CGColor) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    static func format(_ a: CGColor, _ b: CGColor) -> String {
        String(format: "%.2f:1 (%@ on %@)", ratio(a, b), components(a).map { String(Int($0)) }.joined(separator: ","),
               components(b).map { String(Int($0)) }.joined(separator: ","))
    }
}

/// Builds views in offscreen windows (never ordered front) and drives them with synthetic events.
enum UIKitchen {
    static func wheel(_ count: Int, clickMode: Bool = true) -> WheelView {
        let items = (0..<count).map { WheelItem(title: "Option \($0 + 1)", symbol: "circle", detail: "Detail \($0 + 1)") { _ in } }
        return WheelView(items: items, title: "Test", subtitle: "file.txt", urls: [Fixtures.url("notes.txt")], clickMode: clickMode)
    }

    /// The tools wheel with the app's groups, as it opens with no arrangement saved.
    static func tools(_ urls: [URL]) -> [WheelItem] {
        WheelCatalog.arranged(ToolCatalog.items(for: urls), WheelArrangement(), defaultGroups: WheelCatalog.defaultGroups(for: .tools))
    }

    /// Which "Option N" of `wheel(_:)` an item is, counting from 0.
    static func option(_ item: WheelItem) -> Int { Int(item.title.split(separator: " ").last ?? "").map { $0 - 1 } ?? -1 }

    @discardableResult
    static func host(_ view: NSView, appearance: NSAppearance.Name = .darkAqua) -> NSWindow {
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        return window
    }

    /// Clockwise from 12 o'clock, like the wheel.
    static func point(_ view: WheelView, angle: CGFloat, radius: CGFloat) -> NSPoint {
        NSPoint(x: view.center.x + radius * sin(angle), y: view.center.y + radius * cos(angle))
    }

    static func key(_ view: NSView, _ code: UInt16) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                                     context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        view.keyDown(with: event)
    }

    static func mouse(_ view: NSView, _ type: NSEvent.EventType, _ point: NSPoint) {
        let location = view.convert(point, to: nil)
        let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        default: view.mouseMoved(with: event)
        }
    }

    /// The view's pixels; with `backdrop`, over a neutral grey standing in for the desktop behind.
    static func render(_ view: NSView, backdrop: Bool = false) -> CGImage? {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage else { return nil }
        let background = backdrop ? CGColor(gray: 0.35, alpha: 1) : nil
        return composite(image, over: background, appearance: view.effectiveAppearance)
    }

    static func render<V: View>(_ content: V, size: NSSize, appearance: NSAppearance.Name, settle: TimeInterval = 0.6) -> CGImage? {
        renderRaw(content, size: size, appearance: appearance, settle: settle).flatMap { composite($0.image, over: nil, appearance: $0.appearance) }
    }

    /// Without a background, so what is left transparent can be checked.
    static func renderClear<V: View>(_ content: V, size: NSSize) -> CGImage? {
        renderRaw(content, size: size, appearance: .darkAqua, settle: 0.4)?.image
    }

    private static func renderRaw<V: View>(_ content: V, size: NSSize, appearance: NSAppearance.Name, settle: TimeInterval) -> (image: CGImage, appearance: NSAppearance)? {
        let hosting = NSHostingView(rootView: content.themed())
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = host(hosting, appearance: appearance)
        window.isOpaque = false
        window.backgroundColor = .clear
        defer { window.close() }
        spinRunLoop(settle)
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep.cgImage.map { ($0, hosting.effectiveAppearance) }
    }

    /// Flattens onto the window background (or `background`) so transparent areas read as they do on screen.
    static func composite(_ image: CGImage, over background: CGColor?, appearance: NSAppearance) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(background ?? NSColor.windowBackgroundColor.cgColor(for: appearance))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// RGB at a wheel position (view points → image pixels; the image may be @2x).
    static func sample(_ image: CGImage, _ view: WheelView, angle: CGFloat, radius: CGFloat) -> [Double] {
        let point = self.point(view, angle: angle, radius: radius)
        let scale = CGFloat(image.width) / view.bounds.width
        let x = Int(point.x * scale)
        let y = image.height - 1 - Int(point.y * scale)
        return Pixels.at(image, x, y).prefix(3).map(Double.init)
    }

    static func close(_ a: [Double], _ b: [Double], _ tolerance: Double) -> Bool {
        zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
    }

    /// Standard deviation of luminance over a 64×64 downsample: ~0 means an empty view.
    static func spread(_ image: CGImage) -> Double {
        let side = 64
        var data = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &data, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let values = stride(from: 0, to: data.count, by: 4).map { 0.299 * Double(data[$0]) + 0.587 * Double(data[$0 + 1]) + 0.114 * Double(data[$0 + 2]) }
        let mean = values.reduce(0, +) / Double(values.count)
        return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
    }

    static func png(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw TestFailure("PNG") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw TestFailure("PNG") }
    }
}

