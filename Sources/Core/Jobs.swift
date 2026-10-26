import AppKit

/// Runs work off the main thread, several files at a time when that's safe. Every job is
/// listed in the activity log from the moment it is asked for, and reported through the HUD.
final class JobRunner {
    static let shared = JobRunner()

    /// One job at a time; files inside a job may run in parallel.
    private let queue = DispatchQueue(label: "split.jobs", qos: .userInitiated)

    func convert(_ urls: [URL], to target: Format) {
        let sources = Set(urls.compactMap(Format.detect))
        each(title: L("Converting to %@…", target.label), verb: (L("1 file converted"), L("%@ files converted")), urls: urls,
             width: parallelism(sources: sources, target: target)) { try Conversions.convert($0, to: target) }
    }

    func tool(_ tool: QuickTool, _ urls: [URL], targetBytes: Int? = nil) {
        if tool.isBatch || tool == .readQR {
            single(title: tool.title + "…", item: urls.count == 1 ? urls[0].lastPathComponent : L("%@ files", urls.count), files: urls) {
                let result = try tool.run(urls)
                if tool == .readQR, let text = result.message {
                    DispatchQueue.main.async {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        HUD.shared.showMessage(L("Code text copied"), detail: text)
                    }
                    return nil
                }
                return result.outputs
            }
            return
        }
        let sources = Set(urls.compactMap(Format.detect))
        each(title: tool.title + "…", verb: (L("1 file processed"), L("%@ files processed")), urls: urls,
             width: parallelism(sources: sources, target: nil)) { try tool.run([$0], targetBytes: targetBytes).outputs }
    }

    /// One unit of work with one result (editors saving, batch tools).
    /// Returning nil means the work already reported its own outcome.
    func single(title: String, item: String, files: [URL] = [], work: @escaping () throws -> [URL]?) {
        let (id, token) = enqueue(title: title, files: files)
        queue.async {
            guard self.begin(id, token: token, title: title, item: item, count: 1) else { return }
            let name = JobRunner.plain(title)
            do {
                for file in files { try FileCheck.preflight(file, allowFolders: true) }
                let (outputs, notes) = try JobProgress.run({ fraction in
                    DispatchQueue.main.async {
                        HUD.shared.updateProgress(fraction)
                        ActivityLog.shared.progress(id, fraction: fraction)
                    }
                }, cancel: token) { try Fidelity.collect(work) }
                OfficeBridge.quitLaunchedApps()
                DispatchQueue.main.async {
                    let message = L("%@ — done", name)
                    ActivityLog.shared.finish(id, state: .succeeded, summary: message, outputs: outputs ?? [], notes: notes)
                    if let outputs { HUD.shared.showDone(outputs: outputs, message: message, notes: notes, jobID: id) }
                }
            } catch {
                OfficeBridge.quitLaunchedApps()
                let explained = Explain.error(error, file: files.count == 1 ? files[0] : nil)
                let failure = JobFailure(file: files.count == 1 ? files[0].lastPathComponent : "", error: explained)
                DispatchQueue.main.async {
                    if explained.isCancellation {
                        ActivityLog.shared.finish(id, state: .cancelled, summary: L("%@ — canceled", name))
                        HUD.shared.showMessage(L("Canceled"), detail: name)
                        return
                    }
                    let message = L("Couldn’t finish: %@", name)
                    ActivityLog.shared.finish(id, state: .failed, summary: message, failures: [failure])
                    HUD.shared.showDone(outputs: [], message: message, failures: [failure])
                }
            }
        }
    }

