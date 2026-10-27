import AppKit

struct WheelItem {
    /// Stable across languages, so the user's arrangement of the wheel can find it.
    let id: String
    let title: String
    let symbol: String?
    /// One line shown in the centre while the item is highlighted.
    var detail: String?
    /// A group's slices: choosing a group opens them as a wheel of their own.
    var children: [WheelItem]
    let action: ([URL]) -> Void

    var isGroup: Bool { !children.isEmpty }

    init(id: String? = nil, title: String, symbol: String?, detail: String? = nil, children: [WheelItem] = [],
         action: @escaping ([URL]) -> Void = { _ in }) {
        self.id = id ?? title
        self.title = title
        self.symbol = symbol
        self.detail = detail
        self.children = children
        self.action = action
    }
}

/// The radial wheel of drop targets shown around the cursor while files are dragged
/// (or clicked, when opened from the menu or "Open With").
final class WheelController {
    static let shared = WheelController()

    private var panel: WheelPanel?
    private var wheel: WheelView?
    private var clickMonitor: Any?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(items: [WheelItem], title: String, subtitle: String, urls: [URL], at point: NSPoint, clickMode: Bool) {
        hide(animated: false)
        let wheel = WheelView(items: items, title: title, subtitle: subtitle, urls: urls, clickMode: clickMode)
        let size = wheel.frame.width
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens[0]
        let bounds = screen.visibleFrame
        var origin = NSPoint(x: point.x - size / 2, y: point.y - size / 2)
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size)
        origin.y = min(max(origin.y, bounds.minY), bounds.maxY - size)

        let panel = WheelPanel(contentRect: NSRect(origin: origin, size: NSSize(width: size, height: size)),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        wheel.onPerform = { [weak self] item, chosen in
            Haptics.commit()
            self?.hide(animated: true)
            item.action(chosen)
        }
        wheel.onCancel = { [weak self] in self?.hide(animated: true) }
        wheel.onNeedsClicks = { [weak self, weak panel, weak wheel] in
            guard let self, let panel, let wheel else { return }
            self.acceptClicks(panel, wheel)
        }
        panel.contentView = wheel

        if clickMode {
            acceptClicks(panel, wheel)
        } else {
            panel.orderFrontRegardless()
            panel.makeKey()
        }
        // The wheel grows out of the cursor, so it's clear where it came from.
        let anchor = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        wheel.animateIn(from: anchor)
        panel.invalidateShadow()
        self.panel = panel
        self.wheel = wheel
    }

    /// From here on the wheel is clicked: it takes the keyboard and closes on a click elsewhere.
    private func acceptClicks(_ panel: WheelPanel, _ wheel: WheelView) {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(wheel)
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.hide(animated: true)
            }
        }
    }

    func hide(animated: Bool) {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        guard let panel, let wheel else { return }
        self.panel = nil
        self.wheel = nil
        wheel.stopAnimating()
        if animated {
            wheel.animateOut { panel.orderOut(nil) }
        } else {
            panel.orderOut(nil)
        }
    }

    /// While a drag is in progress, close only when the cursor isn't over the wheel.
    func dragEnded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, let wheel = self.wheel, !wheel.clickMode else { return }
            self.hide(animated: true)
        }
    }
}

final class WheelPanel: NSPanel {
    /// Glass only looks alive in the key window; in any other it goes flat and grey. Being
    /// nonactivating, the wheel can take the key without taking the app's focus from what is dragged.
    override var canBecomeKey: Bool { true }
}

/// A value that follows its target like a critically damped spring and can be
/// re-targeted mid-flight without a jump (it keeps its current value and velocity).
struct SpringValue {
    var value: CGFloat = 0
    var velocity: CGFloat = 0
    var target: CGFloat = 0
    var response: CGFloat = 0.26
    var damping: CGFloat = 1

