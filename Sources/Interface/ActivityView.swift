import AppKit
import SwiftUI

/// Settings › Activity: what is waiting or running right now (with progress and a way to
/// cancel), and how every job of this session ended. Notifications can be dismissed; this stays.
struct ActivityView: View {
    @ObservedObject var log = ActivityLog.shared

    var body: some View {
        Form {
            Section {
                if log.active.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle").font(.system(size: 18)).foregroundColor(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Nothing running")).font(.system(size: 13, weight: .medium))
                            Text(L("When you drop files on a wheel, the work shows here until it finishes."))
                                .font(.system(size: 11)).foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(log.active) { entry in
                        ActiveRow(entry: entry) { log.cancel(entry.id) }
                    }
                }
            } header: {
                Text(log.active.isEmpty ? L("Running") : L("Running (%@)", String(log.active.count)))
            }

            Section {
                if log.finished.isEmpty {
                    Text(L("No work has finished since Split opened."))
                        .font(.system(size: 12)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(log.finished) { entry in
                        FinishedRow(entry: entry) { undo(entry) }
                    }
                }
            } header: {
                HStack {
                    Text(L("Finished"))
                    Spacer()
                    if !log.finished.isEmpty {
                        Button(L("Clear")) { withAnimation(Motion.standard) { log.clearFinished() } }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11))
                    }
                }
            } footer: {
                Text(L("The list covers this session and empties when Split quits. New files are always saved next to the originals."))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }

    private func undo(_ entry: ActivityLog.Entry) {
        let failures = log.undo(entry.id)
        if !failures.isEmpty { FailureReport.show(failures) }
    }
}

private struct ActiveRow: View {
    let entry: ActivityLog.Entry
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(ActivityFormat.status(entry, now: context.date))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(.secondary)
                }
                Button(L("Cancel"), action: cancel)
                    .buttonStyle(SecondaryButtonStyle())
                    .controlSize(.small)
                    .disabled(entry.cancelRequested)
            }
            if entry.state == .running {
                ProgressView(value: entry.fraction ?? 0)
                    .progressViewStyle(.linear)
            }
            Text(entry.detail.isEmpty ? ActivityFormat.files(entry.files) : entry.detail)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 3)
    }
}

private struct FinishedRow: View {
    let entry: ActivityLog.Entry
    let undo: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(entry.state == .succeeded ? Color(nsColor: Palette.accent) : Color.secondary)
                .frame(width: 20)
                .accessibilityLabel(ActivityFormat.stateName(entry.state))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.summary).font(.system(size: 12.5, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Text(ActivityFormat.files(entry.files) + " · " + ActivityFormat.when(entry))
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                ForEach(entry.notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if entry.undone {
                    Label(L("Undone: the new files are in the Trash."), systemImage: "trash")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                if let first = entry.failures.first, entry.state != .cancelled {
                    Text(first.error.message)
                        .font(.system(size: 11)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if !entry.failures.isEmpty {
                    Button(L("Details…")) { FailureReport.show(entry.failures) }
                }
                let existing = entry.outputs.filter { FileManager.default.fileExists(atPath: $0.path) }
                if !existing.isEmpty {
                    Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting(existing) }
                }
                if !ActivityLog.undoable(entry).isEmpty {
                    Button(L("Undo"), action: undo)
                        .help(L("Move the new files to the Trash"))
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch entry.state {
        case .succeeded: return "checkmark.circle.fill"
        case .partial: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "stop.circle"
        case .queued, .running: return "clock"
        }
    }
}

/// Text pieces shared by the activity rows (and checked by the tests).
enum ActivityFormat {
    static func files(_ urls: [URL]) -> String {
        guard let first = urls.first else { return L("No files") }
        return urls.count == 1 ? first.lastPathComponent : L("%@ and %@ more", first.lastPathComponent, String(urls.count - 1))
    }

    static func status(_ entry: ActivityLog.Entry, now: Date) -> String {
        switch entry.state {
        case .queued:
            return L("Waiting")
        case .running where entry.cancelRequested:
            return L("Canceling…")
        case .running:
            let percent = Int(((entry.fraction ?? 0) * 100).rounded())
            return L("%@ · %@", "\(percent)%", duration(now.timeIntervalSince(entry.startedAt ?? now)))
        default:
            return stateName(entry.state)
        }
    }

    static func stateName(_ state: ActivityLog.State) -> String {
        switch state {
        case .queued: return L("Waiting")
        case .running: return L("Running")
        case .succeeded: return L("Done")
        case .partial: return L("Done with problems")
        case .failed: return L("Failed")
        case .cancelled: return L("Canceled")
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        var calendar = Calendar.current
        calendar.locale = Localizer.shared.locale
        formatter.calendar = calendar
        return formatter.string(from: max(0, seconds)) ?? ""
    }

    static func when(_ entry: ActivityLog.Entry) -> String {
        let end = entry.finishedAt ?? Date()
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Localizer.shared.locale
        formatter.unitsStyle = .full
        var text = formatter.localizedString(for: end, relativeTo: Date())
        if let start = entry.startedAt {
            text += " · " + L("took %@", duration(end.timeIntervalSince(start)))
        }
        return text
    }
}