    /// Images and documents are CPU-light per file: run a few at once. ffmpeg already uses
    /// every core, and Office apps can only handle one document at a time.
    private func parallelism(sources: Set<Format>, target: Format?) -> Int {
        let usesOfficeApps = sources.contains { [.presentation, .spreadsheet].contains($0.group) || [.pages, .doc, .docx, .odt].contains($0) }
            || target == .pages
        if usesOfficeApps { return 1 }
        let media = sources.contains { [.audio, .video].contains($0.group) } || target?.group == .video
        if media { return 2 }
        return max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

    /// "1 file converted" / "3 files converted": `verb` holds both translated forms, the
    /// second with a placeholder for the count (or for "2 of 3").
    static func phrase(_ count: Int, _ verb: (one: String, many: String)) -> String {
        count == 1 ? verb.one : fill(verb.many, [count])
    }

    /// Per-file work with a shared progress banner and an explained list of failures.
    func each(title: String, verb: (one: String, many: String), urls: [URL], width: Int, work: @escaping (URL) throws -> [URL]) {
        let (id, token) = enqueue(title: title, files: urls)
        queue.async {
            guard self.begin(id, token: token, title: title, item: urls.first?.lastPathComponent ?? "", count: urls.count) else { return }
            let lock = NSLock()
            var outputs: [[URL]] = Array(repeating: [], count: urls.count)
            var notes: [String] = []
            var failures: [Int: JobFailure] = [:]
            var fractions = Array(repeating: 0.0, count: urls.count)
            var finished = 0
            var skipped = 0
            var lastUpdate = Date.distantPast

            func publish(current: String?) {
                let overall = fractions.reduce(0, +) / Double(max(urls.count, 1))
                let now = Date()
                guard now.timeIntervalSince(lastUpdate) > 0.1 || current != nil else { return }
                lastUpdate = now
                let detail = urls.count > 1 ? L("%@ of %@ done", finished, urls.count) + (current.map { " · \($0)" } ?? "") : current
                DispatchQueue.main.async {
                    HUD.shared.updateProgress(overall, detail: detail)
                    ActivityLog.shared.progress(id, fraction: overall, detail: detail)
                }
            }

            let next = NSLock()
            var cursor = 0
            DispatchQueue.concurrentPerform(iterations: min(width, urls.count)) { _ in
                while true {
                    next.lock()
                    let index = cursor
                    cursor += 1
                    next.unlock()
                    guard index < urls.count else { return }
                    // Cancelling stops new files from starting; the ones running stop at their next check.
                    if token.isCancelled {
                        lock.lock(); skipped += 1; lock.unlock()
                        continue
                    }
                    let url = urls[index]
                    lock.lock(); publish(current: url.lastPathComponent); lock.unlock()
                    do {
                        let (result, fileNotes) = try JobProgress.run({ fraction in
                            lock.lock()
                            fractions[index] = fraction
                            publish(current: nil)
                            lock.unlock()
                        }, cancel: token) { try Fidelity.collect { try work(url) } }
                        lock.lock()
                        outputs[index] = result
                        for note in fileNotes where !notes.contains(note) { notes.append(note) }
                        lock.unlock()
                    } catch {
                        let explained = Explain.error(error, file: url)
                        lock.lock()
                        if explained.isCancellation { skipped += 1 } else { failures[index] = JobFailure(file: url.lastPathComponent, error: explained) }
                        lock.unlock()
                    }
                    lock.lock()
                    fractions[index] = 1
                    finished += 1
                    publish(current: nil)
                    lock.unlock()
                }
            }
            OfficeBridge.quitLaunchedApps()
            let ordered = failures.keys.sorted().compactMap { failures[$0] }
            let produced = outputs.flatMap { $0 }
            DispatchQueue.main.async {
                let ok = urls.count - ordered.count - skipped
                if skipped > 0 {
                    let message = ok == 0 ? L("Canceled") : L("Canceled after %@", JobRunner.phrase(ok, verb))
                    ActivityLog.shared.finish(id, state: .cancelled, summary: message, outputs: produced, failures: ordered)
                    HUD.shared.showMessage(message, detail: JobRunner.plain(title))
                    return
                }
                let message: String
                if ordered.isEmpty {
                    message = JobRunner.phrase(ok, verb)
                } else if ok == 0 {
                    message = urls.count == 1 ? L("Couldn’t process “%@”", urls[0].lastPathComponent) : L("No file was processed")
                } else {
                    message = fill(verb.many, [L("%@ of %@", ok, urls.count)])
                }
                let state: ActivityLog.State = ordered.isEmpty ? .succeeded : (ok == 0 ? .failed : .partial)
                ActivityLog.shared.finish(id, state: state, summary: message, outputs: produced, failures: ordered, notes: notes)
                HUD.shared.showDone(outputs: produced, message: message, failures: ordered, total: urls.count, notes: notes, jobID: id)
            }
        }
    }

    // MARK: Activity bookkeeping

    /// Lists the job as waiting straight away, so it is visible even before it starts.
    private func enqueue(title: String, files: [URL]) -> (UUID, CancelToken) {
        let id = UUID()
        let token = CancelToken()
        let register = { _ = ActivityLog.shared.add(id: id, title: JobRunner.plain(title), files: files, token: token) }
        if Thread.isMainThread { register() } else { DispatchQueue.main.sync(execute: register) }
        return (id, token)
    }

    /// Marks the job as running, unless it was cancelled while it waited.
    private func begin(_ id: UUID, token: CancelToken, title: String, item: String, count: Int) -> Bool {
        guard !token.isCancelled else { return false }
        DispatchQueue.main.async {
            ActivityLog.shared.start(id)
            HUD.shared.showProgress(title: title, item: item, index: 0, count: count, jobID: id)
        }
        return true
    }

    /// "Converting to MP4…" → "Converting to MP4".
    static func plain(_ title: String) -> String {
        title.hasSuffix("…") ? String(title.dropLast()) : title
    }
}
