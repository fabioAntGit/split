import AppKit

/// What the wheel looks like: its size, and whether names show under the icons.
struct WheelStyle: Equatable {
    var size: WheelSize = .medium
    var names = true

    static var current: WheelStyle { WheelStyle(size: Settings.wheelSize, names: Settings.wheelNames) }
}

/// Geometry of the wheel and where each slice's icon and name go. The size is the user's, so a
/// wheel never changes size with what it shows. Every icon sits on one ring and every name right
/// under its icon, all in one font, on up to two lines; a name too long for its slice ends in
/// "…" (the centre shows the whole name of the slice under the pointer). A slice without an icon
/// centres its name on the middle of the ring. Nothing comes closer than `clearance` to the
/// lines around its slice, so it stays inside the white selection when the slice pops out.
struct WheelLayout {
    struct Slice: Equatable {
        /// Centre of the icon, relative to the wheel's centre (y up); nil without one.
        var icon: CGPoint?
        /// The name's box, relative to the wheel's centre; nil when the name isn't shown.
        var text: CGRect?
        /// The name doesn't fit whole and ends in "…".
        var truncated = false
    }

    static let rimMargin: CGFloat = 12
    static let windowMargin: CGFloat = 10
    /// How far the chosen slice moves outwards.
    static let pop: CGFloat = 5
    static let clearance: CGFloat = 6
    static let symbolGap: CGFloat = 3
    static let maxLines = 2

    let count: Int
    let style: WheelStyle
    let inner: CGFloat
    let outer: CGFloat
    /// The names under icons; `labelFontSize` is for slices that have only a name.
    let fontSize: CGFloat
    let labelFontSize: CGFloat
    let symbolSize: CGFloat
    /// The room an icon takes, the same for every slice so the names line up.
    let iconBox: CGSize
    /// Distance from the centre to every icon.
    let iconRadius: CGFloat
    private(set) var slices: [Slice]

    var disc: CGFloat { outer + WheelLayout.rimMargin }
    var size: CGFloat { 2 * (disc + WheelLayout.windowMargin) }
    var step: CGFloat { 2 * .pi / CGFloat(max(count, 1)) }
    /// 1 at the medium size: text and icons grow and shrink with the wheel.
    var scale: CGFloat { outer / WheelLayout.outerRadius(.medium) }
    /// Text and icons grow more slowly than the wheel, so a bigger wheel also has more room for names.
    var textScale: CGFloat { sqrt(scale) }

    static func outerRadius(_ size: WheelSize) -> CGFloat {
        switch size {
        case .extraSmall: return 146
        case .small: return 166
        case .medium: return 186
        case .large: return 210
        case .extraLarge: return 236
        }
    }

    /// The side of the window a wheel of this size needs.
    static func windowSize(_ size: WheelSize) -> CGFloat { 2 * (outerRadius(size) + rimMargin + windowMargin) }

    func angle(of index: Int) -> CGFloat { (CGFloat(index) + 0.5) * step }

    /// The icon and name of slice `index` together, relative to the wheel's centre, moved
    /// outwards by `popped`.
    func frame(of index: Int, popped: CGFloat = 0) -> CGRect {
        let slice = slices[index]
        var frame = slice.text ?? .null
        if let icon = slice.icon {
            frame = frame.union(CGRect(x: icon.x - iconBox.width / 2, y: icon.y - iconBox.height / 2, width: iconBox.width, height: iconBox.height))
        }
        return frame.offsetBy(dx: popped * sin(angle(of: index)), dy: popped * cos(angle(of: index)))
    }

    // MARK: Building

    /// When there isn't room for a name under every icon, not even shortened, the wheel shows
    /// icons only (`style.names` is then false); the centre still names the slice under the pointer.
    static func make(titles: [String], symbols: [String?], style: WheelStyle = .current) -> WheelLayout {
        let layout = fitted(titles: titles, symbols: symbols, style: style)
        guard style.names, layout.slices.contains(where: { $0.icon != nil && $0.text == nil }) else { return layout }
        return fitted(titles: titles, symbols: symbols, style: WheelStyle(size: style.size, names: false))
    }

