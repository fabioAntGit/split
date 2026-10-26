// Draws the app icon (an orange wheel of segments) into an .iconset folder.
// Usage: swift make_icon.swift <output.iconset>
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
    let inset = size * 0.1
    let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let squircle = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(starting: NSColor(srgbRed: 1.0, green: 0.62, blue: 0.20, alpha: 1),
               ending: NSColor(srgbRed: 0.96, green: 0.36, blue: 0.05, alpha: 1))!.draw(in: squircle, angle: -90)

    let center = CGPoint(x: size / 2, y: size / 2)
    let outer = body.width * 0.36
    let inner = body.width * 0.15
    let segments = 8
    for index in 0..<segments {
        let start = 90 - Double(index) * 360 / Double(segments) - 3
        let end = 90 - Double(index + 1) * 360 / Double(segments) + 3
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: outer, startAngle: start, endAngle: end, clockwise: true)
        path.appendArc(withCenter: center, radius: inner, startAngle: end, endAngle: start, clockwise: false)
        path.close()
        NSColor(white: 1, alpha: index == 0 ? 1 : 0.55).setFill()
        path.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: output.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: output.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
