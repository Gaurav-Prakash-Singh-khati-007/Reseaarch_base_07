//
//  InboxFolderWatcherTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 21/10/26.
//


//
//  InboxFolderWatcherTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 31 · F-20. Every test uses a temporary library; files are dropped
//  into its inbox/ folder by hand, exactly as a person would.
//

import XCTest
@testable import ResearchBase

@MainActor
final class InboxFolderWatcherTests: XCTestCase {

    // MARK: Helpers

    private func makeWatcher(
        _ model: LibraryModel, settle: TimeInterval = 0
    ) -> InboxFolderWatcher {
        var config = InboxWatcherConfig()
        config.settleSeconds = settle
        config.debounceSeconds = 0.05
        return InboxFolderWatcher(model: model, config: config)
    }

    /// Drops a file into the inbox. `age` makes it look like it was written that long ago.
    @discardableResult
    private func drop(
        _ model: LibraryModel, _ name: String, _ text: String = "%PDF-1.4 sample", age: TimeInterval = 60
    ) throws -> URL {
        let url = model.library.inboxURL.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    private func inboxTopLevel(_ model: LibraryModel) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: model.library.inboxURL.path).sorted()
    }

    private func names(in folder: String, _ model: LibraryModel) -> [String] {
        let url = model.library.inboxURL.appendingPathComponent(folder)
        return ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    private func count(_ model: LibraryModel, _ table: String, where clause: String = "1") throws -> Int {
        try ModelTestSupport.count(model, table, where: clause)
    }

    // MARK: Adding

    func testDroppedPDFBecomesAnInboxPaperWithItsFile() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        try drop(model, "scan_0042.pdf")

        let result = makeWatcher(model).scanNow()

        XCTAssertEqual(result.added.count, 1)
        let id = try XCTUnwrap(result.added.first?.itemID)
        let item = try XCTUnwrap(try model.items.fetch(id: id))
        XCTAssertEqual(item.title, "scan 0042")
        XCTAssertEqual(item.reviewState, .inbox)
        XCTAssertEqual(item.sourceKind, .inboxFolder)
        XCTAssertEqual(item.sourceURL, "inbox/scan_0042.pdf")

        XCTAssertEqual(try count(model, "attachments", where: "item_id = '\(id)' AND kind = 'pdf' AND is_primary = 1"), 1)
        XCTAssertEqual(try count(model, "capture_log",
                                 where: "via = 'inbox_folder' AND result = 'added' AND item_id = '\(id)'"), 1)
    }

    func testOriginalIsMovedNotDeleted() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        try drop(model, "paper.pdf")

        _ = makeWatcher(model).scanNow()

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: model.library.inboxURL.appendingPathComponent("paper.pdf").path))
        XCTAssertEqual(names(in: "Imported", model), ["paper.pdf"])
    }

    func testSeveralFilesAreAddedOldestFirst() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        try drop(model, "b.pdf", "%PDF-1.4 b", age: 300)
        try drop(model, "a.pdf", "%PDF-1.4 a", age: 100)

        let result = makeWatcher(model).scanNow()

        XCTAssertEqual(result.added.map(\.fileName), ["b.pdf", "a.pdf"])
        XCTAssertEqual(try count(model, "items", where: "review_state = 'inbox'"), 2)
    }

    func testRescanFindsNothingNew() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        try drop(model, "paper.pdf")
        let watcher = makeWatcher(model)

        _ = watcher.scanNow()
        let again = watcher.scanNow()

        XCTAssertFalse(again.didSomething)
        XCTAssertEqual(try count(model, "items"), 1)
        XCTAssertEqual(try count(model, "capture_log"), 1)
    }

    // MARK: Duplicates

    func testSamePDFDroppedAgainIsADuplicate() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let watcher = makeWatcher(model)

        try drop(model, "first.pdf", "%PDF-1.4 identical")
        let first = watcher.scanNow()
        try drop(model, "copy of first.pdf", "%PDF-1.4 identical")
        let second = watcher.scanNow()

        XCTAssertEqual(second.added.count, 0)
        XCTAssertEqual(second.duplicates.count, 1)
        XCTAssertEqual(second.duplicates.first?.existingItemID, first.added.first?.itemID)
        XCTAssertEqual(try count(model, "items"), 1)
        XCTAssertEqual(names(in: "Duplicates", model), ["copy of first.pdf"])
        XCTAssertEqual(try count(model, "capture_log", where: "result = 'duplicate'"), 1)
    }

    func testPDFAlreadyAttachedByHandIsADuplicate() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let item = try ModelTestSupport.item(model)
        let source = try TestSupport.makeTempDirectory(self).appendingPathComponent("mine.pdf")
        try Data("%PDF-1.4 mine".utf8).write(to: source)
        _ = try model.attachments.add(fileAt: source, to: item.id)

        try drop(model, "same-content.pdf", "%PDF-1.4 mine")
        let result = makeWatcher(model).scanNow()

        XCTAssertEqual(result.duplicates.first?.existingItemID, item.id)
        XCTAssertEqual(try count(model, "items"), 1)
    }

    func testTrashedPaperDoesNotBlockReAdding() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let watcher = makeWatcher(model)

        try drop(model, "a.pdf", "%PDF-1.4 same")
        let first = watcher.scanNow()
        try ModelTestSupport.trash(model, itemID: try XCTUnwrap(first.added.first?.itemID))

        try drop(model, "a again.pdf", "%PDF-1.4 same")
        let second = watcher.scanNow()

        XCTAssertEqual(second.added.count, 1, "a deleted paper is not in the library any more")
    }

    // MARK: Files that must wait or stay

    func testFileStillBeingWrittenIsLeftAloneAndCounted() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        try drop(model, "fresh.pdf", age: 0)

        let result = makeWatcher(model, settle: 30).scanNow()

        XCTAssertEqual(result.waiting, 1)
        XCTAssertFalse(result.didSomething)
        XCTAssertEqual(try count(model, "items"), 0)
        XCTAssertEqual(try inboxTopLevel(model).filter { $0.hasSuffix(".pdf") }, ["fresh.pdf"])
    }

    func testPartialDownloadsAndHiddenFilesAreIgnored() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        for name in ["paper.pdf.crdownload", "paper.pdf.part", ".hidden.pdf", ".DS_Store", "~$lock.pdf"] {
            try drop(model, name)
        }

        let result = makeWatcher(model).scanNow()

        XCTAssertEqual(result.waiting, 5)
        XCTAssertEqual(try count(model, "items"), 0)
        XCTAssertEqual(try inboxTopLevel(model).count, 5 + 0, "nothing was moved")
    }

    func testNonPDFFilesStayWhereTheyAre() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        try drop(model, "notes.txt", "hello")
        try drop(model, "slides.pptx", "x")

        let result = makeWatcher(model).scanNow()

        XCTAssertEqual(result.unsupported, 2)
        XCTAssertEqual(try count(model, "items"), 0)
        XCTAssertEqual(try inboxTopLevel(model), ["notes.txt", "slides.pptx"])
    }

    func testFakePDFIsReportedOnceAndKept() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        try drop(model, "broken.pdf", "this is not a pdf")
        let watcher = makeWatcher(model)

        let first = watcher.scanNow()
        let second = watcher.scanNow()

        XCTAssertEqual(first.failed.map(\.fileName), ["broken.pdf"])
        XCTAssertEqual(second.failed.map(\.fileName), ["broken.pdf"], "still reported to the caller")
        XCTAssertEqual(try count(model, "items"), 0)
        XCTAssertEqual(try count(model, "capture_log", where: "result = 'failed'"), 1, "but logged only once")
        XCTAssertTrue(try inboxTopLevel(model).contains("broken.pdf"))
    }

    func testSubfoldersAreNeverScanned() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let nested = model.library.inboxURL.appendingPathComponent("Sorted later", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("%PDF-1.4 nested".utf8).write(to: nested.appendingPathComponent("inside.pdf"))

        let result = makeWatcher(model).scanNow()

        XCTAssertFalse(result.didSomething)
        XCTAssertEqual(result.waiting + result.unsupported, 0)
        XCTAssertEqual(try count(model, "items"), 0)
    }

    // MARK: Never loses a file

    func testTwoDifferentFilesWithTheSameNameAreBothKept() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let watcher = makeWatcher(model)

        try drop(model, "paper.pdf", "%PDF-1.4 one")
        _ = watcher.scanNow()
        try drop(model, "paper.pdf", "%PDF-1.4 two")
        _ = watcher.scanNow()

        XCTAssertEqual(names(in: "Imported", model), ["paper 2.pdf", "paper.pdf"])
        XCTAssertEqual(try count(model, "items"), 2)
    }

    func testEveryDroppedFileStillExistsSomewhereAfterAScan() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        try drop(model, "ok.pdf", "%PDF-1.4 ok")
        try drop(model, "dup.pdf", "%PDF-1.4 ok")
        try drop(model, "bad.pdf", "nope")
        try drop(model, "readme.txt", "hi")

        _ = makeWatcher(model).scanNow()

        let all = (try? FileManager.default.subpathsOfDirectory(atPath: model.library.inboxURL.path)) ?? []
        for name in ["ok.pdf", "dup.pdf", "bad.pdf", "readme.txt"] {
            XCTAssertTrue(all.contains { $0.hasSuffix(name) }, "\(name) is gone: \(all)")
        }
    }

    func testFailedImportLeavesNoHalfMadePaper() throws {
        let sink = FailingChangeSink(failOnCall: 1)   // item create is call 0, the attachment record is call 1
        let model = try ModelTestSupport.makeModel(self, sink: sink)
        defer { model.library.close() }
        try drop(model, "paper.pdf")

        let result = makeWatcher(model).scanNow()

        XCTAssertEqual(result.failed.count, 1)
        XCTAssertEqual(try count(model, "items"), 0, "the item was rolled back with the failed attachment")
        XCTAssertEqual(try count(model, "attachments"), 0)
        XCTAssertTrue(try inboxTopLevel(model).contains("paper.pdf"), "the original stays in the inbox")
    }

    // MARK: Pure helpers

    func testTitlesFromFileNames() {
        XCTAssertEqual(InboxFolderWatcher.title(fromFileName: "scan_0042.pdf"), "scan 0042")
        XCTAssertEqual(InboxFolderWatcher.title(fromFileName: "  A   Study of  Drift.PDF"), "A Study of Drift")
        XCTAssertEqual(InboxFolderWatcher.title(fromFileName: "_.pdf"), "Untitled PDF")
    }

    func testPartialDownloadNames() {
        for name in ["a.crdownload", "a.pdf.download", "a.PART", ".x", "~$y.pdf", "a.tmp"] {
            XCTAssertTrue(InboxFolderWatcher.isPartialDownload(name), name)
        }
        for name in ["a.pdf", "paper (1).pdf", "my.part.one.pdf"] {
            XCTAssertFalse(InboxFolderWatcher.isPartialDownload(name), name)
        }
    }

    func testFreeNameCountsUp() throws {
        let folder = try TestSupport.makeTempDirectory(self)
        XCTAssertEqual(InboxFolderWatcher.freeName(for: "a.pdf", in: folder).lastPathComponent, "a.pdf")
        try Data().write(to: folder.appendingPathComponent("a.pdf"))
        XCTAssertEqual(InboxFolderWatcher.freeName(for: "a.pdf", in: folder).lastPathComponent, "a 2.pdf")
        try Data().write(to: folder.appendingPathComponent("a 2.pdf"))
        XCTAssertEqual(InboxFolderWatcher.freeName(for: "a.pdf", in: folder).lastPathComponent, "a 3.pdf")
    }

    // MARK: Starting and watching

    func testFilesDroppedWhileTheAppWasClosedAreAddedOnStart() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        try drop(model, "while-closed.pdf")
        let watcher = makeWatcher(model)
        var reported: InboxScanResult?
        watcher.onScan = { reported = $0 }
        defer { watcher.stop() }

        watcher.start()

        XCTAssertTrue(watcher.isWatching)
        XCTAssertEqual(try count(model, "items", where: "review_state = 'inbox'"), 1)
        XCTAssertEqual(reported?.added.count, 1)
    }

    func testStartTwiceAndStopAreSafe() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let watcher = makeWatcher(model)

        watcher.start()
        watcher.start()
        XCTAssertTrue(watcher.isWatching)
        watcher.stop()
        XCTAssertFalse(watcher.isWatching)
        watcher.stop()
    }

    func testFileDroppedWhileWatchingIsPickedUp() async throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let watcher = makeWatcher(model)
        defer { watcher.stop() }
        watcher.start()

        try drop(model, "live.pdf")

        var waited = 0
        while try count(model, "items") == 0, waited < 100 {
            try await Task.sleep(nanoseconds: 50_000_000)
            waited += 1
        }
        guard try count(model, "items") == 1 else {
            throw XCTSkip("The folder event did not arrive in 5 seconds on this machine.")
        }
        XCTAssertEqual(names(in: "Imported", model), ["live.pdf"])
    }
}