    /// Every icon has the same size and sits on the same ring: the one closest to `preferred`
    /// where the most names fit whole under their icons. A crowded wheel gets smaller icons,
    /// never icons out of line.
    private static func fitted(titles: [String], symbols: [String?], style: WheelStyle) -> WheelLayout {
        let outer = outerRadius(style.size)
        let inner = (outer * 0.36).rounded()
        let scale = outer / outerRadius(.medium)
        func half(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }
        let textScale = sqrt(scale)
        let fontSize = max(9.5, half(11 * textScale))
        let labelFontSize = max(10.5, half(13 * textScale))
        let names = Measurer.height(lines: maxLines, fontSize: fontSize, bold: false)
        let middle = (inner + outer) / 2
        let named = style.names && symbols.contains { $0 != nil }
        var measurer = Measurer()
        var symbolSize = ((style.names ? 19 : 24) * textScale).rounded()
        while true {
            let iconBox = CGSize(width: (symbolSize * 1.35).rounded(), height: (symbolSize * 1.2).rounded())
            // As far out as two lines of name allow, where the slices are widest.
            let preferred = named ? max(middle, outer - clearance - iconBox.height / 2 - symbolGap - names) : middle
            let radii = named
                ? stride(from: inner + clearance + iconBox.height / 2, through: outer - clearance - iconBox.height / 2, by: 2).sorted { abs($0 - preferred) < abs($1 - preferred) }
                : [preferred]
            var best: (layout: WheelLayout, missing: Int, truncated: Int)?
            for radius in radii {
                var layout = WheelLayout(count: titles.count, style: style, inner: inner, outer: outer, fontSize: fontSize, labelFontSize: labelFontSize,
                                         symbolSize: symbolSize, iconBox: iconBox, iconRadius: radius, slices: [])
                guard layout.iconsFit(symbols) else { continue }
                layout.fitSlices(titles: titles, symbols: symbols, measurer: &measurer)
                let missing = layout.slices.filter { $0.text == nil && ($0.icon == nil || named) }.count
                let truncated = layout.slices.filter(\.truncated).count
                if best == nil || (missing, truncated) < (best!.missing, best!.truncated) { best = (layout, missing, truncated) }
                if missing == 0 && truncated == 0 { break }
            }
            if let best { return best.layout }
            guard symbolSize > 8 else {
                var layout = WheelLayout(count: titles.count, style: style, inner: inner, outer: outer, fontSize: fontSize, labelFontSize: labelFontSize,
                                         symbolSize: symbolSize, iconBox: iconBox, iconRadius: preferred, slices: [])
                layout.fitSlices(titles: titles, symbols: symbols, measurer: &measurer)
                return layout
            }
            symbolSize -= 1
        }
    }

    private func iconsFit(_ symbols: [String?]) -> Bool {
        symbols.indices.allSatisfy { index in
            guard symbols[index] != nil else { return true }
            let icon = iconCentre(index)
            return clear(CGRect(x: icon.x - iconBox.width / 2, y: icon.y - iconBox.height / 2, width: iconBox.width, height: iconBox.height), index: index)
        }
    }

    private func iconCentre(_ index: Int) -> CGPoint {
        CGPoint(x: iconRadius * sin(angle(of: index)), y: iconRadius * cos(angle(of: index)))
    }

