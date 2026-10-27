// Draws the disk image's window: Split's wheel and name at the top, an arrow from the app to the
// Applications folder, and a field of dots that fades where the two icons sit.
// Usage: swiftc Resources/DiskImage/main.swift Sources/Interface/Logo.swift -o build/make-dmg-background
//        build/make-dmg-background <folder>   → background.png and background@2x.png
// make-dmg.sh places the icons on the arrow's ends, at the points below.
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

/// The window, in points, from the top left as Finder counts.
let window = CGSize(width: 660, height: 400)
let arrow = (from: CGPoint(x: 235, y: 200), to: CGPoint(x: 425, y: 200))

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(window.width * scale), pixelsHigh: Int(window.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = window
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // Finder's coordinates: y grows downwards.
    let flip = NSAffineTransform()
    flip.translateX(by: 0, yBy: window.height)
    flip.scaleX(by: 1, yBy: -1)
    flip.concat()

    NSColor.black.setFill()
    NSRect(origin: .zero, size: window).fill()

    // Dots, faint around the middle and brighter towards the edges, and none under the words.
    let spacing: CGFloat = 16.5
    let clear = [NSRect(x: 230, y: 22, width: 200, height: 70), NSRect(x: 196, y: 324, width: 268, height: 28)]
    var y = spacing
    while y < window.height {
        var x = spacing / 2
        while x < window.width {
            let dx = (x - window.width / 2) / (window.width / 2)
            let dy = (y - window.height / 2) / (window.height / 2)
            let distance = min(1, (dx * dx + dy * dy).squareRoot())
            let fade = max(0, min(1, (distance - 0.38) / 0.5))
            if fade > 0, !clear.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) {
                NSColor(white: 0.62, alpha: fade * fade * (3 - 2 * fade)).setFill()
                NSBezierPath(ovalIn: NSRect(x: x - 1, y: y - 1, width: 2, height: 2)).fill()
            }
            x += spacing
        }
        y += spacing
    }

    // The wheel and the name, centred together. Logo.slice counts angles with y upwards, so it
    // is drawn unflipped around its own centre.
    let name = NSAttributedString(string: "split", attributes: [
        .font: NSFont.systemFont(ofSize: 36, weight: .medium),
        .foregroundColor: NSColor.white,
    ])
    let radius: CGFloat = 27.5, space: CGFloat = 17
    let width = radius * 2 + space + name.size().width
    let center = CGPoint(x: (window.width - width) / 2 + radius, y: 57)
    NSGraphicsContext.saveGraphicsState()
    let unflip = NSAffineTransform()
    unflip.translateX(by: center.x, yBy: center.y)
    unflip.scaleX(by: 1, yBy: -1)
    unflip.concat()
    for index in 0..<Logo.slices {
        (index == 0 ? NSColor.white : Logo.grey).setFill()
        Logo.slice(index, center: .zero, radius: radius).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    let text = NSAffineTransform()
    text.translateX(by: center.x + radius + space, yBy: center.y + name.size().height / 2 - 2)
    text.scaleX(by: 1, yBy: -1)
    text.concat()
    name.draw(at: .zero)
    NSGraphicsContext.restoreGraphicsState()

    // The arrow: a line that grows out of the dark into white, and an open head.
    let line = NSRect(x: arrow.from.x, y: arrow.from.y - 1.25, width: arrow.to.x - arrow.from.x - 1, height: 2.5)
    NSGradient(colors: [NSColor(white: 1, alpha: 0), NSColor(white: 1, alpha: 0.75), .white], atLocations: [0, 0.6, 1],
               colorSpace: .deviceRGB)!.draw(in: NSBezierPath(roundedRect: line, xRadius: 1.25, yRadius: 1.25), angle: 0)
    let head = NSBezierPath()
    head.move(to: CGPoint(x: arrow.to.x - 19, y: arrow.to.y - 19))
    head.line(to: arrow.to)
    head.line(to: CGPoint(x: arrow.to.x - 19, y: arrow.to.y + 19))
    head.lineWidth = 2.5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    NSColor.white.setStroke()
    head.stroke()

    let hint = NSAttributedString(string: "Drag split to the Applications folder", attributes: [
        .font: NSFont.systemFont(ofSize: 14),
        .foregroundColor: NSColor(white: 0.74, alpha: 1),
    ])
    NSGraphicsContext.saveGraphicsState()
    let caption = NSAffineTransform()
    caption.translateX(by: (window.width - hint.size().width) / 2, yBy: 338 + hint.size().height / 2)
    caption.scaleX(by: 1, yBy: -1)
    caption.concat()
    hint.draw(at: .zero)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try! render(scale: 1).write(to: output.appendingPathComponent("background.png"))
try! render(scale: 2).write(to: output.appendingPathComponent("background@2x.png"))
