import Foundation

/// Set by the user from the Activity tab; read by the job's thread between steps.
final class CancelToken {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Everything the app was asked to do since it opened: what is waiting, what is running
/// (with progress) and how each job ended. Notifications come and go; this list stays,
/// in Settings › Activity. Only touched on the main thread.
final class ActivityLog: ObservableObject {
    static let shared = ActivityLog()
    static let historyLimit = 100
    /// How "Undo" disposes of a result; the tests swap it so they never fill the real Trash.
    static var moveToTrash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    enum State: Equatable {
        case queued, running, succeeded, partial, failed, cancelled

        var isActive: Bool { self == .queued || self == .running }
    }

    struct Entry: Identifiable {
        let id: UUID
        let title: String
        let files: [URL]
        let queuedAt: Date
        var startedAt: Date?
        var finishedAt: Date?
        var state: State = .queued
        var fraction: Double?
        var detail = ""
        var summary = ""
        var outputs: [URL] = []
        var failures: [JobFailure] = []
        /// What the target formats could not keep (see `Fidelity`).
        var notes: [String] = []
        var cancelRequested = false
        /// The results were moved to the Trash with "Undo".
        var undone = false
        let token: CancelToken
    }

    @Published private(set) var entries: [Entry] = []

    var active: [Entry] { entries.filter { $0.state.isActive } }
    var finished: [Entry] { entries.filter { !$0.state.isActive } }

    @discardableResult
    func add(id: UUID = UUID(), title: String, files: [URL], token: CancelToken) -> UUID {
        entries.insert(Entry(id: id, title: title, files: files, queuedAt: Date(), token: token), at: 0)
        trim()
        return id
    }

    func start(_ id: UUID) {
        update(id) {
            $0.state = .running
            $0.startedAt = Date()
            $0.fraction = 0
        }
    }

    func progress(_ id: UUID, fraction: Double, detail: String? = nil) {
        update(id) {
            guard $0.state == .running else { return }
            $0.fraction = fraction
            if let detail { $0.detail = detail }
        }
    }

    func finish(_ id: UUID, state: State, summary: String, outputs: [URL] = [], failures: [JobFailure] = [], notes: [String] = []) {
        update(id) {
            $0.state = state
            $0.finishedAt = Date()
            $0.fraction = nil
            $0.detail = ""
            $0.summary = summary
            $0.outputs = outputs
            $0.failures = failures
            $0.notes = notes
        }
    }

    /// Queued jobs stop before they start; running ones stop at the next safe point
    /// (the engine process is ended and its partial output removed).
    func cancel(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }), entry.state.isActive else { return }
        entry.token.cancel()
        update(id) { $0.cancelRequested = true }
        if entry.state == .queued {
            finish(id, state: .cancelled, summary: L("Canceled before it started."))
        }
    }

    /// What "Undo" would move to the Trash: the job's results that are still there, never one
    /// of the files the job started from (nor a folder holding one).
    static func undoable(_ entry: Entry) -> [URL] {
        guard !entry.undone, !entry.state.isActive else { return [] }
        let sources = entry.files.map { $0.standardizedFileURL.path }
        return entry.outputs.filter { output in
            let path = output.standardizedFileURL.path
            return FileManager.default.fileExists(atPath: path) && !sources.contains { $0 == path || $0.hasPrefix(path + "/") }
        }
    }

    /// Takes a job back by moving its results to the Trash, where Finder's "Put Back" can
    /// still restore them. Returns what could not be moved.
    func undo(_ id: UUID) -> [JobFailure] {
        guard let entry = entry(id) else { return [] }
        var failures: [JobFailure] = []
        for url in ActivityLog.undoable(entry) {
            do {
                try ActivityLog.moveToTrash(url)
            } catch {
                failures.append(JobFailure(file: url.lastPathComponent, error: Explain.error(error, file: url)))
            }
        }
        if failures.isEmpty { update(id) { $0.undone = true } }
        return failures
    }

    func clearFinished() {
        entries.removeAll { !$0.state.isActive }
    }

    func entry(_ id: UUID) -> Entry? { entries.first { $0.id == id } }

    private func update(_ id: UUID, _ change: (inout Entry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
    }

    private func trim() {
        let finished = entries.indices.filter { !entries[$0].state.isActive }
        guard finished.count > ActivityLog.historyLimit else { return }
        let drop = Set(finished.dropFirst(ActivityLog.historyLimit))
        entries = entries.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }
}