    mutating func step(_ dt: CGFloat) {
        let stiffness = pow(2 * .pi / response, 2)
        let friction = 4 * .pi * damping / response
        let steps = 4
        let h = dt / CGFloat(steps)
        for _ in 0..<steps {
            velocity += (-stiffness * (value - target) - friction * velocity) * h
            value += velocity * h
        }
        if isSettled {
            value = target
            velocity = 0
        }
    }

    var isSettled: Bool { abs(value - target) < 0.002 && abs(velocity) < 0.02 }
}

final class WheelView: NSView {
    /// How long a drag rests on a group before it opens (or on the centre before going back).
    static let springDelay: TimeInterval = 0.5

    let style: WheelStyle
    private(set) var items: [WheelItem]
    private(set) var layout: WheelLayout
    private(set) var title: String
    private(set) var subtitle: String
    private(set) var urls: [URL]
    private(set) var clickMode: Bool
    /// Called with the chosen slice; groups never reach it, they open in place.
    var onPerform: ((WheelItem, [URL]) -> Void)?
    var onCancel: (() -> Void)?
    /// Files were dropped on a group: the wheel stays open for a click on one of its slices.
    var onNeedsClicks: (() -> Void)?

    /// The wheels left behind by opening groups, to go back to.
    private var trail: [(items: [WheelItem], title: String, subtitle: String, group: Int)] = []
    private var backdrop: NSView?
    private let drawing: WheelDrawing
    private var pops: [SpringValue]
    private var animationTimer: Timer?
    private var springTimer: Timer?
    private var lastTick = CACurrentMediaTime()
    private var pressedOutside = false
    private var pressedHub = false
    private lazy var fileIcon: NSImage? = urls.first.map { NSWorkspace.shared.icon(forFile: $0.path) }

    private(set) var highlighted: Int? {
        didSet {
            guard highlighted != oldValue else { return }
            for index in pops.indices { pops[index].target = index == highlighted ? 1 : 0 }
            // Snapping onto a new target is a meaningful moment: one subtle tick (never for a picture of the wheel).
            if highlighted != nil, window != nil { Haptics.snap() }
            startAnimating()
            armSpring()
            redraw()
        }
    }

    /// The pointer is on the centre of an open group, which goes back.
    private(set) var hubHighlighted = false {
        didSet {
            guard hubHighlighted != oldValue else { return }
            armSpring()
            redraw()
        }
    }

    var isInGroup: Bool { !trail.isEmpty }
    /// The wheel the open group belongs to.
    var parentTitle: String? { trail.last?.title }

