import AppKit

// MARK: - External engines

enum Engines {
    // Homebrew first (Apple Silicon, then Intel), then the system and LibreOffice.
    static let searchDirectories = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin",
        "/Applications/LibreOffice.app/Contents/MacOS",
    ]

    private static var cache: [String: String] = [:]
    private static let lock = NSLock()

    static func path(_ name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[name] { return cached }
        let found = searchDirectories
            .map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        if let found { cache[name] = found }
        return found
    }

    /// What each engine is for, as the subject of "… needs the program".
    private static func purpose(_ name: String) -> String {
        switch name {
        case "ffmpeg": return L("Converting and editing audio and video")
        case "ffprobe": return L("Reading audio and video files")
        case "cwebp": return L("Creating WebP images")
        case "gif2webp", "img2webp": return L("Creating animated WebP images")
        case "cjxl": return L("Creating JPEG XL images")
        case "djxl": return L("Reading JPEG XL images")
        case "exiftool": return L("Removing image metadata")
        default: return L("This operation")
        }
    }

    static func require(_ name: String, brew: String? = nil) throws -> String {
        if let path = path(name) { return path }
        let package = brew ?? name
        let install = path("brew") == nil
            ? L("Install Homebrew first (brew.sh), then run: brew install %@", package)
            : L("Install it in Terminal with: brew install %@. There’s no need to reopen Split.", package)
        throw Problem(L("%@ needs the program “%@”, which isn’t installed.", purpose(name), name), suggestion: install)
    }

    /// The programs Homebrew provides, with the package each comes in.
    static let homebrewPackages: [(program: String, package: String)] = [
        ("ffmpeg", "ffmpeg"), ("cwebp", "webp"), ("cjxl", "jpeg-xl"), ("exiftool", "exiftool"),
    ]

    /// One command that installs every missing program, or nil when nothing is missing.
    static var missingPackagesCommand: String? {
        let missing = homebrewPackages.filter { path($0.program) == nil }.map(\.package)
        return missing.isEmpty ? nil : "brew install " + missing.joined(separator: " ")
    }

    static func appInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static var pages: Bool { appInstalled("com.apple.iWork.Pages") }
    static var numbers: Bool { appInstalled("com.apple.iWork.Numbers") }
    static var keynote: Bool { appInstalled("com.apple.iWork.Keynote") }
    static var word: Bool { appInstalled("com.microsoft.Word") }
    static var excel: Bool { appInstalled("com.microsoft.Excel") }
    static var powerPoint: Bool { appInstalled("com.microsoft.Powerpoint") }
    static var soffice: String? { path("soffice") }
}

// MARK: - Processes

struct ProcessResult {
    let status: Int32
    let stdoutData: Data
    let stderr: String
    var stdout: String { String(decoding: stdoutData, as: UTF8.self) }
}

@discardableResult
func runProcess(_ executable: String, _ arguments: [String], cwd: URL? = nil, timeout: TimeInterval = 3600,
                monitor: (() -> Void)? = nil) throws -> ProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let cwd { process.currentDirectoryURL = cwd }
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    environment["LANG"] = "en_US.UTF-8"
    environment["LC_ALL"] = "en_US.UTF-8"
    process.environment = environment

    // Files instead of pipes: no deadlock when a tool writes a lot to stderr.
    let temp = FileManager.default.temporaryDirectory
    let outURL = temp.appendingPathComponent("split-\(UUID().uuidString).out")
    let errURL = temp.appendingPathComponent("split-\(UUID().uuidString).err")
    FileManager.default.createFile(atPath: outURL.path, contents: nil)
    FileManager.default.createFile(atPath: errURL.path, contents: nil)
    defer {
        try? FileManager.default.removeItem(at: outURL)
        try? FileManager.default.removeItem(at: errURL)
    }
    let outHandle = try FileHandle(forWritingTo: outURL)
    let errHandle = try FileHandle(forWritingTo: errURL)
    process.standardOutput = outHandle
    process.standardError = errHandle
    process.standardInput = FileHandle.nullDevice

    try process.run()
    let deadline = Date().addingTimeInterval(timeout)
    var lastMonitor = Date()
    while process.isRunning {
        if JobProgress.isCancelled {
            process.terminate()
            process.waitUntilExit()
            throw Problem.cancelled
        }
        if Date() > deadline {
            process.terminate()
            throw Problem(L("%@ took more than %@ minutes and was stopped.", URL(fileURLWithPath: executable).lastPathComponent, Int(timeout / 60)),
                          suggestion: L("Very long files take time. Choose the “Compact” quality or trim the file first."))
        }
        if let monitor, Date().timeIntervalSince(lastMonitor) > 0.25 {
            lastMonitor = Date()
            monitor()
        }
        usleep(20_000)
    }
    try? outHandle.close()
    try? errHandle.close()
    let out = (try? Data(contentsOf: outURL)) ?? Data()
    let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
    return ProcessResult(status: process.terminationStatus, stdoutData: out, stderr: err)
}

@discardableResult
func runChecked(_ executable: String, _ arguments: [String], cwd: URL? = nil, what: String, app: String = "",
                monitor: (() -> Void)? = nil) throws -> ProcessResult {
    let result = try runProcess(executable, arguments, cwd: cwd, monitor: monitor)
    guard result.status == 0 else {
        throw Explain.toolFailure(what: what, tool: URL(fileURLWithPath: executable).lastPathComponent,
                                  stderr: result.stderr + "\n" + result.stdout.suffix(400), status: result.status, app: app)
    }
    return result
}

/// Progress and cancellation of the job running on the current thread. Engines report
/// progress and check for cancellation without knowing which job (or test) runs them.
enum JobProgress {
    private struct Context {
        let report: (Double) -> Void
        let token: CancelToken?
    }

    private static var contexts: [String: Context] = [:]
    private static let lock = NSLock()

    static func run<T>(_ handler: @escaping (Double) -> Void, cancel token: CancelToken? = nil, _ body: () throws -> T) rethrows -> T {
        let key = Thread.current.description
        lock.lock(); contexts[key] = Context(report: handler, token: token); lock.unlock()
        defer { lock.lock(); contexts[key] = nil; lock.unlock() }
        return try body()
    }

    private static var current: Context? {
        lock.lock()
        defer { lock.unlock() }
        return contexts[Thread.current.description]
    }

    static func report(_ fraction: Double) {
        current?.report(min(max(fraction, 0), 1))
    }

    static var isCancelled: Bool { current?.token?.isCancelled ?? false }

    /// Long in-process work (page loops, frame loops) calls this between steps.
    static func checkCancelled() throws {
        if isCancelled { throw Problem.cancelled }
    }
}

/// AppKit text APIs (HTML import, printing) must run on the main thread.
func onMain<T>(_ body: () throws -> T) rethrows -> T {
    if Thread.isMainThread { return try body() }
    return try DispatchQueue.main.sync(execute: body)
}
