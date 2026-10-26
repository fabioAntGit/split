import AppKit
import PDFKit

func registerEditorTests() {
    let red = [255, 0, 0], blue = [0, 0, 255], green = [0, 204, 0], yellow = [255, 230, 0]

    test("Crop", "Rotating 90° right, flipping and cropping use screen coordinates") {
        let image = Fixtures.quadrants()
        let turned = try CropRenderer.transform(image, turns: 1, flipH: false, flipV: false)
        check(turned.width == 400 && turned.height == 600, "size \(turned.width)×\(turned.height)")
        // Clockwise: the left column (red over green) becomes the top row (green, red).
        check(Pixels.close(Pixels.at(turned, 50, 50), green), "top-left should be green: \(Pixels.at(turned, 50, 50))")
        check(Pixels.close(Pixels.at(turned, 350, 50), red), "top-right should be red: \(Pixels.at(turned, 350, 50))")
        // …and the right column (blue over yellow) becomes the bottom row (yellow, blue).
        check(Pixels.close(Pixels.at(turned, 50, 550), yellow), "bottom-left should be yellow: \(Pixels.at(turned, 50, 550))")
        let mirrored = try CropRenderer.transform(image, turns: 0, flipH: true, flipV: false)
        check(Pixels.close(Pixels.at(mirrored, 50, 50), blue), "flipped horizontally: top-left is blue")
        let flipped = try CropRenderer.transform(image, turns: 0, flipH: false, flipV: true)
        check(Pixels.close(Pixels.at(flipped, 50, 50), green), "flipped vertically: top-left is green")
        var settings = CropSettings()
        settings.rect = CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        let cropped = try CropRenderer.render(image, settings)
        check(cropped.width == 300 && cropped.height == 200, "crop \(cropped.width)×\(cropped.height)")
        check(Pixels.close(Pixels.at(cropped, 150, 100), blue), "the top-right quadrant is blue: \(Pixels.at(cropped, 150, 100))")
        settings.rect = CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        check(Pixels.close(Pixels.at(try CropRenderer.render(image, settings), 10, 10), green), "bottom-left is green")
    }

    test("Crop", "Rotating with a crop keeps showing the same area") {
        let image = Fixtures.quadrants()
        let model = CropModel(urls: [], preview: image)
        model.settings.rect = CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5) // blue
        model.rotate(clockwise: true)
        check(Pixels.close(Pixels.at(try CropRenderer.render(image, model.settings), 20, 20), blue), "still blue after rotating right")
        model.rotate(clockwise: false)
        model.rotate(clockwise: false)
        check(Pixels.close(Pixels.at(try CropRenderer.render(image, model.settings), 20, 20), blue), "still blue after rotating left")
        model.flip(horizontal: true)
        check(Pixels.close(Pixels.at(try CropRenderer.render(image, model.settings), 20, 20), blue), "still blue after flipping")
    }

    test("Crop", "Dragging keeps the ratio, the bounds and the minimum size") {
        let square: CGFloat = 1
        let corner = CropRenderer.drag(.bottomRight, from: CropSettings.full, by: CGSize(width: -0.3, height: -0.1), ratio: square)
        check(abs(corner.width - corner.height) < 1e-9 && corner.origin == .zero, "corner at 1:1 → \(corner)")
        let edge = CropRenderer.drag(.right, from: CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4), by: CGSize(width: 0.5, height: 0), ratio: square)
        check(edge.maxX <= 1 + 1e-9 && edge.minY >= 0 && edge.maxY <= 1 + 1e-9 && abs(edge.width - edge.height) < 1e-9, "side at 1:1 → \(edge)")
        let moved = CropRenderer.drag(.move, from: CGRect(x: 0.5, y: 0.5, width: 0.4, height: 0.4), by: CGSize(width: 1, height: 1), ratio: nil)
        check(moved == CGRect(x: 0.6, y: 0.6, width: 0.4, height: 0.4), "moving stays inside the image → \(moved)")
        let tiny = CropRenderer.drag(.topLeft, from: CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1), by: CGSize(width: 1, height: 1), ratio: nil)
        check(tiny.width >= 0.03 - 1e-9 && tiny.height >= 0.03 - 1e-9, "minimum size → \(tiny)")
        let fitted = CropRenderer.fitted(ratio: 16.0 / 9, imageSize: CGSize(width: 1000, height: 1000), center: CGPoint(x: 0.5, y: 0.5))
        check(abs(fitted.width - 1) < 1e-9 && abs(fitted.height - 0.5625) < 1e-9 && abs(fitted.midY - 0.5) < 1e-9, "16:9 → \(fitted)")
        check(CropRenderer.handle(at: CGPoint(x: 100, y: 100), crop: CropSettings.full, frame: CGRect(x: 100, y: 100, width: 400, height: 300)) == .topLeft, "grabs the corner")
        check(CropRenderer.handle(at: CGPoint(x: 300, y: 250), crop: CropSettings.full, frame: CGRect(x: 100, y: 100, width: 400, height: 300)) == .move, "the middle moves")
    }

    test("Crop", "A fixed ratio gives every picture of a batch that shape") {
        let wide = Fixtures.quadrants(600, 400)
        let tall = Fixtures.quadrants(300, 600)
        let model = CropModel(urls: [], preview: wide)
        model.aspect = .r4x5
        let settings = model.batchSettings
        try require(settings.shape != nil, "4:5 should be kept as a shape")
        for image in [wide, tall] {
            let out = try CropRenderer.render(image, settings)
            check(abs(Double(out.width) / Double(out.height) - 0.8) < 0.01, "\(image.width)×\(image.height) → \(out.width)×\(out.height), not 4:5")
        }
        model.aspect = .original
        check(model.batchSettings.shape == nil, "“Original” keeps each picture’s own shape")
        check(CropAspect.allCases.contains(.r5x4) && CropAspect.r5x4.ratio(original: .zero) == 1.25, "5:4 is offered")
    }

    test("Background", "Margin, ratio, transparent corners and gradient") {
        var style = BackdropStyle()
        style.padding = 0.1
        check(BackdropRenderer.backdropSize(for: CGSize(width: 1000, height: 500), style: style) == CGSize(width: 1200, height: 700), "10% margin")
        style.ratio = .square
        check(BackdropRenderer.backdropSize(for: CGSize(width: 1000, height: 500), style: style) == CGSize(width: 1200, height: 1200), "square")
        style = BackdropStyle()
        style.kind = .transparent
        style.corner = 0.2
        style.shadow = 0
        style.padding = 0.1
        let image = Fixtures.quadrants()
        let result = try BackdropRenderer.render(image, style: style)
        let pad = 60
        check(Pixels.at(result, pad + 1, pad + 1)[3] == 0, "the rounded corner should be transparent")
        check(Pixels.at(result, pad + 150, pad + 100)[3] == 255, "the inside of the image is opaque")
        style.kind = .gradient
        style.gradient = 0
        let gradient = try BackdropRenderer.render(image, style: style)
        check(Pixels.close(Pixels.at(gradient, 2, 2), [255, 154, 61], 30), "corner of the Citrine gradient: \(Pixels.at(gradient, 2, 2))")
        style.kind = .blur
        check(Pixels.at(try BackdropRenderer.render(image, style: style), 2, 2)[3] == 255, "a blurred background is opaque")
    }

    test("Annotate", "Cover, blur, pixelate, arrow, text and numbers") {
        let white = Pixels.solid(1000, 800, CGColor(gray: 1, alpha: 1))
        let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let redact = Mark(tool: .redact, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.3, y: 0.3)], color: red, width: 4)
        let out = try require(MarkupRenderer.render(base: white, marks: [redact]), "render")
        check(Pixels.close(Pixels.at(out, 200, 160), [0, 0, 0], 5), "the covered area should be black")
        check(Pixels.close(Pixels.at(out, 500, 500), [255, 255, 255], 5), "outside the area stays the same")

        let quads = Fixtures.quadrants(1000, 800)
        let layers = MarkupRenderer.privacyLayers(for: quads)
        let blur = Mark(tool: .blur, points: [CGPoint(x: 0.4, y: 0.4), CGPoint(x: 0.6, y: 0.6)], color: red, width: 4)
        let blurred = try require(MarkupRenderer.render(base: quads, marks: [blur], blurred: layers.blurred, pixelated: layers.pixelated), "blur")
        let centre = Pixels.at(blurred, 500, 400)
        check(!Pixels.close(centre, Pixels.at(quads, 500, 400), 10), "the blurred centre should mix colours: \(centre)")
        check(Pixels.close(Pixels.at(blurred, 50, 50), [255, 0, 0], 5), "outside the area isn’t blurred")

        let arrow = Mark(tool: .arrow, points: [CGPoint(x: 0.1, y: 0.9), CGPoint(x: 0.9, y: 0.1)], color: red, width: 8)
        let drawn = try require(MarkupRenderer.render(base: white, marks: [arrow]), "arrow")
        check(Pixels.close(Pixels.at(drawn, 500, 400), [255, 0, 0], 40), "the arrow’s line crosses the middle")
        var text = Mark(tool: .text, points: [CGPoint(x: 0.1, y: 0.1)], color: red, width: 6)
        text.text = "Hi"
        var counter = Mark(tool: .counter, points: [CGPoint(x: 0.5, y: 0.5)], color: red, width: 6)
        counter.number = 7
        let labelled = try require(MarkupRenderer.render(base: white, marks: [text, counter]), "text")
        var redPixels = 0
        for x in stride(from: 100, to: 200, by: 4) { for y in stride(from: 80, to: 130, by: 4) where Pixels.at(labelled, x, y)[1] < 120 { redPixels += 1 } }
        check(redPixels > 5, "the text should show in red (\(redPixels) pixels)")
        check(Pixels.close(Pixels.at(labelled, 500 - 14, 400), [255, 0, 0], 40), "the number’s circle is red")
        _ = try MarkupRenderer.faceAreas(in: quads)
    }

    test("Adjust", "Exposure, the mono filter and temperature do what they say") {
        let gray = Pixels.solid(200, 200, CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        var adjustments = Adjustments()
        check(try AdjustRenderer.render(gray, adjustments) === gray, "without adjustments it returns the same image")
        adjustments.exposure = 1
        check(Pixels.meanLuma(try AdjustRenderer.render(gray, adjustments)) > Pixels.meanLuma(gray) + 20, "+1 EV should brighten")
        adjustments = Adjustments()
        adjustments.warmth = 1
        let warm = Pixels.at(try AdjustRenderer.render(gray, adjustments), 100, 100)
        check(warm[0] > warm[2] + 10, "warmer should lean towards red: \(warm)")
        adjustments = Adjustments()
        adjustments.filter = .mono
        let mono = Pixels.at(try AdjustRenderer.render(Fixtures.quadrants(), adjustments), 50, 50)
        check(abs(mono[0] - mono[1]) < 4 && abs(mono[1] - mono[2]) < 4, "mono should be grey: \(mono)")
        adjustments = Adjustments()
        adjustments.auto = true
        adjustments.vignette = 1
        adjustments.sharpness = 1
        adjustments.noise = 1
        let all = try AdjustRenderer.render(Fixtures.quadrants(), adjustments)
        check(all.width == 600 && all.height == 400, "the size doesn’t change")
    }

    test("Collage", "Layouts: row, column and grid with the last row centred") {
        var style = CollageSpec()
        style.width = 1000
        style.spacing = 0
        style.layout = .row
        let row = CollageRenderer.layout(aspects: [1, 2], style: style)
        check(abs(row.cells[0].height - row.cells[1].height) < 1e-9 && abs(row.cells[1].width / row.cells[0].width - 2) < 1e-9, "row: \(row.cells)")
        check(abs(row.cells[1].maxX - 1000) < 1e-6, "the row fills the width")
        style.layout = .column
        let column = CollageRenderer.layout(aspects: [1, 2], style: style)
        check(column.cells.allSatisfy { abs($0.width - 1000) < 1e-9 }, "a column has one width")
        style.layout = .grid
        style.spacing = 0.01
        let grid = CollageRenderer.layout(aspects: [1, 1, 1], style: style)
        check(grid.cells[2].midX > grid.cells[0].maxX - 1 && abs(grid.cells[2].midX - 500) < 1, "the last row should be centred: \(grid.cells[2])")
        let images = [Fixtures.quadrants(), Fixtures.quadrants(300, 300), Fixtures.quadrants(200, 400)]
        let rendered = try CollageRenderer.render(images, style: style)
        check(CGFloat(rendered.width) == 1000 && CGFloat(rendered.height) == grid.canvas.height, "canvas \(rendered.width)×\(rendered.height)")
    }

    test("Video and audio", "ffmpeg commands: atempo, crops with even values, quick trim") {
        // ffmpeg's atempo accepts 0.5…2 per stage; faster or slower speeds are chained.
        for speed in [4, 0.25, 3, 0.3, 1.5] {
            let factors = MediaEditRenderer.atempo(speed).map { Double($0.dropFirst("atempo=".count)) ?? 0 }
            check(factors.allSatisfy { $0 >= 0.5 && $0 <= 2 }, "\(speed)×: a factor outside 0.5…2 in \(factors)")
            check(near(factors.reduce(1, *), speed, 0.001), "\(speed)×: the product is \(factors.reduce(1, *))")
        }
        check(MediaEditRenderer.evenOffset(0) == 0 && MediaEditRenderer.even(0) == 2 && MediaEditRenderer.even(241) == 240, "even values")
        check(MediaEditRenderer.atempo(1).isEmpty, "1× needs no filter")
        var probe = MediaConverter.Probe()
        probe.videoEncoder = "h264"
        probe.audioEncoder = "aac"
        probe.width = 321
        probe.height = 241
        probe.duration = 10
        var edit = MediaEdit()
        edit.duration = 10
        edit.start = 2
        edit.end = 5
        edit.crop = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        let arguments = MediaEditRenderer.arguments(edit: edit, probe: probe, target: .mp4)
        check(arguments.input == ["-ss", "2.000", "-t", "3.000"], "trim: \(arguments.input)")
        let graph = arguments.output[(arguments.output.firstIndex(of: "-filter_complex") ?? 0) + 1]
        check(graph.contains("crop=160:120:32:24"), "crop with even values: \(graph)")
        edit.crop = nil
        edit.fastTrim = true
        check(MediaEditRenderer.arguments(edit: edit, probe: probe, target: .mp4).output.contains("copy"), "a quick trim copies the streams")
    }

    test("Video and audio", "Export: trim, speed, crop, rotate, cover, GIF, audio only") {
        let clip = try Fixtures.isolated("clip.mp4", in: "media-edit")
        var edit = MediaEdit()
        edit.duration = 2
        edit.start = 0.5
        edit.end = 1.5
        check(near(Probe.duration(try MediaEditRenderer.export(clip, edit: edit)), 1, 0.15), "a 1 s trim")
        edit = MediaEdit()
        edit.duration = 2
        edit.end = 2
        edit.speed = 2
        let fast = try MediaEditRenderer.export(clip, edit: edit)
        check(near(Probe.duration(fast), 1, 0.15), "2× → \(Probe.duration(fast)) s")
        check(!Probe.codecs(fast, type: "audio").isEmpty, "speed keeps the sound")
        edit.speed = 1
        edit.crop = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        check(Probe.videoSize(try MediaEditRenderer.export(clip, edit: edit)) == CGSize(width: 160, height: 120), "crop 160×120")
        edit.crop = nil
        edit.turns = 1
        check(Probe.videoSize(try MediaEditRenderer.export(clip, edit: edit)) == CGSize(width: 240, height: 320), "rotated 240×320")
        edit.turns = 0
        edit.masks = [MaskRegion(rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), kind: .black),
                           MaskRegion(rect: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5), kind: .blur)]
        let redacted = try MediaEditRenderer.export(clip, edit: edit)
        let frame = try MediaEditRenderer.saveFrame(redacted, at: 1)
        let image = try require(Pixels.load(frame), "frame")
        check(Pixels.close(Pixels.at(image, 40, 30), [0, 0, 0], 20), "the covered area should be black: \(Pixels.at(image, 40, 30))")
        edit.masks = []
        edit.output = .gif
        check(try requireInfo(try MediaEditRenderer.export(clip, edit: edit)).frames > 5, "animated GIF")
        edit.output = .m4a
        let audioOnly = try MediaEditRenderer.export(clip, edit: edit)
        check(Probe.codecs(audioOnly, type: "video").isEmpty && Probe.codecs(audioOnly, type: "audio") == ["aac"], "audio only, as M4A")

        let wav = try Fixtures.isolated("tone.wav", in: "audio-edit")
        var sound = MediaEdit()
        sound.duration = 3
        sound.start = 0.5
        sound.end = 2.5
        sound.volume = 0.5
        sound.fadeIn = true
        sound.fadeOut = true
        check(near(Probe.duration(try MediaEditRenderer.export(wav, edit: sound)), 2, 0.1), "trimmed audio with fades")
        sound.mute = true
        expectError("muting an audio file", contains: ["empty"]) { _ = try MediaEditRenderer.export(wav, edit: sound) }
        let peaks = try MediaEditRenderer.waveform(wav)
        check(peaks.count > 100 && (peaks.max() ?? 0) == 1, "waveform: \(peaks.count) points")
    }

    test("Video and audio", "Phone video (rotated): crops in the coordinates you see") {
        let portrait = try Fixtures.isolated("portrait.mp4", in: "media-portrait")
        let probe = try MediaConverter.probe(portrait)
        check(probe.displaySize.height > probe.displaySize.width, "the displayed size should be portrait: \(probe.displaySize)")
        var edit = MediaEdit()
        edit.duration = probe.duration
        edit.end = probe.duration
        edit.crop = CGRect(x: 0, y: 0, width: 1, height: 0.5)
        let size = Probe.videoSize(try MediaEditRenderer.export(portrait, edit: edit))
        check(size == CGSize(width: 240, height: 160), "top half of 240×320 → \(size)")
    }

    test("Organize PDF", "Order, rotation, duplicates and an empty document") {
        let document = try PDFTools.open(Fixtures.url("report.pdf"))
        var third = PageItem(source: 0, page: 2)
        third.rotation = 90
        let built = try PDFOrganizer.build([third, PageItem(source: 0, page: 0)], documents: [document])
        check(built.pageCount == 2, "2 pages")
        check(built.page(at: 0)?.string?.contains("Page 3") == true, "the first one becomes page 3")
        check(built.page(at: 0)?.rotation == 90, "a 90° rotation")
        expectError("PDF without pages", contains: ["no pages"]) { _ = try PDFOrganizer.build([], documents: [document]) }
        let model = try PDFOrganizerModel(urls: [Fixtures.url("report.pdf"), Fixtures.url("quadrants.png")])
        check(model.items.count == 4, "3 pages + 1 image")
        model.selection = [model.items[0].id]
        model.duplicateSelection()
        check(model.items.count == 5 && model.items[1].page == 0, "duplicating inserts the copy right after")
        model.selection = Set(model.items.map(\.id))
        model.removeSelected()
        check(model.items.count == 5 && model.note != nil, "deleting everything is refused with an explanation")
        check(model.hasChanges, "duplicating counts as a change")
    }
}
