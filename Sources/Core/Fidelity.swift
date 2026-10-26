import Foundation

/// What a conversion could not carry over, told to the user instead of dropped in silence.
/// Converters call `note(_:)` while they work, on the thread running the job; the job runner
/// collects the notes of each file and shows them with the result and in the activity list.
enum Fidelity {
    private static var notes: [String: [String]] = [:]
    private static let lock = NSLock()

    static func collect<T>(_ body: () throws -> T) rethrows -> (result: T, notes: [String]) {
        let key = Thread.current.description
        lock.lock(); let outer = notes[key]; notes[key] = []; lock.unlock()
        defer { lock.lock(); notes[key] = outer; lock.unlock() }
        let result = try body()
        lock.lock(); let collected = notes[key] ?? []; lock.unlock()
        return (result, collected)
    }

    /// Records one limitation of the target format, once per file.
    static func note(_ text: String) {
        let key = Thread.current.description
        lock.lock()
        defer { lock.unlock() }
        guard var list = notes[key] else { return }
        if !list.contains(text) { list.append(text) }
        notes[key] = list
    }
}
