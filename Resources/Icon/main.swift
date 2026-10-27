// Draws the app icon into an .iconset folder: Split's wheel (Sources/Interface/Logo.swift) on a
// black rounded square, on the macOS icon grid.
// Usage: swiftc Resources/Icon/main.swift Sources/Interface/Logo.swift -o build/make-icon
//        build/make-icon <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = size / 1024
    // 824 of 1024, as macOS draws every app icon, with its soft shadow.
    let body = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let square = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
    shadow.shadowBlurRadius = 20 * scale
    shadow.set()
    NSColor.black.setFill()
    square.fill()
    NSGraphicsContext.restoreGraphicsState()

    let center = CGPoint(x: body.midX, y: body.midY)
    for index in 0..<Logo.slices {
        (index == 0 ? NSColor.white : Logo.grey).setFill()
        Logo.slice(index, center: center, radius: body.width * 0.3076, gap: pixels < 64 ? 0.12 : nil).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: output.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: output.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
