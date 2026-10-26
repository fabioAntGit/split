import AppKit

// Same binary works as the menu-bar app (no arguments) and as a CLI
// (`splitapp convert png foto.heic`), so every engine can be tested headlessly.
let arguments = Array(CommandLine.arguments.dropFirst())

if let first = arguments.first, CLI.commands.contains(first) {
    exit(CLI.run(arguments))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