    init(items: [WheelItem], title: String, subtitle: String, urls: [URL], clickMode: Bool, style: WheelStyle = .current) {
        self.style = style
        self.items = items
        layout = WheelLayout.make(titles: items.map(\.title), symbols: items.map(\.symbol), style: style)
        self.title = title
        self.subtitle = subtitle
        self.urls = urls
        self.clickMode = clickMode
        pops = Array(repeating: SpringValue(), count: items.count)
        drawing = WheelDrawing(frame: NSRect(x: 0, y: 0, width: layout.size, height: layout.size))
        super.init(frame: NSRect(x: 0, y: 0, width: layout.size, height: layout.size))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        appearance = Palette.wheelAppearance
        installBackdrop()
        // Drawing happens in an overlay above the material.
        drawing.owner = self
        drawing.autoresizingMask = [.width, .height]
        drawing.wantsLayer = true
        addSubview(drawing)

        registerForDraggedTypes([.fileURL])
        if clickMode { trackMouse() }
        NotificationCenter.default.addObserver(self, selector: #selector(lookChanged), name: LookStore.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        animationTimer?.invalidate()
        springTimer?.invalidate()
    }

    @objc private func lookChanged() {
        installBackdrop()
        redraw()
    }

    /// Solid dark grey, or glass when chosen in Settings (never with Reduce Transparency).
    private func installBackdrop() {
        backdrop?.removeFromSuperview()
        let disc = NSRect(x: bounds.midX - layout.disc, y: bounds.midY - layout.disc, width: layout.disc * 2, height: layout.disc * 2)
        let view = WheelBackdrop.make(frame: disc, glass: Settings.glassWheel && !Motion.reduceTransparency)
        addSubview(view, positioned: .below, relativeTo: nil)
        backdrop = view
    }

    private func trackMouse() {
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override var acceptsFirstResponder: Bool { true }

    /// Everything on the wheel is drawn by `drawing`, so it is asked directly: a layer-backed
    /// view's `needsDisplay` reads back false straight away and can't pass the request on.
    func redraw() { drawing.needsDisplay = true }
    /// How often the wheel has been drawn; tests use it to see that every change reaches the screen.
    fileprivate(set) var drawCount = 0

    var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    var step: CGFloat { layout.step }
    var geometry: (inner: CGFloat, outer: CGFloat, disc: CGFloat) { (layout.inner, layout.outer, layout.disc) }
    func pop(_ index: Int) -> CGFloat { pops.indices.contains(index) ? pops[index].value : 0 }
    var iconForHub: NSImage? { fileIcon }

    /// Angle measured clockwise from 12 o'clock. A generous margin outside the ring still counts.
    func index(at point: NSPoint) -> Int? {
        layout.slice(at: CGPoint(x: point.x - center.x, y: point.y - center.y))
    }

    func isOnHub(_ point: NSPoint) -> Bool {
        layout.isOnHub(CGPoint(x: point.x - center.x, y: point.y - center.y))
    }

    /// The wheel as a picture, drawn by the wheel itself, with `highlighted` already popped out
    /// (Settings previews arrangements with it). Glass can't be captured in a picture, so
    /// without `backdrop` the picture leaves it out for a live one to be put behind.
    static func picture(items: [WheelItem], title: String, subtitle: String, highlighted: Int? = nil,
                        style: WheelStyle = .current, back: String? = nil, backdrop: Bool = true) -> NSImage? {
        let view = WheelView(items: items, title: title, subtitle: subtitle, urls: [], clickMode: false, style: style)
        if !backdrop {
            view.backdrop?.removeFromSuperview()
            view.backdrop = nil
        }
        if let back { view.trail = [(items: [], title: back, subtitle: "", group: 0)] }
        if let highlighted, view.pops.indices.contains(highlighted) {
            view.highlighted = highlighted
            view.stopAnimating()
            view.pops[highlighted].value = 1
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: Choosing and groups

    /// Performs the slice, or opens it when it is a group.
    func choose(_ index: Int) {
        guard items.indices.contains(index) else { return }
        if items[index].isGroup {
            openGroup(index)
        } else {
            onPerform?(items[index], urls)
        }
    }

    func openGroup(_ index: Int) {
        guard items.indices.contains(index), items[index].isGroup else { return }
        let group = items[index]
        trail.append((items: items, title: title, subtitle: subtitle, group: index))
        show(group.children, title: group.title, subtitle: subtitle, highlight: nil)
    }

    /// Back to the wheel the open group belongs to; `highlightGroup` keeps the keyboard on the group.
    @discardableResult
    func goBack(highlightGroup: Bool = false) -> Bool {
        guard let level = trail.popLast() else { return false }
        show(level.items, title: level.title, subtitle: level.subtitle, highlight: highlightGroup ? level.group : nil)
        return true
    }

    private func show(_ items: [WheelItem], title: String, subtitle: String, highlight: Int?) {
        springTimer?.invalidate()
        springTimer = nil
        highlighted = nil
        hubHighlighted = false
        self.items = items
        self.title = title
        self.subtitle = subtitle
        layout = WheelLayout.make(titles: items.map(\.title), symbols: items.map(\.symbol), style: style)
        pops = Array(repeating: SpringValue(), count: items.count)
        highlighted = highlight
        segmentElements = makeSegmentElements()
        redraw()
        if window != nil { Haptics.snap() }
        animateLevelChange()
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    /// While files are dragged, resting on a group opens it and resting on the centre goes back.
    private func armSpring() {
        springTimer?.invalidate()
        springTimer = nil
        guard !clickMode, window != nil else { return }
        let open: (() -> Void)?
        if let index = highlighted, items[index].isGroup {
            open = { [weak self] in self?.openGroup(index) }
        } else if hubHighlighted {
            open = { [weak self] in self?.goBack() }
        } else {
            open = nil
        }
        guard let open else { return }
        let timer = Timer(timeInterval: WheelView.springDelay, repeats: false) { _ in open() }
        RunLoop.main.add(timer, forMode: .common)
        springTimer = timer
    }

    /// Files dropped on a group: open it, and wait for a click on one of its slices.
    private func becomeClickable() {
        guard !clickMode else { return }
        clickMode = true
        trackMouse()
        onNeedsClicks?()
    }

    // MARK: Motion

    private func startAnimating() {
        guard animationTimer == nil else { return }
        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(now - lastTick, 1.0 / 30))
        lastTick = now
        let reduce = Motion.reduceMotion
        var settled = true
        for index in pops.indices {
            if reduce {
                pops[index].value = pops[index].target
                pops[index].velocity = 0
            } else {
                pops[index].step(dt)
            }
            settled = settled && pops[index].isSettled
        }
        redraw()
        if settled { stopAnimating() }
    }

    func animateIn(from anchor: NSPoint) {
        guard let layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Motion.reduceMotion ? 0.12 : 0.18
        layer.add(fade, forKey: "fade")
        guard !Motion.reduceMotion else { return }
        layer.add(Motion.spring("transform", from: WheelView.scale(0.82, around: anchor), to: CATransform3DIdentity, response: 0.3), forKey: "grow")
    }

    /// A group opening (or closing) settles into place from slightly smaller, like a new menu level.
    private func animateLevelChange() {
        guard window != nil, let layer = drawing.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.16
        layer.add(fade, forKey: "fade")
        guard !Motion.reduceMotion else { return }
        layer.add(Motion.spring("transform", from: WheelView.scale(0.92, around: center), to: CATransform3DIdentity, response: 0.28), forKey: "level")
    }

    func animateOut(completion: @escaping () -> Void) {
        guard let layer else { return completion() }
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.16
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        layer.add(fade, forKey: "fadeOut")
        if !Motion.reduceMotion {
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.toValue = WheelView.scale(0.94, around: center)
            shrink.duration = 0.16
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            layer.add(shrink, forKey: "shrink")
        }
        CATransaction.commit()
    }

    /// Scale around a point of a layer whose anchor is its bottom-left corner.
    static func scale(_ factor: CGFloat, around point: NSPoint) -> CATransform3D {
        var transform = CATransform3DMakeTranslation(point.x, point.y, 0)
        transform = CATransform3DScale(transform, factor, factor, 1)
        return CATransform3DTranslate(transform, -point.x, -point.y, 0)
    }

    // MARK: Drag destination

    /// Files dragged over `point`, in the view's coordinates.
    @discardableResult
    func dragMoved(to point: NSPoint) -> NSDragOperation {
        highlighted = index(at: point)
        hubHighlighted = isInGroup && isOnHub(point)
        return highlighted == nil ? [] : .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragMoved(to: convert(sender.draggingLocation, from: nil)) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragMoved(to: convert(sender.draggingLocation, from: nil)) }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = nil
        hubHighlighted = false
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { highlighted != nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let index = highlighted, items.indices.contains(index) else { return false }
        let item = items[index]
        let dropped = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? urls
        let chosen = dropped.isEmpty ? urls : Intake.resolve(dropped)
        DispatchQueue.main.async {
            guard item.isGroup else { return self.onPerform?(item, chosen) ?? () }
            self.urls = chosen
            self.becomeClickable()
            self.openGroup(index)
        }
        return true
    }

    // MARK: Click mode (highlight on press, commit on release)

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        highlighted = index(at: point)
        hubHighlighted = isInGroup && isOnHub(point)
    }

    override func mouseExited(with event: NSEvent) {
        highlighted = nil
        hubHighlighted = false
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = index(at: point)
        pressedHub = isInGroup && isOnHub(point)
        pressedOutside = index == nil && !pressedHub
        highlighted = index
    }

    override func mouseDragged(with event: NSEvent) {
        highlighted = index(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = index(at: point) {
            choose(index)
        } else if pressedHub, isOnHub(point) {
            goBack()
        } else if pressedOutside {
            onCancel?()
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc: out of a group first, then away
            if !goBack(highlightGroup: true) { onCancel?() }
        case 51, 117: // Delete
            goBack(highlightGroup: true)
        case 36, 76, 49: // Return, Enter, Space
            if let highlighted { choose(highlighted) }
        case 123, 125: // ←, ↓: counter-clockwise
            guard !items.isEmpty else { return }
            highlighted = ((highlighted ?? 0) - 1 + items.count) % items.count
        case 124, 126: // →, ↑: clockwise
            guard !items.isEmpty else { return }
            highlighted = highlighted.map { ($0 + 1) % items.count } ?? 0
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Accessibility

    /// Each segment is a button for VoiceOver and Switch Control, named like its label; inside a
    /// group, a Back button comes first.
    private lazy var segmentElements: [NSAccessibilityElement] = makeSegmentElements()

    private func makeSegmentElements() -> [NSAccessibilityElement] {
        let segments: [NSAccessibilityElement] = items.indices.map { WheelSegmentElement(wheel: self, index: $0) }
        return isInGroup ? [WheelBackElement(wheel: self)] + segments : segments
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { subtitle.isEmpty ? title : "\(title), \(subtitle)" }
    override func accessibilityChildren() -> [Any]? { segmentElements }

    /// Where segment `index`'s icon and name sit on screen.
    func screenFrame(of index: Int) -> NSRect {
        guard items.indices.contains(index) else { return .zero }
        let block = layout.frame(of: index).offsetBy(dx: center.x, dy: center.y)
        return window?.convertToScreen(convert(block, to: nil)) ?? .zero
    }

    var hubScreenFrame: NSRect {
        let radius = layout.inner - 8
        let hub = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        return window?.convertToScreen(convert(hub, to: nil)) ?? .zero
    }
}

private final class WheelSegmentElement: NSAccessibilityElement {
    private weak var wheel: WheelView?
    private let index: Int

    init(wheel: WheelView, index: Int) {
        self.wheel = wheel
        self.index = index
        super.init()
        let item = wheel.items[index]
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.title)
        setAccessibilityHelp(item.detail)
        if item.isGroup { setAccessibilityRoleDescription(L("group")) }
        setAccessibilityParent(wheel)
    }

    override func accessibilityFrame() -> NSRect { wheel?.screenFrame(of: index) ?? .zero }
    override func isAccessibilityFocused() -> Bool { wheel?.highlighted == index }

    override func accessibilityPerformPress() -> Bool {
        wheel?.choose(index)
        return wheel != nil
    }
}

private final class WheelBackElement: NSAccessibilityElement {
    private weak var wheel: WheelView?

    init(wheel: WheelView) {
        self.wheel = wheel
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityLabel(L("Back to %@", wheel.parentTitle ?? ""))
        setAccessibilityParent(wheel)
    }

    override func accessibilityFrame() -> NSRect { wheel?.hubScreenFrame ?? .zero }

    override func accessibilityPerformPress() -> Bool {
        wheel?.goBack() ?? false
    }
}

/// Draws separators, the highlighted segment, icons and names, and the centre.
private final class WheelDrawing: NSView {
    weak var owner: WheelView?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let owner, let context = NSGraphicsContext.current?.cgContext else { return }
        owner.drawCount += 1
        let center = owner.center
        let layout = owner.layout
        let (inner, outer, disc) = owner.geometry
        let items = owner.items
        let step = owner.step
        let contrast = Motion.increaseContrast

        // Edge of the material: a hairline that reads as light catching glass.
        let rim = NSBezierPath(ovalIn: NSRect(x: center.x - disc + 0.5, y: center.y - disc + 0.5, width: disc * 2 - 1, height: disc * 2 - 1))
        rim.lineWidth = contrast ? 1.5 : 1
        Palette.wheelInk.withAlphaComponent(contrast ? 0.5 : (Settings.glassWheel ? 0.35 : 0.14)).setStroke()
        rim.stroke()

        // Separators between segments.
        if items.count > 1 {
            Palette.wheelInk.withAlphaComponent(contrast ? 0.4 : 0.14).setStroke()
            for index in 0..<items.count {
                let angle = CGFloat(index) * step
                let line = NSBezierPath()
                line.move(to: point(center, angle: angle, radius: inner + 10))
                line.line(to: point(center, angle: angle, radius: outer - 10))
                line.lineWidth = 1
                line.stroke()
            }
        }

        // Highlight: a platter inside its own slice, 5 pt from the dividers and the hub and short of the rim,
        // where a group's dots sit, with a hairline edge, like a menu selection. It is drawn `lift` closer
        // to the hub, so once it has risen with its slice it sits evenly.
        let lift = Motion.reduceMotion ? 0 : WheelLayout.pop
        for index in items.indices {
            let pop = owner.pop(index)
            let strength = index == owner.highlighted ? 1 : pop
            guard strength > 0.01 else { continue }
            let mid = layout.angle(of: index)
            let veil = Palette.wheelSelection
            let path = segment(center, start: CGFloat(index) * step, end: CGFloat(index + 1) * step,
                               inner: inner - 8 - lift, outer: outer + 7.5 - lift, inset: 5, corner: 9, single: items.count == 1)
            context.saveGState()
            context.translateBy(x: lift * pop * sin(mid), y: lift * pop * cos(mid))
            veil.withAlphaComponent(veil.alphaComponent * strength).setFill()
            path.fill()
            Palette.wheelInk.withAlphaComponent((contrast ? 0.5 : 0.14) * strength).setStroke()
            path.lineWidth = 1
            path.stroke()
            context.restoreGState()
        }

        for (index, item) in items.enumerated() {
            let pop = Motion.reduceMotion ? 0 : owner.pop(index)
            let angle = layout.angle(of: index)
            let shift = CGPoint(x: center.x + WheelLayout.pop * pop * sin(angle), y: center.y + WheelLayout.pop * pop * cos(angle))
            drawSlice(item, layout.slices[index], layout: layout, at: shift, grow: pop)
            if item.isGroup { drawGroupMark(center, angle: angle, radius: outer + WheelLayout.rimMargin / 2) }
        }

        drawHub(center: center, radius: inner - 8, owner: owner)
    }

    private func point(_ center: CGPoint, angle: CGFloat, radius: CGFloat) -> CGPoint {
        CGPoint(x: center.x + radius * sin(angle), y: center.y + radius * cos(angle))
    }

    /// Annular segment whose edges all sit `inset` points inside the slice, with rounded corners of
    /// radius `corner`, or less where the slice is too narrow for it.
    private func segment(_ center: CGPoint, start: CGFloat, end: CGFloat, inner: CGFloat, outer: CGFloat,
                         inset: CGFloat, corner: CGFloat, single: Bool) -> NSBezierPath {
        let ro = outer - inset
        let ri = inner + inset
        let path = NSBezierPath()
        if single {
            path.appendOval(in: NSRect(x: center.x - ro, y: center.y - ro, width: ro * 2, height: ro * 2))
            path.appendOval(in: NSRect(x: center.x - ri, y: center.y - ri, width: ri * 2, height: ri * 2))
            path.windingRule = .evenOdd
            return path
        }
        let narrow = sin((end - start) / 2)
        let r = max(1, min(corner, (narrow * ri - inset) / (1 - narrow)))
        // Each corner is a circle of radius r that touches its straight edge and its arc.
        let outerCentre = ro - r
        let innerCentre = ri + r
        let outerTurn = asin(min(1, (inset + r) / outerCentre))
        let innerTurn = asin(min(1, (inset + r) / innerCentre))
        func degrees(_ angle: CGFloat) -> CGFloat { 90 - angle * 180 / .pi }
        func arc(at centre: CGPoint, from: CGFloat, to: CGFloat) {
            path.appendArc(withCenter: centre, radius: r, startAngle: degrees(from), endAngle: degrees(to), clockwise: true)
        }
        let quarter = CGFloat.pi / 2
        arc(at: point(center, angle: start + innerTurn, radius: innerCentre), from: start + innerTurn + .pi, to: start + 3 * quarter)
        arc(at: point(center, angle: start + outerTurn, radius: outerCentre), from: start - quarter, to: start + outerTurn)
        path.appendArc(withCenter: center, radius: ro, startAngle: degrees(start + outerTurn), endAngle: degrees(end - outerTurn), clockwise: true)
        arc(at: point(center, angle: end - outerTurn, radius: outerCentre), from: end - outerTurn, to: end + quarter)
        arc(at: point(center, angle: end - innerTurn, radius: innerCentre), from: end + quarter, to: end - innerTurn + .pi)
        path.appendArc(withCenter: center, radius: ri, startAngle: degrees(end - innerTurn), endAngle: degrees(start + innerTurn), clockwise: false)
        path.close()
        return path
    }

    /// The icon on the ring every icon shares, and the name under it. The icon swells a little with `grow`.
    private func drawSlice(_ item: WheelItem, _ slice: WheelLayout.Slice, layout: WheelLayout, at origin: CGPoint, grow: CGFloat) {
        let color = Palette.wheelInk
        if let icon = slice.icon, let symbol = item.symbol, let image = WheelLayout.symbolImage(symbol, pointSize: layout.symbolSize) {
            let tinted = image.tinted(color)
            let size = CGSize(width: tinted.size.width * (1 + 0.06 * grow), height: tinted.size.height * (1 + 0.06 * grow))
            tinted.draw(in: NSRect(x: origin.x + icon.x - size.width / 2, y: origin.y + icon.y - size.height / 2, width: size.width, height: size.height))
        }
        guard let box = slice.text else { return }
        let bold = slice.icon == nil
        let text = WheelLayout.Measurer.attributed(item.title, fontSize: bold ? layout.labelFontSize : layout.fontSize, bold: bold, color: color)
        text.draw(with: box.offsetBy(dx: origin.x, dy: origin.y), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// Three dots on the rim: this slice opens a wheel of its own.
    private func drawGroupMark(_ center: CGPoint, angle: CGFloat, radius: CGFloat) {
        Palette.wheelInk.withAlphaComponent(Motion.increaseContrast ? 0.8 : 0.5).setFill()
        let gap: CGFloat = 5.5 / radius
        for step in -1...1 {
            let dot = point(center, angle: angle + CGFloat(step) * gap, radius: radius)
            NSBezierPath(ovalIn: NSRect(x: dot.x - 1.6, y: dot.y - 1.6, width: 3.2, height: 3.2)).fill()
        }
    }

    private func drawHub(center: CGPoint, radius: CGFloat, owner: WheelView) {
        let scale = owner.layout.textScale
        let hub = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        let ink = Palette.wheelInk
        ink.withAlphaComponent(owner.hubHighlighted ? 0.2 : 0.08).setFill()
        hub.fill()

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        // Long names (French, Spanish) wrap onto a second line before they are shortened.
        style.lineBreakMode = .byWordWrapping
        let width = radius * 2 - 18 * scale
        var title = owner.title
        var detail = owner.subtitle
        var icon = owner.iconForHub
        if let index = owner.highlighted {
            // Just the name, so there is room for all of it; VoiceOver still reads the detail.
            title = owner.items[index].title
            detail = ""
            icon = nil
        } else if let parent = owner.parentTitle {
            detail = L("Back to %@", parent)
            icon = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15 * scale, weight: .semibold))?.tinted(ink)
        } else if owner.items.isEmpty {
            title = L("Nothing to do")
        }
        let titleText = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: max(10.5, 12.5 * scale), weight: .semibold),
            .foregroundColor: ink,
            .paragraphStyle: style,
        ])
        let detailText = NSAttributedString(string: detail, attributes: [
            .font: NSFont.systemFont(ofSize: max(9.5, 10.5 * scale), weight: .regular),
            .foregroundColor: ink.withAlphaComponent(0.62),
            .paragraphStyle: style,
        ])
        // A name on its own may take a third line.
        let titleHeight = min((detail.isEmpty ? 48 : 32) * scale, ceil(titleText.boundingRect(with: NSSize(width: width, height: 1000), options: [.usesLineFragmentOrigin]).height))
        let detailHeight = detail.isEmpty ? 0 : min(27 * scale, ceil(detailText.boundingRect(with: NSSize(width: width, height: 1000), options: [.usesLineFragmentOrigin]).height))
        let iconSize: CGSize = icon.map { owner.parentTitle == nil ? CGSize(width: 30 * scale, height: 30 * scale) : $0.size } ?? .zero
        let total = iconSize.height + (iconSize.height > 0 ? 4 : 0) + titleHeight + (detail.isEmpty ? 0 : 1 + detailHeight)
        var y = center.y + total / 2
        if let icon, iconSize.height > 0 {
            icon.draw(in: NSRect(x: center.x - iconSize.width / 2, y: y - iconSize.height, width: iconSize.width, height: iconSize.height))
            y -= iconSize.height + 4
        }
        titleText.draw(with: NSRect(x: center.x - width / 2, y: y - titleHeight, width: width, height: titleHeight),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        guard !detail.isEmpty else { return }
        y -= titleHeight + 1
        detailText.draw(with: NSRect(x: center.x - width / 2, y: y - detailHeight, width: width, height: detailHeight),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        draw(in: NSRect(origin: .zero, size: size))
        color.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        image.unlockFocus()
        return image
    }
}

/// What sits behind the wheel: a dark grey disc, or Liquid Glass. `NSGlassEffectView` exists from
/// macOS 26 and the build SDK predates it, so it is found at run time; older systems get the
/// closest material instead.
enum WheelBackdrop {
    static func make(frame: NSRect, glass: Bool) -> NSView {
        let radius = frame.width / 2
        guard glass else {
            let view = NSView(frame: frame)
            view.wantsLayer = true
            view.layer?.backgroundColor = Palette.wheelSurface.cgColor
            view.layer?.cornerRadius = radius
            return view
        }
        if let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            let view = glassClass.init(frame: frame)
            if view.responds(to: NSSelectorFromString("setCornerRadius:")) { view.setValue(radius, forKey: "cornerRadius") }
            // The clear variant (style 1): what is behind shows through, only lightly frosted.
            if view.responds(to: NSSelectorFromString("setStyle:")) { view.setValue(1, forKey: "style") }
            tint(view)
            return view
        }
        let material = NSVisualEffectView(frame: frame)
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.maskImage = NSImage(size: frame.size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        let tintView = NSView(frame: material.bounds)
        tintView.wantsLayer = true
        tintView.layer?.cornerRadius = radius
        tintView.autoresizingMask = [.width, .height]
        material.addSubview(tintView)
        tint(material)
        return material
    }

    /// Gives glass the colour and intensity Settings asks for, in place. Before Liquid Glass, the
    /// material's first subview carries the tint; the solid disc has none.
    static func tint(_ view: NSView) {
        view.appearance = Palette.wheelAppearance
        if view is NSVisualEffectView {
            view.subviews.first?.layer?.backgroundColor = Palette.glassTint().cgColor
        } else if view.responds(to: NSSelectorFromString("setTintColor:")) {
            view.setValue(Palette.glassTint(), forKey: "tintColor")
        }
    }
}
