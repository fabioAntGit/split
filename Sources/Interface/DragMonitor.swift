import AppKit

/// Detects "files are being dragged + a modifier was tapped" without Accessibility
/// permission: poll the system drag pasteboard's change count, the mouse button
/// and the modifier state. A new change count while the button is down means a drag.
final class DragMonitor {
    var onTrigger: ((WheelKind, [URL]) -> Void)?
    var onDragEnded: (() -> Void)?

    private let dragBoard = NSPasteboard(name: .drag)
    private var timer: Timer?
    private var lastObservedChangeCount = 0
    private var changeCountBeforeMouseDown = 0
    private var buttonWasDown = false
    private var isDragging = false
    private var lastFlags: NSEvent.ModifierFlags = []
    private var tapCandidate: NSEvent.ModifierFlags = []
    private var tapStarted: TimeInterval = 0
    private let tapWindow: TimeInterval = 0.8
    private let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    func start() {
        lastObservedChangeCount = dragBoard.changeCount
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NSLog("[Split] Drag shortcut monitor started")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let primaryDown = NSEvent.pressedMouseButtons & 1 != 0
        let changeCount = dragBoard.changeCount

        if primaryDown {
            if !buttonWasDown { changeCountBeforeMouseDown = lastObservedChangeCount }
            // A new drag session writes the drag pasteboard after the mouse went down.
            if !isDragging && changeCount != changeCountBeforeMouseDown && !draggedFiles().isEmpty {
                isDragging = true
            }
        } else {
            if isDragging {
                isDragging = false
                onDragEnded?()
            }
            lastObservedChangeCount = changeCount
        }
        buttonWasDown = primaryDown
        trackModifiers()
    }

    /// A "tap" is pressing and releasing a modifier (or combination) quickly while dragging.
    private func trackModifiers() {
        let modifiers = NSEvent.modifierFlags.intersection(relevant)
        defer { lastFlags = modifiers }
        guard modifiers != lastFlags else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if lastFlags.isEmpty {
            tapCandidate = modifiers
            tapStarted = now
        } else if !modifiers.isEmpty {
            tapCandidate.formUnion(modifiers)
        } else {
            let candidate = tapCandidate
            tapCandidate = []
            guard isDragging, now - tapStarted <= tapWindow else { return }
            if let wheel = WheelKind.allCases.first(where: { Settings.modifier(for: $0) == candidate }) {
                let files = draggedFiles()
                if !files.isEmpty { onTrigger?(wheel, files) }
            }
        }
    }

    private func draggedFiles() -> [URL] {
        dragBoard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}
