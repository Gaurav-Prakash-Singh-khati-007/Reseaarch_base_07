//
//  OCRService.swift
//  ResearchBase
//
//  Owner: Agent 13 · Features: F-23
//
//  Makes scanned PDFs searchable. For every page it either takes the text
//  already inside the PDF or, when a page has (almost) none, draws the page
//  and reads it with macOS Vision. It only RETURNS text: it writes nothing
//  to the library, the search index or the PDF. The indexer (Agent 50)
//  stores the result.
//
//  PUBLIC API
//    struct OCROptions                 dpi, languages, accuracy, thresholds, page limit
//    struct OCRProgress                pages done / total, current page, fraction
//    enum   OCRPageSource              .embedded, .recognised, .none
//    struct OCRPageResult              one page: number (1-based), text, source, confidence, failure
//    struct OCRDocumentAnalysis        which pages have text and which need OCR
//    struct OCRDocumentResult          all pages, failed pages, cancelled flag, summary
//    struct OCRImageText               text read from one image
//    enum   OCRError                   file-level problems only (LocalizedError)
//    final class OCRService
//      init(options: OCROptions = OCROptions())
//      func analyse(pdfAt:) throws -> OCRDocumentAnalysis
//      func readPages(pdfAt:pages:progress:) async throws -> OCRDocumentResult
//      func readPagesBlocking(pdfAt:pages:progress:shouldCancel:) throws -> OCRDocumentResult
//      func recognise(image: CGImage) throws -> OCRImageText
//
//  Rules
//    - A page with at least `embeddedTextThreshold` non-space characters keeps
//      its own text and is not re-read (unless `forceOCR`). This is quick and
//      exact; OCR is only for pages that need it.
//    - One bad page never stops the rest: it is reported in `failure` and the
//      next page is read. Only a PDF that cannot be opened at all throws.
//    - Cancelling (Task cancellation, or `shouldCancel` returning true) stops
//      after the current page and returns what was read so far, with
//      `wasCancelled` set. Nothing is lost.
//    - One page is held in memory at a time, drawn at `dpi` but never larger
//      than `maxLongSidePixels` on its longest side.
//    - Text from several columns is returned top to bottom, left to right
//      within a line; reading order of complex layouts is approximate.
//    - Page numbers are 1-based, like the page numbers people see.
//    - No logging here. The caller turns `failure` strings (plain words) into log lines.
//

import Foundation
import PDFKit
import Vision
import CoreGraphics

// MARK: - Options and results

nonisolated struct OCROptions: Sendable {
    /// Resolution used to draw a page before reading it. 300 is the usual scan quality.
    var dpi: Double = 300
    /// Safety limit on the drawn image, so a huge page cannot use all memory.
    var maxLongSidePixels: Int = 5000
    /// Lines Vision is less sure of than this are dropped (0 to 1).
    var minimumLineConfidence: Float = 0.3
    /// Language codes such as ["en-US", "de-DE"]. Empty = detect automatically.
    var languages: [String] = []
    /// Fast reads quicker and less exactly. Default is the accurate level.
    var fast: Bool = false
    /// A page with fewer non-space characters than this counts as having no text.
    var embeddedTextThreshold: Int = 20
    /// Read every page with OCR, even pages that already have text.
    var forceOCR: Bool = false
    /// Stop after this many pages (of the pages chosen). nil = all.
    var maxPages: Int?
}

nonisolated struct OCRProgress: Sendable, Equatable {
    let pagesDone: Int
    let pagesTotal: Int
    /// The page just finished (1-based).
    let currentPage: Int

    var fraction: Double { pagesTotal == 0 ? 1 : Double(pagesDone) / Double(pagesTotal) }
}

nonisolated enum OCRPageSource: String, Sendable, Equatable {
    /// The PDF already had text on this page.
    case embedded
    /// The page was drawn and read with Vision.
    case recognised
    /// No text could be found (blank page, picture only, or a failure).
    case none
}

nonisolated struct OCRPageResult: Sendable, Equatable {
    /// 1-based.
    let pageNumber: Int
    let text: String
    let source: OCRPageSource
    /// Average Vision confidence (0 to 1) for recognised pages, otherwise nil.
    let confidence: Double?
    /// Plain-words reason when the page could not be read; nil otherwise.
    let failure: String?

    var hasText: Bool { !text.isEmpty }
}

nonisolated struct OCRDocumentAnalysis: Sendable, Equatable {
    let pageCount: Int
    /// 1-based page numbers.
    let pagesWithText: [Int]
    let pagesWithoutText: [Int]

    /// At least one page would be read with OCR.
    var needsOCR: Bool { !pagesWithoutText.isEmpty }
    /// No page has text at all: a pure scan.
    var isFullyScanned: Bool { pageCount > 0 && pagesWithText.isEmpty }
}

