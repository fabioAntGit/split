import AppKit
import PDFKit

/// Conversions done by the installed Office apps. Opt-in (`SPLIT_OFFICE=1 Tests/run.sh Office`):
/// they open Word, Excel and PowerPoint, and the first run asks for Automation permission.
func registerOfficeTests() {
    guard ProcessInfo.processInfo.environment["SPLIT_OFFICE"] == "1" else { return }

    func withOffice(_ body: () throws -> Void) rethrows {
        Settings.useOfficeApps = true
        defer {
            Settings.useOfficeApps = false
            OfficeBridge.quitLaunchedApps()
        }
        try body()
    }

    test("Office", "PowerPoint: PPTX → PDF with the slide’s text") {
        guard OfficeApp.powerPoint.isInstalled || OfficeApp.keynote.isInstalled else { return }
        let dir = Fixtures.root.appendingPathComponent("_office", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pptx = dir.appendingPathComponent("slides.pptx")
        try Fixtures.pptx(pptx)
        try withOffice {
            let pdf = try require(try Conversions.convert(pptx, to: .pdf).first, "no PDF")
            check(PDFDocument(url: pdf)?.pageCount == 1, "1 slide → \(PDFDocument(url: pdf)?.pageCount ?? 0) pages")
            check(Files.pdfText(pdf).contains("Hello Split"), "the slide’s text should be in the PDF")
        }
    }

    test("Office", "Word: DOCX → PDF with accents") {
        guard OfficeApp.word.isInstalled else { return }
        let docx = try Fixtures.isolated("letter.docx", in: "office-word")
        try withOffice {
            let pdf = try require(try Conversions.convert(docx, to: .pdf).first, "no PDF")
            check(Files.pdfText(pdf).contains("crème brûlée"), "text: \(Files.pdfText(pdf).prefix(80))")
        }
    }

    test("Office", "Excel: XLSX → PDF") {
        guard OfficeApp.excel.isInstalled else { return }
        let xlsx = try Fixtures.isolated("sales.xlsx", in: "office-excel")
        try withOffice {
            let pdf = try require(try Conversions.convert(xlsx, to: .pdf).first, "no PDF")
            check((PDFDocument(url: pdf)?.pageCount ?? 0) >= 1, "empty PDF")
        }
    }
}
