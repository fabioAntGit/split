import AppKit

// Test runner: `Tests/run.sh [filter]` runs every suite (or those whose name contains the filter).
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
// Office apps stay out of the default run (they need Automation permission).
Settings.useOfficeApps = false
Settings.keepsMetadata = true
Settings.playSounds = false
HUD.shared.isHeadless = true

let binary = URL(fileURLWithPath: CommandLine.arguments[0])
let repository = binary.deletingLastPathComponent().deletingLastPathComponent()
// The translation tables come from the source tree; the messages the tests read are English.
Localizer.tablesDirectory = repository.appendingPathComponent("Resources/Localization")
if Localizer.shared.language != .en { Localizer.shared.language = .en }

let arguments = Array(CommandLine.arguments.dropFirst())
let filter = arguments.first { !$0.hasPrefix("-") }?.lowercased()
let root = binary.deletingLastPathComponent().appendingPathComponent("test-run", isDirectory: true)

print("Generating samples in \(root.path)…")
do {
    try Fixtures.create(in: root)
} catch {
    print("✗ Couldn’t generate the samples: \(Explain.error(error).fullText)")
    exit(2)
}
let originals = Dictionary(uniqueKeysWithValues: Files.list(root).filter { !$0.lastPathComponent.hasPrefix("_") }.map { ($0.path, Files.sha($0)) })

registerConversionTests()
registerFidelityTests()
registerDataTests()
registerToolTests()
registerEditorTests()
registerErrorTests()
registerSecurityTests()
registerUITests()
registerWheelTests()
registerLocalizationTests()
registerOfficeTests()
test("Integrity", "Originals are never changed") {
    for (path, hash) in originals {
        check(Files.sha(URL(fileURLWithPath: path)) == hash, "\(URL(fileURLWithPath: path).lastPathComponent) was changed")
    }
}
test("Integrity", "No temporary files are left behind") {
    var leftovers: [String] = []
    if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
        for case let url as URL in walker where url.lastPathComponent.hasPrefix(".split-") { leftovers.append(url.path) }
    }
    check(leftovers.isEmpty, "forgotten temporary files: \(leftovers.prefix(5))")
    let scratch = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
    check(scratch.filter { $0.hasPrefix("split-") }.isEmpty, "forgotten work folders in \(FileManager.default.temporaryDirectory.path)")
}

var passed = 0
var failed: [(String, [String])] = []
let started = Date()
for testCase in Registry.tests where filter == nil || "\(testCase.suite) \(testCase.name)".lowercased().contains(filter!) {
    Registry.failures = []
    let begin = Date()
    do {
        try testCase.body()
    } catch {
        Registry.failures.append("stopped: \(Explain.error(error).fullText)")
    }
    let time = String(format: "%.1f s", Date().timeIntervalSince(begin))
    if Registry.failures.isEmpty {
        passed += 1
        print("✓ \(testCase.suite) › \(testCase.name) (\(time))")
    } else {
        failed.append(("\(testCase.suite) › \(testCase.name)", Registry.failures))
        print("✗ \(testCase.suite) › \(testCase.name) (\(time))")
        Registry.failures.forEach { print("    · \($0)") }
    }
}

print("\n\(passed) tests passed, \(failed.count) failed, \(Registry.checks) checks in \(Int(Date().timeIntervalSince(started))) s.")
exit(failed.isEmpty ? 0 : 1)
