import AppKit
import SwiftUI

final class HUDModel: ObservableObject {
    enum State: Equatable { case progress, success, warning, failure, info }

    @Published var state: State = .info
    @Published var title = ""
    @Published var detail = ""
    @Published var fraction: Double?
    @Published var outputs: [URL] = []
    @Published var failures: [JobFailure] = []
    @Published var hovering = false
    /// The job behind the progress banner, so it can be cancelled from here.
    @Published var jobID: UUID?
    /// The finished job whose results "Undo" moves to the Trash; nil when there is nothing to undo.
    @Published var undoJob: UUID?
}

/// Status banner under the menu bar, styled like a macOS notification:
/// progress, results (click to reveal) and explained errors. Closing it never loses
/// anything: every job stays listed in Settings › Activity.
final class HUD {
    static let shared = HUD()

    let model = HUDModel()
    private var panel: NSPanel?
    private var hosting: NSHostingView<HUDView>?
    private var hideWork: DispatchWorkItem?
    private var autoHideDelay: TimeInterval?
    private var hoverObservation: Any?
    private var shapeObservation: Any?

    /// Room around the card for the close button, which sits on its corner. The shadow is
    /// drawn by the window server around the card's shape, so it is never clipped.
    static let inset: CGFloat = 8

    /// Internal (not private) so the tests can check the window it builds.
    func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = HUDView(model: model,
                           reveal: { [weak self] in self?.showResultsInFinder() },
                           open: { [weak self] in self?.openOutputs() },
                           details: { [weak self] in self?.showDetails() },
                           activity: { [weak self] in self?.showActivity() },
                           cancel: { [weak self] in self?.cancelJob() },
                           undo: { [weak self] in self?.undoJob() },
                           close: { [weak self] in self?.hide() })
        let hosting = NSHostingView(rootView: view)
        panel.contentView = hosting
        self.hosting = hosting
        hoverObservation = model.$hovering.sink { [weak self] hovering in
            guard let self else { return }
            // Never hide a message while it's being read.
            if hovering { self.hideWork?.cancel() } else { self.scheduleHide() }
            self.refreshShadow()
        }
        // The shadow follows the card's outline, so recompute it whenever the content changes.
        shapeObservation = model.objectWillChange.sink { [weak self] in self?.refreshShadow() }
        return panel
    }

    private func layout(animatedEntry: Bool) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        // The card sits 12 pt from the right edge and 8 pt under the menu bar, like a notification.
        let target = NSRect(x: visible.maxX - size.width - 12 + HUD.inset, y: visible.maxY - size.height - 8 + HUD.inset,
                            width: size.width, height: size.height)
        if animatedEntry && !panel.isVisible {
            // Enters from the right edge and leaves the same way.
            let start = Motion.reduceMotion ? target : target.offsetBy(dx: 28, dy: 0)
            panel.setFrame(start, display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.reduceMotion ? 0.15 : 0.32
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.setFrame(target, display: true)
            if !panel.isVisible { panel.alphaValue = 1; panel.orderFrontRegardless() }
        }
        panel.invalidateShadow()
    }

    private func refreshShadow() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, let hosting = self.hosting, panel.isVisible else { return }
            hosting.layoutSubtreeIfNeeded()
            let size = hosting.fittingSize
            if abs(size.height - panel.frame.height) > 0.5 {
                var frame = panel.frame
                frame.origin.y += frame.height - size.height
                frame.size = size
                panel.setFrame(frame, display: true)
            }
            panel.invalidateShadow()
        }
    }

    /// Updates the model without putting a panel on screen (used by the test runner).
    var isHeadless = false

    private func present(autoHide: TimeInterval?) {
        guard !isHeadless else { return }
        let entering = !(panel?.isVisible ?? false)
        layout(animatedEntry: entering)
        autoHideDelay = autoHide
        scheduleHide()
    }

    private func scheduleHide() {
        hideWork?.cancel()
        guard let delay = autoHideDelay, !model.hovering else { return }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        guard let panel, panel.isVisible else { return }
        let exit = Motion.reduceMotion ? panel.frame : panel.frame.offsetBy(dx: 28, dy: 0)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Motion.reduceMotion ? 0.15 : 0.22
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
            panel.animator().setFrame(exit, display: true)
            panel.animator().alphaValue = 0
        }) {
            panel.orderOut(nil)
        }
    }

    // MARK: States

    func showProgress(title: String, item: String, index: Int, count: Int, jobID: UUID? = nil) {
        model.jobID = jobID
        model.undoJob = nil
        model.state = .progress
        model.title = title
        model.detail = count > 1 ? L("%@ of %@ · %@", index + 1, count, item) : item
        model.fraction = Double(index) / Double(max(count, 1))
        model.outputs = []
        model.failures = []
        present(autoHide: nil)
    }

    func updateProgress(_ fraction: Double, detail: String? = nil) {
        guard model.state == .progress else { return }
        model.fraction = fraction
        if let detail { model.detail = detail }
    }

    func showDone(outputs: [URL], message: String, failures: [JobFailure] = [], total: Int = 1, notes: [String] = [],
                  jobID: UUID? = nil) {
        model.jobID = nil
        model.undoJob = outputs.isEmpty ? nil : jobID
        model.outputs = outputs
        model.failures = failures
        model.fraction = nil
        model.title = message
        if failures.isEmpty {
            model.state = .success
            if outputs.count == 1, let first = outputs.first {
                model.detail = L("“%@” is next to the original.", first.lastPathComponent)
            } else {
                model.detail = outputs.isEmpty ? "" : L("The results are next to the originals.")
            }
            // What the new format couldn't keep is said plainly, never dropped in silence.
            if !notes.isEmpty {
                model.state = .warning
                model.detail = ([model.detail] + notes).filter { !$0.isEmpty }.joined(separator: "\n")
            }
            present(autoHide: notes.isEmpty ? 5 : 12)
            Sounds.success()
        } else {
            model.state = failures.count >= total ? .failure : .warning
            let first = failures[0]
            var detail = total > 1 ? "\(first.file): \(first.error.message)" : first.error.message
            if let suggestion = first.error.suggestion, total == 1 { detail += "\n" + suggestion }
            if failures.count > 1 { detail += L("\n…and %@ more with problems.", failures.count - 1) }
            model.detail = detail
            present(autoHide: 14)
            Sounds.failure()
        }
    }

    func showMessage(_ message: String, detail: String = "", isError: Bool = false) {
        model.jobID = nil
        model.undoJob = nil
        model.state = isError ? .failure : .info
        model.title = message
        model.detail = detail
        model.fraction = nil
        model.outputs = []
        model.failures = []
        present(autoHide: isError ? 12 : (detail.isEmpty ? 2.5 : 6))
        if isError { Sounds.failure() }
    }

    /// An explained error: the reason as the title, what to do underneath.
    func showError(_ error: Problem, title: String? = nil) {
        model.undoJob = nil
        model.state = .failure
        model.title = title ?? error.message
        model.detail = title == nil ? (error.suggestion ?? "") : error.fullText
        model.fraction = nil
        model.outputs = []
        model.failures = error.technical == nil ? [] : [JobFailure(file: "", error: error)]
        present(autoHide: 12)
        Sounds.failure()
    }

    /// Something isn't possible (not an engine failure): a warning, without the error sound.
    func showNotice(_ error: Problem) {
        model.undoJob = nil
        model.state = .warning
        model.title = error.message
        model.detail = error.suggestion ?? ""
        model.fraction = nil
        model.outputs = []
        model.failures = []
        present(autoHide: 8)
    }

    // MARK: Actions

    private func showResultsInFinder() {
        if !model.outputs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(model.outputs) }
        hide()
    }

    private func showActivity() {
        hide()
        (NSApp.delegate as? AppDelegate)?.showSettings(tab: .activity)
    }

    private func cancelJob() {
        if let id = model.jobID { ActivityLog.shared.cancel(id) }
    }

    private func undoJob() {
        guard let id = model.undoJob else { return }
        let failures = ActivityLog.shared.undo(id)
        if failures.isEmpty {
            showMessage(L("Moved to the Trash"), detail: L("Finder’s “Put Back” restores the files if you need them again."))
        } else {
            hide()
            FailureReport.show(failures)
        }
    }

    private func openOutputs() {
        model.outputs.prefix(5).forEach { NSWorkspace.shared.open($0) }
        hide()
    }

    private func showDetails() {
        let failures = model.failures
        guard !failures.isEmpty else { return }
        hide()
        FailureReport.show(failures)
    }
}