nonisolated struct OCRDocumentResult: Sendable, Equatable {
    let pageCount: Int
    /// Only the pages that were processed, in page order.
    var pages: [OCRPageResult]
    var wasCancelled: Bool

    var failedPages: [Int] { pages.filter { $0.failure != nil }.map(\.pageNumber) }
    var recognisedPageCount: Int { pages.filter { $0.source == .recognised }.count }
    var embeddedPageCount: Int { pages.filter { $0.source == .embedded }.count }
    var fullText: String { pages.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n") }

    /// One line for the UI, e.g. "12 pages: 2 read with OCR, 1 could not be read".
    var summary: String {
        var parts = ["\(pages.count) \(pages.count == 1 ? "page" : "pages")"]
        var detail: [String] = []
        if recognisedPageCount > 0 { detail.append("\(recognisedPageCount) read with OCR") }
        if !failedPages.isEmpty { detail.append("\(failedPages.count) could not be read") }
        if wasCancelled { detail.append("stopped early") }
        if !detail.isEmpty { parts.append(detail.joined(separator: ", ")) }
        return parts.joined(separator: ": ")
    }
}

nonisolated struct OCRImageText: Sendable, Equatable {
    let text: String
    /// Average confidence (0 to 1) of the lines kept; 0 when nothing was read.
    let confidence: Double
    let lineCount: Int
}

nonisolated enum OCRError: LocalizedError, Equatable {
    case cannotOpen(String)
    case locked
    case noPages

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let why):
            return "The PDF could not be opened. \(why)"
        case .locked:
            return "The PDF is protected with a password, so its text cannot be read."
        case .noPages:
            return "The PDF has no pages."
        }
    }
}

// MARK: - Service

