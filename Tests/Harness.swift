import AppKit
import CryptoKit
import ImageIO
import PDFKit

// A small test harness: the Command Line Tools ship no XCTest, so the app's sources are
// compiled together with these files into one test binary (see Tests/run.sh).

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct TestCase {
    let suite: String
    let name: String
    let body: () throws -> Void
}

enum Registry {
    static var tests: [TestCase] = []
    static var checks = 0
    static var failures: [String] = []
}

func test(_ suite: String, _ name: String, _ body: @escaping () throws -> Void) {
    Registry.tests.append(TestCase(suite: suite, name: name, body: body))
}

/// Records a failure but lets the test continue (so one run shows every problem).
func check(_ condition: Bool, _ message: @autoclosure () -> String, line: UInt = #line, file: StaticString = #fileID) {
    Registry.checks += 1
    if !condition { Registry.failures.append("\(message())  [\(file):\(line)]") }
}

/// Stops the test: later steps depend on this one.
func require(_ condition: Bool, _ message: @autoclosure () -> String, line: UInt = #line, file: StaticString = #fileID) throws {
    Registry.checks += 1
    if !condition { throw TestFailure("\(message())  [\(file):\(line)]") }
}

func near(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool { abs(a - b) <= tolerance }

/// The body must throw an explained error mentioning every fragment (case-insensitive).
@discardableResult
func expectError(_ label: String, contains fragments: [String], line: UInt = #line, _ body: () throws -> Void) -> Problem? {
    Registry.checks += 1
    do {
        try body()
        Registry.failures.append("\(label): should have failed with an explained error, but it worked  [line \(line)]")
        return nil
    } catch {
        let explained = Explain.error(error)
        let text = (explained.fullText + " " + (explained.technical ?? "")).lowercased()
        let missing = fragments.filter { !text.contains($0.lowercased()) }
        if !missing.isEmpty {
            Registry.failures.append("\(label): the message doesn’t mention \(missing) → “\(explained.fullText)”  [line \(line)]")
        }
        ErrorLog.seen.append(explained)
        return explained
    }
}

enum ErrorLog {
    static var seen: [Problem] = []
}

// MARK: - Inspecting outputs

enum Probe {
    static func json(_ url: URL) -> [String: Any] {
        guard let ffprobe = Engines.path("ffprobe"), let result = try? runProcess(ffprobe, ["-v", "error", "-show_streams", "-show_format", "-of", "json", url.path]),
              let json = try? JSONSerialization.jsonObject(with: result.stdoutData) as? [String: Any] else { return [:] }
        return json
    }

    static func streams(_ url: URL) -> [[String: Any]] { json(url)["streams"] as? [[String: Any]] ?? [] }

    static func codecs(_ url: URL, type: String) -> [String] {
        streams(url).filter { ($0["codec_type"] as? String) == type && (($0["disposition"] as? [String: Any])?["attached_pic"] as? Int) != 1 }
            .compactMap { $0["codec_name"] as? String }
    }

    static func duration(_ url: URL) -> Double {
        Double((json(url)["format"] as? [String: Any])?["duration"] as? String ?? "") ?? 0
    }

    static func videoSize(_ url: URL) -> CGSize {
        guard let stream = streams(url).first(where: { ($0["codec_type"] as? String) == "video" }) else { return .zero }
        return CGSize(width: stream["width"] as? Int ?? 0, height: stream["height"] as? Int ?? 0)
    }

    static func channels(_ url: URL) -> Int {
        streams(url).first { ($0["codec_type"] as? String) == "audio" }?["channels"] as? Int ?? 0
    }

    static func chapters(_ url: URL) -> Int {
        guard let ffprobe = Engines.path("ffprobe"),
              let result = try? runProcess(ffprobe, ["-v", "error", "-show_chapters", "-of", "json", url.path]),
              let json = try? JSONSerialization.jsonObject(with: result.stdoutData) as? [String: Any] else { return 0 }
        return (json["chapters"] as? [Any])?.count ?? 0
    }

    static func tags(_ url: URL) -> [String: Any] {
        (json(url)["format"] as? [String: Any])?["tags"] as? [String: Any] ?? [:]
    }

    /// Integrated loudness (LUFS) measured by ffmpeg's EBU R128 meter.
    static func loudness(_ url: URL) -> Double? {
        guard let ffmpeg = Engines.path("ffmpeg"), let result = try? runProcess(ffmpeg, ["-hide_banner", "-nostats", "-i", url.path, "-af", "ebur128", "-f", "null", "-"]) else { return nil }
        let lines = result.stderr.components(separatedBy: "\n")
        guard let summary = lines.lastIndex(where: { $0.contains("Integrated loudness") }) else { return nil }
        for line in lines[summary...] where line.contains("I:") {
            let parts = line.split(separator: " ").map(String.init)
            if let index = parts.firstIndex(of: "I:"), index + 1 < parts.count { return Double(parts[index + 1]) }
        }
        return nil
    }
}

struct ImageInfo {
    let width: Int
    let height: Int
    let frames: Int
    let hasAlpha: Bool
    let properties: [CFString: Any]
}

enum Pixels {
    static func info(_ url: URL) -> ImageInfo? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        return ImageInfo(width: properties[kCGImagePropertyPixelWidth] as? Int ?? 0, height: properties[kCGImagePropertyPixelHeight] as? Int ?? 0,
                         frames: CGImageSourceGetCount(source), hasAlpha: properties[kCGImagePropertyHasAlpha] as? Bool ?? false,
                         properties: properties)
    }

    /// RGBA (0…255) at a top-left pixel coordinate.
    static func at(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
        var data = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [0, 0, 0, 0] }
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return data.map(Int.init)
    }

    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func close(_ a: [Int], _ b: [Int], _ tolerance: Int = 40) -> Bool {
        zip(a.prefix(3), b.prefix(3)).allSatisfy { abs($0 - $1) <= tolerance }
    }

    static func solid(_ width: Int, _ height: Int, _ color: CGColor) -> CGImage {
        let context = ImageConverter.bitmapContext(CGSize(width: width, height: height))!
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Mean luminance 0…255 over a coarse grid.
    static func meanLuma(_ image: CGImage) -> Double {
        var total = 0.0
        var count = 0.0
        for gx in 0..<10 { for gy in 0..<10 {
            let p = at(image, gx * image.width / 10, gy * image.height / 10)
            total += 0.2126 * Double(p[0]) + 0.7152 * Double(p[1]) + 0.0722 * Double(p[2])
            count += 1
        } }
        return total / count
    }
}