/// The explained list of failures, with the technical details and a "Copy Report" button.
enum FailureReport {
    static func show(_ failures: [JobFailure]) {
        guard !failures.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        let named = failures.filter { !$0.file.isEmpty }
        alert.messageText = named.count > 1 ? L("%@ files weren’t processed", String(named.count))
            : (named.first.map { L("Couldn’t process “%@”", $0.file) } ?? failures[0].error.message)
        alert.informativeText = failures.count == 1 ? failures[0].error.fullText : L("Each file has the explanation and what you can do.")
        let report = text(failures)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 200))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let view = NSTextView(frame: scroll.bounds)
        view.isEditable = false
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.string = report
        view.textContainerInset = NSSize(width: 6, height: 6)
        scroll.documentView = view
        alert.accessoryView = scroll
        alert.addButton(withTitle: L("OK"))
        alert.addButton(withTitle: L("Copy Report"))
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
        }
    }

    static func text(_ failures: [JobFailure]) -> String {
        var report = ""
        for failure in failures {
            if !failure.file.isEmpty { report += "• \(failure.file)\n" }
            report += "  \(failure.error.message)\n"
            if let suggestion = failure.error.suggestion { report += "  " + L("What to do: %@", suggestion) + "\n" }
            if let technical = failure.error.technical {
                report += "  " + L("Technical details:") + "\n" + technical.split(separator: "\n").map { "    \($0)" }.joined(separator: "\n") + "\n"
            }
            report += "\n"
        }
        return report
    }
}