nonisolated final class OCRService: Sendable {

    let options: OCROptions

    init(options: OCROptions = OCROptions()) {
        self.options = options
    }

    // MARK: Analyse

    /// Quick look: which pages already have text. No OCR is done.
    func analyse(pdfAt url: URL) throws -> OCRDocumentAnalysis {
        let document = try rbA13_open(url)
        var with: [Int] = []
        var without: [Int] = []
        for index in 0..<document.pageCount {
            let text = document.page(at: index)?.string ?? ""
            if rbA13_visibleCount(text) >= options.embeddedTextThreshold { with.append(index + 1) }
            else { without.append(index + 1) }
        }
        return OCRDocumentAnalysis(pageCount: document.pageCount, pagesWithText: with, pagesWithoutText: without)
    }

    // MARK: Read pages

    /// Reads the text of a PDF: embedded text where there is some, OCR where there is not.
    /// Runs on a background thread and stops early if the calling task is cancelled.
    /// - Parameter pages: 1-based page numbers to read; nil = every page.
    func readPages(
        pdfAt url: URL,
        pages: [Int]? = nil,
        progress: (@Sendable (OCRProgress) -> Void)? = nil
    ) async throws -> OCRDocumentResult {

        let work = Task.detached(priority: .utility) { [self] () throws -> OCRDocumentResult in
            try self.readPagesBlocking(
                pdfAt: url, pages: pages, progress: progress,
                shouldCancel: { Task.isCancelled })
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    /// Same as `readPages`, but on the calling thread. Use it from your own queue.
    func readPagesBlocking(
        pdfAt url: URL,
        pages: [Int]? = nil,
        progress: (@Sendable (OCRProgress) -> Void)? = nil,
        shouldCancel: () -> Bool = { false }
    ) throws -> OCRDocumentResult {

        let document = try rbA13_open(url)
        let total = document.pageCount

        var wanted: [Int]
        if let pages {
            wanted = Array(Set(pages.filter { (1...total).contains($0) })).sorted()
        } else {
            wanted = Array(1...total)
        }
        if let limit = options.maxPages, limit >= 0, wanted.count > limit { wanted = Array(wanted.prefix(limit)) }

        var results: [OCRPageResult] = []
        var cancelled = false

        for (done, number) in wanted.enumerated() {
            if shouldCancel() { cancelled = true; break }

            var pageResult: OCRPageResult?
            autoreleasepool {
                pageResult = self.readOnePage(document: document, number: number)
            }
            results.append(pageResult ?? OCRPageResult(
                pageNumber: number, text: "", source: .none, confidence: nil,
                failure: "Page \(number) could not be read."))
            progress?(OCRProgress(pagesDone: done + 1, pagesTotal: wanted.count, currentPage: number))
        }

        return OCRDocumentResult(pageCount: total, pages: results, wasCancelled: cancelled)
    }

    // MARK: Read an image

    /// Reads the text in one image with Vision.
    func recognise(image: CGImage) throws -> OCRImageText {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = options.fast ? .fast : .accurate
        request.usesLanguageCorrection = true
        if options.languages.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = options.languages
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        struct Line { let text: String; let confidence: Float; let midY: CGFloat; let minX: CGFloat }
        var lines: [Line] = []
        for observation in request.results ?? [] {
            guard let best = observation.topCandidates(1).first else { continue }
            let text = best.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, best.confidence >= options.minimumLineConfidence else { continue }
            lines.append(Line(text: text, confidence: best.confidence,
                              midY: observation.boundingBox.midY, minX: observation.boundingBox.minX))
        }

        // Vision's origin is bottom-left: a larger midY is higher on the page.
        lines.sort { a, b in a.midY != b.midY ? a.midY > b.midY : a.minX < b.minX }

        guard !lines.isEmpty else { return OCRImageText(text: "", confidence: 0, lineCount: 0) }
        let mean = lines.reduce(0.0) { $0 + Double($1.confidence) } / Double(lines.count)
        return OCRImageText(text: lines.map(\.text).joined(separator: "\n"), confidence: mean, lineCount: lines.count)
    }

    // MARK: One page (private)

    private func readOnePage(document: PDFDocument, number: Int) -> OCRPageResult {

        guard let page = document.page(at: number - 1) else {
            return OCRPageResult(pageNumber: number, text: "", source: .none, confidence: nil,
                                 failure: "Page \(number) could not be found in the PDF.")
        }

        let embedded = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !options.forceOCR, rbA13_visibleCount(embedded) >= options.embeddedTextThreshold {
            return OCRPageResult(pageNumber: number, text: embedded, source: .embedded, confidence: nil, failure: nil)
        }

        guard let image = rbA13_render(page, dpi: options.dpi, maxLongSide: options.maxLongSidePixels) else {
            return rbA13_fallback(number: number, embedded: embedded,
                                  failure: "Could not draw page \(number); OCR was skipped for that page.")
        }

        do {
            let read = try recognise(image: image)
            if !read.text.isEmpty {
                return OCRPageResult(pageNumber: number, text: read.text, source: .recognised,
                                     confidence: read.confidence, failure: nil)
            }
            // Nothing recognised: keep the little embedded text there is, if any.
            return rbA13_fallback(number: number, embedded: embedded, failure: nil)
        } catch {
            return rbA13_fallback(number: number, embedded: embedded,
                                  failure: "Text recognition failed on page \(number); OCR was skipped for that page.")
        }
    }

    private func rbA13_fallback(number: Int, embedded: String, failure: String?) -> OCRPageResult {
        if embedded.isEmpty {
            return OCRPageResult(pageNumber: number, text: "", source: .none, confidence: nil, failure: failure)
        }
        return OCRPageResult(pageNumber: number, text: embedded, source: .embedded, confidence: nil, failure: failure)
    }
}

// MARK: - Helpers (private)

nonisolated private func rbA13_open(_ url: URL) throws -> PDFDocument {
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw OCRError.cannotOpen("There is no file at that location.")
    }
    guard let document = PDFDocument(url: url) else {
        throw OCRError.cannotOpen("The file is not a readable PDF.")
    }
    if document.isLocked, !document.unlock(withPassword: "") { throw OCRError.locked }
    guard document.pageCount > 0 else { throw OCRError.noPages }
    return document
}

nonisolated private func rbA13_visibleCount(_ text: String) -> Int {
    text.unicodeScalars.reduce(0) { $0 + ($1.properties.isWhitespace ? 0 : 1) }
}

/// Draws a PDF page on a white grey-scale bitmap at the given resolution.
nonisolated private func rbA13_render(_ page: PDFPage, dpi: Double, maxLongSide: Int) -> CGImage? {
    let box = page.bounds(for: .mediaBox)
    guard box.width > 1, box.height > 1 else { return nil }

    var scale = dpi / 72.0
    let longest = Double(max(box.width, box.height)) * scale
    if longest > Double(maxLongSide) { scale *= Double(maxLongSide) / longest }

    let width = Int((Double(box.width) * scale).rounded(.up))
    let height = Int((Double(box.height) * scale).rounded(.up))
    guard width > 0, height > 0 else { return nil }

    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else { return nil }

    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    context.translateBy(x: -box.origin.x, y: -box.origin.y)
    page.draw(with: .mediaBox, to: context)
    return context.makeImage()
}
