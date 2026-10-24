//
//  OCRServiceTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 20/10/26.
//


//
//  OCRServiceTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 13 · F-23
//
//  Builds small PDFs in a temporary folder: one page with real text, one
//  page that is only a picture of text (a "scan"), and a password-protected one.
//

import XCTest
import PDFKit
import CoreText
@testable import ResearchBase

final class OCRServiceTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("rbA13test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Helpers

    /// Collects progress updates from a background thread.
    private final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [OCRProgress] = []
        func add(_ p: OCRProgress) { lock.lock(); items.append(p); lock.unlock() }
        var all: [OCRProgress] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private func drawLine(_ text: String, size: CGFloat, at point: CGPoint, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = point
        CTLineDraw(line, context)
    }

    /// A page that only contains a bitmap of the words, so it has no text layer.
    private func scannedPage(_ words: String) -> (CGContext) -> Void {
        return { pdf in
            let scale: CGFloat = 2
            let w = Int(612 * scale), h = Int(792 * scale)
            let bitmap = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
            bitmap.fill(CGRect(x: 0, y: 0, width: w, height: h))
            bitmap.scaleBy(x: scale, y: scale)
            bitmap.setFillColor(CGColor(gray: 0, alpha: 1))
            self.drawLine(words, size: 44, at: CGPoint(x: 40, y: 600), in: bitmap)
            pdf.draw(bitmap.makeImage()!, in: CGRect(x: 0, y: 0, width: 612, height: 792))
        }
    }

    private func textPage(_ words: String) -> (CGContext) -> Void {
        return { pdf in
            pdf.setFillColor(CGColor(gray: 0, alpha: 1))
            self.drawLine(words, size: 20, at: CGPoint(x: 40, y: 600), in: pdf)
        }
    }

    private func makePDF(_ pages: [(CGContext) -> Void], password: String? = nil, name: String = "test.pdf") throws -> URL {
        let url = folder.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        var aux: [CFString: Any] = [:]
        if let password {
            aux[kCGPDFContextUserPassword] = password
            aux[kCGPDFContextOwnerPassword] = password
        }
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, aux as CFDictionary))
        for draw in pages {
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private let embeddedWords = "This page has real embedded text"
    private let scannedWords = "FEDERATED LEARNING 2017"

    // MARK: Tests

    func testAnalyseFindsPagesWithoutText() throws {
        let url = try makePDF([textPage(embeddedWords), scannedPage(scannedWords)])
        let a = try OCRService().analyse(pdfAt: url)
        XCTAssertEqual(a.pageCount, 2)
        XCTAssertEqual(a.pagesWithText, [1])
        XCTAssertEqual(a.pagesWithoutText, [2])
        XCTAssertTrue(a.needsOCR)
        XCTAssertFalse(a.isFullyScanned)
    }

    func testEmbeddedTextIsKeptAndScannedPageIsRead() async throws {
        let url = try makePDF([textPage(embeddedWords), scannedPage(scannedWords)])
        let box = ProgressBox()

        let result = try await OCRService().readPages(pdfAt: url) { p in box.add(p) }
        let updates = box.all

        XCTAssertEqual(result.pageCount, 2)
        XCTAssertFalse(result.wasCancelled)
        XCTAssertTrue(result.failedPages.isEmpty)

        XCTAssertEqual(result.pages[0].source, .embedded)
        XCTAssertTrue(result.pages[0].text.contains("embedded text"))
        XCTAssertNil(result.pages[0].confidence)

        XCTAssertEqual(result.pages[1].source, .recognised)
        XCTAssertTrue(result.pages[1].text.uppercased().contains("FEDERATED"), "got: \(result.pages[1].text)")
        XCTAssertNotNil(result.pages[1].confidence)

        XCTAssertEqual(result.recognisedPageCount, 1)
        XCTAssertEqual(result.embeddedPageCount, 1)
        XCTAssertTrue(result.fullText.contains("embedded text"))
        XCTAssertEqual(updates.map(\.pagesDone), [1, 2])
        XCTAssertEqual(updates.last?.fraction, 1)
    }

    func testPageSubsetAndForceOCR() throws {
        let url = try makePDF([textPage(embeddedWords), scannedPage(scannedWords), scannedPage(scannedWords)])

        let subset = try OCRService().readPagesBlocking(pdfAt: url, pages: [3, 99, 3, 0])
        XCTAssertEqual(subset.pages.map(\.pageNumber), [3])

        var forced = OCROptions()
        forced.forceOCR = true
        forced.maxPages = 1
        let r = try OCRService(options: forced).readPagesBlocking(pdfAt: url)
        XCTAssertEqual(r.pages.count, 1)
        XCTAssertEqual(r.pages[0].source, .recognised, "forceOCR reads even a page that has text")
    }

    func testCancellationReturnsPartialResult() throws {
        let url = try makePDF([scannedPage(scannedWords), scannedPage(scannedWords)])
        var calls = 0
        let r = try OCRService().readPagesBlocking(pdfAt: url, shouldCancel: {
            calls += 1
            return calls > 1          // allow the first page, stop before the second
        })
        XCTAssertTrue(r.wasCancelled)
        XCTAssertEqual(r.pages.count, 1)
        XCTAssertTrue(r.summary.contains("stopped early"))
    }

    func testTaskCancellation() async throws {
        let url = try makePDF([scannedPage(scannedWords), scannedPage(scannedWords)])
        let task = Task { try await OCRService().readPages(pdfAt: url) }
        task.cancel()
        let r = try await task.value
        XCTAssertTrue(r.wasCancelled)
    }

    func testFileProblems() throws {
        let service = OCRService()
        XCTAssertThrowsError(try service.analyse(pdfAt: folder.appendingPathComponent("missing.pdf"))) {
            guard case OCRError.cannotOpen = $0 else { return XCTFail("wrong error \($0)") }
        }

        let notPDF = folder.appendingPathComponent("x.pdf")
        try Data("not a pdf".utf8).write(to: notPDF)
        XCTAssertThrowsError(try service.readPagesBlocking(pdfAt: notPDF)) {
            guard case OCRError.cannotOpen = $0 else { return XCTFail("wrong error \($0)") }
        }

        let locked = try makePDF([textPage(embeddedWords)], password: "secret", name: "locked.pdf")
        XCTAssertThrowsError(try service.analyse(pdfAt: locked)) {
            XCTAssertEqual($0 as? OCRError, .locked)
        }
    }

    func testSummaryAndEmptyImage() throws {
        let blank = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        blank.setFillColor(CGColor(gray: 1, alpha: 1))
        blank.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        let read = try OCRService().recognise(image: blank.makeImage()!)
        XCTAssertEqual(read, OCRImageText(text: "", confidence: 0, lineCount: 0))

        let result = OCRDocumentResult(pageCount: 2, pages: [
            OCRPageResult(pageNumber: 1, text: "a", source: .recognised, confidence: 0.9, failure: nil),
            OCRPageResult(pageNumber: 2, text: "", source: .none, confidence: nil, failure: "Could not draw page 2.")
        ], wasCancelled: false)
        XCTAssertEqual(result.summary, "2 pages: 1 read with OCR, 1 could not be read")
        XCTAssertEqual(result.failedPages, [2])
    }
}