enum Files {
    static func sha(_ url: URL) -> String {
        if url.hasDirectoryPath {
            let items = (try? FileManager.default.subpathsOfDirectory(atPath: url.path))?.sorted() ?? []
            return items.map { $0 + sha(url.appendingPathComponent($0)) }.joined()
        }
        guard let data = try? Data(contentsOf: url) else { return "-" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    static func list(_ folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func size(_ url: URL) -> Int64 { Tools.fileSize(url) }

    static func pdfText(_ url: URL) -> String { PDFDocument(url: url)?.string ?? "" }
}

// MARK: - Network tripwire

/// A local TCP listener. If any conversion tries to load a remote resource pointing
/// here, the connection is counted; a correct, local-only app never connects.
final class Tripwire {
    let port: UInt16
    private let socketFD: Int32
    private let lock = NSLock()
    private var count = 0
    private var requests: [String] = []

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 16) == 0 else { throw TestFailure("Couldn’t open the network tripwire") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        socketFD = fd
        port = UInt16(bigEndian: address.sin_port)
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.start()
    }

    private func acceptLoop() {
        while true {
            let client = accept(socketFD, nil, nil)
            if client < 0 { return }
            var buffer = [UInt8](repeating: 0, count: 2048)
            let read = recv(client, &buffer, buffer.count, 0)
            let line = read > 0 ? String(decoding: buffer.prefix(read), as: UTF8.self).components(separatedBy: "\r\n").first ?? "" : ""
            lock.lock(); count += 1; requests.append(line); lock.unlock()
            let reply = "HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\n\r\n"
            _ = reply.withCString { write(client, $0, strlen($0)) }
            close(client)
        }
    }

    var connections: Int { lock.lock(); defer { lock.unlock() }; return count }
    /// Request lines seen ("GET /img.png HTTP/1.1"), to say which reference leaked.
    func requests(since index: Int) -> [String] { lock.lock(); defer { lock.unlock() }; return Array(requests.dropFirst(index)) }
    var base: String { "http://127.0.0.1:\(port)" }

    /// Proves the tripwire works (so "0 connections" really means nothing connected).
    func selfTest() -> Bool {
        let before = connections
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        close(fd)
        for _ in 0..<50 where connections == before { usleep(20_000) }
        return connections == before + 1
    }
}

/// Lets queued main-thread work (SwiftUI updates, async renders) run.
func spinRunLoop(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        spinRunLoop(0.05)
    }
    return condition()
}
