//
//  PDFTextIndexerTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 22/10/26.
//


//
//  PDFTextIndexerTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 50 · Features: F-22 (indexing side)
//  Real PDFs are drawn into a temporary library and indexed for real. Free space is faked.
//  Nothing touches the real library or disk.
//

import XCTest
import CoreGraphics
import CoreText
@testable import ResearchBase

@MainActor
final class PDFTextIndexerTests: XCTestCase {

    // MARK: Helpers

    private final class FreeSpace: @unchecked Sendable {
        var bytes: Int64?
        init(_ bytes: Int64?) { self.bytes = bytes }
    }

    private let gb: Int64 = 1_000_000_000
    private let mb: Int64 = 1_000_000

    private struct Rig {
        let model: LibraryModel
        let search: SearchService
        let indexer: PDFTextIndexer
        let defaults: UserDefaults
        let space: FreeSpace
        let itemID: String
    }

    private func makeRig(recognise: Bool = true, indexInBackground: Bool = true) throws -> Rig {
        let model = try ModelTestSupport.makeModel(self)
        addTeardownBlock { model.library.close() }

        let name = "PDFTextIndexerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        defaults.set(recognise, forKey: PDFIndexingSettings.recogniseScannedKey)
        defaults.set(indexInBackground, forKey: PDFIndexingSettings.indexInBackgroundKey)

        let space = FreeSpace(50 * gb)
        let search = SearchService(model: model)
        let indexer = PDFTextIndexer(
            model: model,
            search: search,
            diskGuard: DiskGuard(lowBytes: 2 * gb, criticalBytes: 500 * mb, capacity: { _ in space.bytes }),
            defaults: defaults
        )
        let item = try ModelTestSupport.item(model)
        return Rig(model: model, search: search, indexer: indexer, defaults: defaults, space: space, itemID: item.id)
    }