    private mutating func fitSlices(titles: [String], symbols: [String?], measurer: inout Measurer) {
        let named = titles.indices.filter { symbols[$0] == nil }
        let nameRadius = named.isEmpty ? 0 : roomiestRadius(for: named, measurer: &measurer)
        var slices: [Slice] = []
        for index in 0..<count {
            var slice = Slice()
            if symbols[index] != nil {
                let icon = iconCentre(index)
                slice.icon = icon
                if style.names {
                    let top = icon.y - iconBox.height / 2 - WheelLayout.symbolGap
                    (slice.text, slice.truncated) = fitName(titles[index], index: index, bold: false, measurer: &measurer) { width, height in
                        CGRect(x: icon.x - width / 2, y: top - height, width: width, height: height)
                    }
                }
            } else {
                let anchor = CGPoint(x: nameRadius * sin(angle(of: index)), y: nameRadius * cos(angle(of: index)))
                (slice.text, slice.truncated) = fitName(titles[index], index: index, bold: true, measurer: &measurer) { width, height in
                    CGRect(x: anchor.x - width / 2, y: anchor.y - height / 2, width: width, height: height)
                }
            }
            slices.append(slice)
        }
        self.slices = slices
    }

    /// The one radius for names without icons where the most crowded of them has the most room:
    /// the middle of the ring, unless a crowded wheel needs them further out, where slices are wider.
    private func roomiestRadius(for indices: [Int], measurer: inout Measurer) -> CGFloat {
        let middle = (inner + outer) / 2
        let lineHeight = Measurer.height(lines: 1, fontSize: labelFontSize, bold: true)
        var best = (radius: middle, room: CGFloat(-1))
        for radius in stride(from: middle, through: outer - WheelLayout.clearance - lineHeight / 2, by: 2) {
            let room = indices.map { index -> CGFloat in
                let anchor = CGPoint(x: radius * sin(angle(of: index)), y: radius * cos(angle(of: index)))
                return widestClear(index: index, bold: true) { width, height in
                    CGRect(x: anchor.x - width / 2, y: anchor.y - height / 2, width: width, height: height)
                } ?? 0
            }.min() ?? 0
            if room > best.room + 0.5 { best = (radius, room) }
            if room >= (120 * scale).rounded() { break }
        }
        return best.radius
    }

    /// The widest one-line box `place` makes that stays clear of slice `index`'s lines.
    private func widestClear(index: Int, bold: Bool, lines: Int = 1, place: (CGFloat, CGFloat) -> CGRect) -> CGFloat? {
        let size = bold ? labelFontSize : fontSize
        let height = Measurer.height(lines: lines, fontSize: size, bold: bold)
        let narrowest = (size * 2).rounded()
        return stride(from: (120 * scale).rounded(), through: narrowest, by: -2).first { clear(place($0, height), index: index) }
    }

    /// The widest box `place` makes for one line and for two that stays clear of the slice's
    /// lines, and the name in the one that shows the most of it.
    private func fitName(_ title: String, index: Int, bold: Bool, measurer: inout Measurer,
                         place: (CGFloat, CGFloat) -> CGRect) -> (CGRect?, Bool) {
        let size = bold ? labelFontSize : fontSize
        let oneHeight = Measurer.height(lines: 1, fontSize: size, bold: bold)
        let twoHeight = Measurer.height(lines: 2, fontSize: size, bold: bold)
        let oneLine = measurer.width(title, fontSize: size, bold: bold)
        let one = widestClear(index: index, bold: bold, place: place)
        if let one, oneLine <= one { return (place(oneLine, oneHeight), false) }
        // Two lines break between words only: a word wider than the box would be split in two.
        let words = title.split(whereSeparator: \.isWhitespace).map { measurer.width(String($0), fontSize: size, bold: bold) }
        if WheelLayout.maxLines > 1, let two = widestClear(index: index, bold: bold, lines: 2, place: place) {
            let wrapped = measurer.size(title, fontSize: size, bold: bold, width: two)
            if wrapped.height <= twoHeight + 0.5, words.allSatisfy({ $0 <= two }) { return (place(min(two, wrapped.width + 2), twoHeight), false) }
            if words.first ?? 0 <= two, two * 2 >= (one ?? 0) { return (place(two, twoHeight), true) }
        }
        return (one.map { place($0, oneHeight) }, true)
    }