// MARK: - View

struct HUDView: View {
    @ObservedObject var model: HUDModel
    @ObservedObject var look = LookStore.shared
    var reveal: () -> Void
    var open: () -> Void
    var details: () -> Void
    var activity: () -> Void
    var cancel: () -> Void
    var undo: () -> Void
    var close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusGlyph(state: model.state, fraction: model.fraction)
                .frame(width: 30, height: 30)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.detail.isEmpty {
                    Text(model.detail)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.state == .progress {
                    HStack(spacing: 8) {
                        if model.jobID != nil {
                            Button(L("Cancel"), action: cancel).buttonStyle(SecondaryButtonStyle())
                        }
                        Button(L("Show Activity"), action: activity).buttonStyle(SecondaryButtonStyle())
                    }
                    .controlSize(.small)
                    .padding(.top, 6)
                } else if hasActions {
                    // Narrower languages get every button; otherwise "Open" gives way first.
                    ViewThatFits(in: .horizontal) {
                        resultButtons(includeOpen: true)
                        resultButtons(includeOpen: false)
                    }
                    .controlSize(.small)
                    .padding(.top, 6)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 344, alignment: .leading)
        .background(VisualEffect(material: .popover, cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.primary.opacity(Motion.increaseContrast ? 0.4 : 0.1), lineWidth: Motion.increaseContrast ? 1 : 0.5))
        .overlay(alignment: .topLeading) {
            if model.hovering && model.state != .progress {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.regularMaterial))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .offset(x: -6, y: -6)
                .transition(.opacity)
                .iconLabel(L("Close"))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if model.state == .success || (model.state == .warning && model.failures.isEmpty) { reveal() } }
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { model.hovering = hovering } }
        .padding(HUD.inset)
        .animation(Motion.standard, value: model.state)
        .themed()
    }

    private var hasActions: Bool {
        model.state != .progress && (!model.outputs.isEmpty || !model.failures.isEmpty)
    }

    private func resultButtons(includeOpen: Bool) -> some View {
        HStack(spacing: 8) {
            if !model.failures.isEmpty {
                Button(L("Details…"), action: details).buttonStyle(SecondaryButtonStyle())
            }
            if !model.outputs.isEmpty {
                Button(L("Show in Finder"), action: reveal).buttonStyle(SecondaryButtonStyle())
                if includeOpen && model.outputs.count == 1 && model.failures.isEmpty {
                    Button(L("Open"), action: open).buttonStyle(SecondaryButtonStyle())
                }
            }
            if model.undoJob != nil {
                Button(L("Undo"), action: undo).buttonStyle(SecondaryButtonStyle())
                    .help(L("Move the new files to the Trash"))
            }
        }
        .fixedSize()
    }
}

/// Progress ring while working; a symbol for the outcome.
struct StatusGlyph: View {
    let state: HUDModel.State
    let fraction: Double?
    @ObservedObject var look = LookStore.shared

    var body: some View {
        ZStack {
            switch state {
            case .progress:
                if let fraction {
                    Circle().stroke(Color.primary.opacity(0.12), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: max(0.02, fraction))
                        .stroke(look.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.25), value: fraction)
                    Text("\(Int(fraction * 100))")
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundColor(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            case .success:
                symbol("checkmark.circle.fill", color: look.accent)
            case .warning:
                symbol("exclamationmark.triangle.fill", color: .primary)
            case .failure:
                symbol("xmark.octagon.fill", color: .primary)
            case .info:
                symbol("info.circle.fill", color: look.accent)
            }
        }
    }

    private func symbol(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 24, weight: .regular))
            .foregroundStyle(color)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
    }
}
