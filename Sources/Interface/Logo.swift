import AppKit

/// Split's mark: six rounded slices of a wheel, the one from twelve to two o'clock chosen. The
/// menu bar draws it from here, and so does the app icon (Resources/Icon builds with this file).
enum Logo {
    static let slices = 6
    static let grey = NSColor(srgbRed: 70 / 255, green: 70 / 255, blue: 70 / 255, alpha: 1)

    /// The wheel's proportions, against its outer radius: where the slices' round inner ends
    /// reach, the space between slices and the rounding of their outer corners.
    private static let tip: CGFloat = 0.336
    private static let gap: CGFloat = 0.083
    private static let rounding: CGFloat = 0.117

    /// Slice `index`, counted clockwise from the chosen one, in a wheel of `radius` around
    /// `center`. Small wheels ask for a wider `gap` (a share of the radius), so the slices stay apart.
    static func slice(_ index: Int, center: CGPoint, radius: CGFloat, gap: CGFloat? = nil) -> NSBezierPath {
        let step = 2 * CGFloat.pi / CGFloat(slices)
        let upper = CGFloat.pi / 2 - CGFloat(index) * step
        let lower = upper - step
        let half = (gap ?? Logo.gap) * radius / 2
        let corner = rounding * radius
        let spread = sin(step / 2)

        // Each side runs parallel to its slice's border, `half` inside it.
        func ray(_ angle: CGFloat) -> CGPoint { CGPoint(x: cos(angle), y: sin(angle)) }
        let upperNormal = CGPoint(x: sin(upper), y: -cos(upper))
        let lowerNormal = CGPoint(x: -sin(lower), y: cos(lower))
        func point(_ normal: CGPoint, _ across: CGFloat, _ angle: CGFloat, _ along: CGFloat) -> CGPoint {
            let direction = ray(angle)
            return CGPoint(x: normal.x * across + direction.x * along, y: normal.y * across + direction.y * along)
        }

        /// The rounding of an outer corner: its centre, and where it touches the side and the rim.
        func outerCorner(_ angle: CGFloat, _ normal: CGPoint) -> (center: CGPoint, onSide: CGPoint, onRim: CGPoint) {
            let along = sqrt((radius - corner) * (radius - corner) - (half + corner) * (half + corner))
            let center = point(normal, half + corner, angle, along)
            let onRim = CGPoint(x: center.x / (radius - corner) * radius, y: center.y / (radius - corner) * radius)
            return (center, point(normal, half, angle, along), onRim)
        }

        // The inner end is one round arc touching both sides, its nearest point at `tip`.
        let end = (tip * radius - half / spread) / (1 / spread - 1)
        let endAlong = (half + end) / spread * cos(step / 2)
        let endCenter = CGPoint(x: ray((upper + lower) / 2).x * (half + end) / spread, y: ray((upper + lower) / 2).y * (half + end) / spread)
        let upperOuter = outerCorner(upper, upperNormal)
        let lowerOuter = outerCorner(lower, lowerNormal)
        let upperInner = point(upperNormal, half, upper, endAlong)
        let lowerInner = point(lowerNormal, half, lower, endAlong)

        func degrees(_ point: CGPoint, from origin: CGPoint) -> CGFloat { atan2(point.y - origin.y, point.x - origin.x) * 180 / .pi }
        func shifted(_ point: CGPoint) -> CGPoint { CGPoint(x: center.x + point.x, y: center.y + point.y) }
        func arc(_ path: NSBezierPath, around origin: CGPoint, radius: CGFloat, from: CGPoint, to: CGPoint) {
            path.appendArc(withCenter: shifted(origin), radius: radius, startAngle: degrees(from, from: origin), endAngle: degrees(to, from: origin), clockwise: true)
        }

        let path = NSBezierPath()
        path.move(to: shifted(upperInner))
        path.line(to: shifted(upperOuter.onSide))
        arc(path, around: upperOuter.center, radius: corner, from: upperOuter.onSide, to: upperOuter.onRim)
        arc(path, around: .zero, radius: radius, from: upperOuter.onRim, to: lowerOuter.onRim)
        arc(path, around: lowerOuter.center, radius: corner, from: lowerOuter.onRim, to: lowerOuter.onSide)
        path.line(to: shifted(lowerInner))
        arc(path, around: endCenter, radius: end, from: lowerInner, to: upperInner)
        path.close()
        return path
    }

    /// The menu bar's wheel: a template, so macOS colours it like the icons around it. The chosen
    /// slice is solid, the others faint, as on the app icon.
    static func menuBarImage(side: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let center = CGPoint(x: rect.midX, y: rect.midY)
            for index in 0..<slices {
                NSColor.black.withAlphaComponent(index == 0 ? 1 : 0.38).setFill()
                slice(index, center: center, radius: side / 2 - 0.5, gap: 0.16).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Split"
        return image
    }
}