    /// Draws a PDF. A string is a page with that text; nil is a blank page (nothing to read).
    private func makePDF(pages: [String?], at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for text in pages {
            context.beginPDFPage(nil)
            if let text {
                let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
                let attributed = NSAttributedString(
                    string: text,
                    attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
                )
                let line = CTLineCreateWithAttributedString(attributed)
                context.textPosition = CGPoint(x: 72, y: 700)
                CTLineDraw(line, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// Stores a PDF the way the app does and records it. Returns the relative path.
    @discardableResult
    private func addPDF(_ rig: Rig, id: String = "a1", itemID: String? = nil, pages: [String?]) throws -> String {
        let sha = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let relative = "files/\(sha.prefix(2))/\(sha).pdf"
        let url = rig.model.library.root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makePDF(pages: pages, at: url)
        try insertAttachment(rig, id: id, itemID: itemID ?? rig.itemID, sha: sha, relative: relative)
        return relative
    }

    private func insertAttachment(_ rig: Rig, id: String, itemID: String, sha: String, relative: String) throws {
        _ = try rig.model.database.run(
            "INSERT INTO attachments (id, item_id, kind, is_primary, sha256, rel_path, original_name, bytes, added_at) VALUES (?, ?, 'pdf', 0, ?, ?, 'paper.pdf', 1, ?)",
            [.text(id), .text(itemID), .text(sha), .text(relative), .text(Library.nowISO())]
        )
    }

    /// Reads one column as text. The CAST matters: `scalarText` returns nil for
    /// INTEGER columns such as `pages` and `has_text`. CAST(NULL AS TEXT) is still NULL,
    /// so the XCTAssertNil checks keep working.
    private func column(_ rig: Rig, _ name: String, id: String = "a1") throws -> String? {
        try rig.model.database.scalarText(
            "SELECT CAST(\(name) AS TEXT) FROM attachments WHERE id = ?",
            [.text(id)]
        )
    }

    private let threePages: [String?] = [
        "Alpha page about wombats and rivers",
        "Second page about the quokka habitat",
        "Third page about kangaroo mathematics"
    ]

    // MARK: Good PDFs

    func testIndexesEmbeddedTextAndSearchFindsThePage() async throws {
        let rig = try makeRig()
        try addPDF(rig, pages: threePages)

        let summary = await rig.indexer.run()

        XCTAssertEqual(summary.outcomes.first?.status, .indexed(pages: 3, ocrPages: 0), summary.headline)
        let hit = try XCTUnwrap(rig.search.searchPDF("quokka").hits.first)
        XCTAssertEqual(hit.attachmentID, "a1")
        XCTAssertEqual(hit.itemID, rig.itemID)
        XCTAssertEqual(hit.page, 2)

        XCTAssertNotNil(try column(rig, "indexed_at"))
        XCTAssertEqual(try column(rig, "pages"), "3")
        XCTAssertEqual(try column(rig, "has_text"), "1")
        XCTAssertEqual(try column(rig, "ocr_state"), "none")
        XCTAssertFalse(rig.indexer.isRunning)
        XCTAssertNil(rig.indexer.progress)
        XCTAssertTrue(rig.indexer.backlog.isEmpty)
    }

    func testSecondRunDoesNothingAndNeverDuplicates() async throws {
        let rig = try makeRig()
        try addPDF(rig, pages: threePages)

        _ = await rig.indexer.run()
        let second = await rig.indexer.run()

        XCTAssertTrue(second.outcomes.isEmpty)
        XCTAssertEqual(second.headline, "Nothing to index.")
        XCTAssertEqual(try rig.search.searchPDF("quokka").total, 1)
    }

    func testIndexNowIndexesOnlyThatPDF() async throws {
        let rig = try makeRig()
        try addPDF(rig, id: "a1", pages: ["First file talks about the platypus family"])
        try addPDF(rig, id: "a2", pages: ["Second file talks about the echidna family"])

        let outcome = await rig.indexer.indexNow(attachmentID: "a2")

        XCTAssertEqual(outcome.status, .indexed(pages: 1, ocrPages: 0))
        XCTAssertEqual(try rig.search.searchPDF("echidna").total, 1)
        XCTAssertEqual(try rig.search.searchPDF("platypus").total, 0)
        XCTAssertNil(try column(rig, "indexed_at", id: "a1"))
        XCTAssertEqual(rig.indexer.backlog.unindexed, 1)

        let again = await rig.indexer.indexNow(attachmentID: "a2")
        XCTAssertEqual(again.status, .alreadyIndexed)
    }

    // MARK: Scanned pages and the OCR switch

    func testScannedPagesWaitWhenRecognitionIsOffThenAreReadWhenItIsOn() async throws {
        let rig = try makeRig(recognise: false)
        try addPDF(rig, pages: ["Alpha page about wombats and rivers", nil])

        let first = await rig.indexer.run()

        XCTAssertEqual(first.outcomes.first?.status, .waitingForOCR(indexedPages: 1), first.headline)
        XCTAssertEqual(try column(rig, "ocr_state"), "queued")
        XCTAssertNotNil(try column(rig, "indexed_at"))
        XCTAssertEqual(rig.indexer.backlog.waitingForOCR, 1)
        XCTAssertEqual(try rig.search.searchPDF("wombats").total, 1)

        // Switched off: running again leaves the queue alone.
        let idle = await rig.indexer.run()
        XCTAssertTrue(idle.outcomes.isEmpty)
        XCTAssertEqual(try column(rig, "ocr_state"), "queued")

        // Switched on: only the scanned page is read, the first page is not indexed twice.
        rig.defaults.set(true, forKey: PDFIndexingSettings.recogniseScannedKey)
        let second = await rig.indexer.run()

        XCTAssertEqual(second.outcomes.count, 1)
        XCTAssertEqual(try column(rig, "ocr_state"), "done")
        XCTAssertEqual(try rig.search.searchPDF("wombats").total, 1, "no duplicate rows")
        XCTAssertTrue(rig.indexer.backlog.isEmpty)
    }

    func testBlankPDFWithRecognitionOnFindsNoText() async throws {
        let rig = try makeRig(recognise: true)
        try addPDF(rig, pages: [nil])

        let summary = await rig.indexer.run()

        XCTAssertEqual(summary.outcomes.first?.status, .noTextFound, summary.headline)
        XCTAssertEqual(try column(rig, "has_text"), "0")
        XCTAssertEqual(try column(rig, "ocr_state"), "done")
        XCTAssertNotNil(try column(rig, "indexed_at"), "not retried every run")
    }

    // MARK: Bad and missing files

    func testMissingFileIsReportedAndStaysPending() async throws {
        let rig = try makeRig()
        let relative = try addPDF(rig, pages: threePages)
        try FileManager.default.removeItem(at: rig.model.library.root.appendingPathComponent(relative))

        let summary = await rig.indexer.run()

        XCTAssertEqual(summary.outcomes.first?.status, .missingFile)
        XCTAssertEqual(summary.problemCount, 1)
        XCTAssertNil(try column(rig, "indexed_at"), "it may come back, for example after a restore")
        XCTAssertEqual(rig.indexer.backlog.unindexed, 1)
    }

    func testUnreadableFileIsMarkedSoItIsNotRetried() async throws {
        let rig = try makeRig()
        let relative = try addPDF(rig, pages: threePages)
        try Data("this is not a pdf".utf8).write(to: rig.model.library.root.appendingPathComponent(relative))

        let first = await rig.indexer.run()

        guard case .unreadable = first.outcomes.first?.status else {
            return XCTFail("expected unreadable, got \(String(describing: first.outcomes.first?.status))")
        }
        XCTAssertEqual(try column(rig, "ocr_state"), "failed")
        XCTAssertNotNil(try column(rig, "indexed_at"))

        let second = await rig.indexer.run()
        XCTAssertTrue(second.outcomes.isEmpty)
    }

    func testOneBadPDFDoesNotStopTheOthers() async throws {
        let rig = try makeRig()
        let bad = try addPDF(rig, id: "a1", pages: threePages)
        try Data("broken".utf8).write(to: rig.model.library.root.appendingPathComponent(bad))
        try addPDF(rig, id: "a2", pages: ["A good file about the numbat and friends"])

        let summary = await rig.indexer.run()

        XCTAssertEqual(summary.outcomes.count, 2)
        XCTAssertEqual(summary.indexedCount, 1)
        XCTAssertEqual(summary.problemCount, 1)
        XCTAssertEqual(try rig.search.searchPDF("numbat").total, 1)
    }

    // MARK: What is skipped

    func testTrashedItemsAndDeletedAttachmentsAreSkipped() async throws {
        let rig = try makeRig()
        let other = try ModelTestSupport.item(rig.model, title: "Another paper", author: "Roe", given: "R")
        try addPDF(rig, id: "a1", itemID: rig.itemID, pages: ["Kept file about the dingo and the outback"])
        try addPDF(rig, id: "a2", itemID: other.id, pages: ["Trashed file about the emu and the outback"])
        try addPDF(rig, id: "a3", itemID: rig.itemID, pages: ["Deleted file about the wallaby and more"])

        try ModelTestSupport.trash(rig.model, itemID: other.id)
        _ = try rig.model.database.run("UPDATE attachments SET deleted_at = ? WHERE id = 'a3'", [.text(Library.nowISO())])

        let summary = await rig.indexer.run()

        XCTAssertEqual(summary.outcomes.map(\.attachmentID), ["a1"])
        XCTAssertNil(try column(rig, "indexed_at", id: "a2"))
        XCTAssertNil(try column(rig, "indexed_at", id: "a3"))
    }

    func testNonPDFAttachmentsAreSkipped() async throws {
        let rig = try makeRig()
        _ = try rig.model.database.run(
            "INSERT INTO attachments (id, item_id, kind, sha256, rel_path, bytes, added_at) VALUES ('s1', ?, 'supplement', 'x', 'files/x.zip', 1, ?)",
            [.text(rig.itemID), .text(Library.nowISO())]
        )

        let summary = await rig.indexer.run()

        XCTAssertTrue(summary.outcomes.isEmpty)
    }

    // MARK: Low disk

    func testLowDiskStopsTheRunAndItContinuesWhenThereIsRoom() async throws {
        let rig = try makeRig()
        try addPDF(rig, pages: threePages)

        rig.space.bytes = 100 * mb
        let stopped = await rig.indexer.run()

        XCTAssertTrue(stopped.outcomes.isEmpty)
        XCTAssertNotNil(stopped.stoppedReason)
        XCTAssertTrue(stopped.headline.contains("disk"))
        XCTAssertNil(try column(rig, "indexed_at"))

        rig.space.bytes = 50 * gb
        let resumed = await rig.indexer.run()
        XCTAssertEqual(resumed.indexedCount, 1)
    }

    // MARK: Cancel, background, rebuild

    func testCancelledRunStoresNothing() async throws {
        let rig = try makeRig()
        try addPDF(rig, pages: threePages)

        rig.indexer.start(force: true)
        rig.indexer.cancel()
        await rig.indexer.waitUntilIdle()

        XCTAssertEqual(rig.indexer.lastSummary?.wasCancelled, true)
        XCTAssertNil(try column(rig, "indexed_at"))
        XCTAssertEqual(try rig.search.searchPDF("quokka").total, 0)

        // The next run indexes it in full.
        let summary = await rig.indexer.run()
        XCTAssertEqual(summary.indexedCount, 1)
        XCTAssertEqual(try rig.search.searchPDF("quokka").total, 1)
    }

    func testBackgroundStartFollowsTheSettingUnlessForced() async throws {
        let rig = try makeRig(indexInBackground: false)
        try addPDF(rig, pages: threePages)

        rig.indexer.start()
        await rig.indexer.waitUntilIdle()
        XCTAssertNil(try column(rig, "indexed_at"), "background indexing is switched off")

        rig.indexer.start(force: true)
        await rig.indexer.waitUntilIdle()
        XCTAssertNotNil(try column(rig, "indexed_at"))
        XCTAssertEqual(try rig.search.searchPDF("quokka").total, 1)
    }

    func testRebuildAllReadsEverythingAgainWithoutDuplicates() async throws {
        let rig = try makeRig()
        try addPDF(rig, pages: threePages)
        _ = await rig.indexer.run()

        let summary = await rig.indexer.rebuildAll()

        XCTAssertEqual(summary.indexedCount, 1)
        XCTAssertEqual(try rig.search.searchPDF("quokka").total, 1)
        XCTAssertEqual(try rig.search.searchPDF("kangaroo").total, 1)
    }

    // MARK: Status line and settings

    func testStatusTextFollowsTheBacklog() async throws {
        let rig = try makeRig()
        XCTAssertEqual(rig.indexer.statusText, "Search index is up to date.")

        try addPDF(rig, pages: threePages)
        rig.indexer.refreshBacklog()
        XCTAssertEqual(rig.indexer.statusText, "1 PDF is waiting to be indexed.")

        _ = await rig.indexer.run()
        XCTAssertEqual(rig.indexer.statusText, "Search index is up to date.")
    }

    func testSettingsDefaultToOn() {
        let name = "PDFTextIndexerTests-defaults-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }

        XCTAssertTrue(PDFIndexingSettings.value(forKey: PDFIndexingSettings.indexInBackgroundKey, default: true, in: defaults))
        XCTAssertTrue(PDFIndexingSettings.value(forKey: PDFIndexingSettings.recogniseScannedKey, default: true, in: defaults))

        defaults.set(false, forKey: PDFIndexingSettings.recogniseScannedKey)
        XCTAssertFalse(PDFIndexingSettings.value(forKey: PDFIndexingSettings.recogniseScannedKey, default: true, in: defaults))
    }

    func testSummaryHeadlines() {
        var summary = PDFIndexSummary()
        XCTAssertEqual(summary.headline, "Nothing to index.")

        summary.outcomes = [
            PDFIndexOutcome(attachmentID: "a", title: "A", status: .indexed(pages: 2, ocrPages: 0)),
            PDFIndexOutcome(attachmentID: "b", title: "B", status: .missingFile)
        ]
        XCTAssertEqual(summary.headline, "Indexed 1 PDF. 1 PDF could not be indexed.")
        XCTAssertEqual(PDFIndexSummary(wasBusy: true).headline, "Indexing is already running.")
    }
}