    // MARK: Fitting

    /// Inside the ring, away from the hub and the rim, and not touching either line of slice `index`.
    func clear(_ rect: CGRect, index: Int) -> Bool {
        let margin = WheelLayout.clearance
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
        guard corners.allSatisfy({ hypot($0.x, $0.y) <= outer - margin }) else { return false }
        let nearest = CGPoint(x: min(max(0, rect.minX), rect.maxX), y: min(max(0, rect.minY), rect.maxY))
        guard hypot(nearest.x, nearest.y) >= inner + margin else { return false }
        guard count > 1 else { return true }
        let padded = rect.insetBy(dx: -margin, dy: -margin)
        for edge in [CGFloat(index) * step, CGFloat(index + 1) * step] {
            let start = CGPoint(x: inner * sin(edge), y: inner * cos(edge))
            let end = CGPoint(x: disc * sin(edge), y: disc * cos(edge))
            if WheelLayout.segment(start, end, intersects: padded) { return false }
        }
        return true
    }

    /// Liang–Barsky: does the segment pass through the rectangle?
    static func segment(_ a: CGPoint, _ b: CGPoint, intersects rect: CGRect) -> Bool {
        var t0: CGFloat = 0
        var t1: CGFloat = 1
        let dx = b.x - a.x
        let dy = b.y - a.y
        for (p, q) in [(-dx, a.x - rect.minX), (dx, rect.maxX - a.x), (-dy, a.y - rect.minY), (dy, rect.maxY - a.y)] {
            if p == 0 {
                if q < 0 { return false }
            } else {
                let t = q / p
                if p < 0 { t0 = max(t0, t) } else { t1 = min(t1, t) }
                if t0 > t1 { return false }
            }
        }
        return true
    }

    // MARK: Text

    static func font(size: CGFloat, bold: Bool) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .medium)
    }

    static func symbolImage(_ name: String, pointSize: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
    }

    /// Caches text sizes: the same name is measured at the same widths again and again.
    struct Measurer {
        private var sizes: [String: CGSize] = [:]

        /// Centred, wrapping between words, and ending in "…" when cut short.
        static func attributed(_ text: String, fontSize: CGFloat, bold: Bool, color: NSColor = .labelColor) -> NSAttributedString {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byWordWrapping
            return NSAttributedString(string: text, attributes: [
                .font: WheelLayout.font(size: fontSize, bold: bold),
                .foregroundColor: color,
                .paragraphStyle: style,
            ])
        }

        private static var heights: [String: CGFloat] = [:]

        /// The height `lines` lines take when drawn, as the text system lays them out.
        static func height(lines: Int, fontSize: CGFloat, bold: Bool) -> CGFloat {
            let key = "\(lines)|\(fontSize)|\(bold)"
            if let cached = heights[key] { return cached }
            let sample = Array(repeating: "Hg", count: lines).joined(separator: "\n")
            let height = ceil(attributed(sample, fontSize: fontSize, bold: bold)
                .boundingRect(with: NSSize(width: 1000, height: 1000), options: [.usesLineFragmentOrigin]).height)
            heights[key] = height
            return height
        }

        mutating func size(_ text: String, fontSize: CGFloat, bold: Bool, width: CGFloat) -> CGSize {
            let key = "\(fontSize)|\(bold)|\(width)|\(text)"
            if let cached = sizes[key] { return cached }
            let rect = Measurer.attributed(text, fontSize: fontSize, bold: bold)
                .boundingRect(with: NSSize(width: width, height: 400), options: [.usesLineFragmentOrigin])
            let size = CGSize(width: ceil(rect.width), height: ceil(rect.height))
            sizes[key] = size
            return size
        }

        /// On one line.
        mutating func width(_ text: String, fontSize: CGFloat, bold: Bool) -> CGFloat {
            size(text, fontSize: fontSize, bold: bold, width: 10_000).width + 2
        }
    }
}
