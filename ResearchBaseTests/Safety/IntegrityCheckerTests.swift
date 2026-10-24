//
//  IntegrityCheckerTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 20/10/26.
//


//
//  IntegrityCheckerTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 4 · Features: F-48, F-55
//
//  Every test builds its library in a temporary folder that is removed
//  afterwards. Nothing touches the real library or the real backups folder.
//

import XCTest
import CryptoKit
@testable import ResearchBase

@MainActor
final class IntegrityCheckerTests: XCTestCase {

    // MARK: Helpers

    private func makeLibrary() throws -> Library {
        let folder = try TestSupport.makeTempDirectory(self)
            .appendingPathComponent(Library.folderName, isDirectory: true)
        let library = try Library.open(at: folder)
        addTeardownBlock { library.close() }
        return library
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    private func addItem(_ library: Library, key: String = "smith2024", deleted: Bool = false) throws -> String {
        let id = UUID().uuidString
        let now = Library.nowISO()
        try library.database.run(
            "INSERT INTO items (id, item_type, title, citation_key, added_at, updated_at, deleted_at) VALUES (?, 'article', 'A title', ?, ?, ?, ?)",
            [.text(id), .text(key), .text(now), .text(now), deleted ? .text(now) : .null]
        )
        return id
    }

    /// Adds an attachment row. Writes the file only when `contents` is given.
    @discardableResult
    private func addAttachment(
        _ library: Library,
        itemID: String,
        relPath: String,
        contents: Data?,
        recordedBytes: Int64? = nil,
        recordedSHA: String? = nil,
        deleted: Bool = false
    ) throws -> String {

        let id = UUID().uuidString

        if let contents {
            let url = try library.url(forRelativePath: relPath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url)
        }

        let bytes = recordedBytes ?? Int64(contents?.count ?? 10)
        let sha = recordedSHA ?? (contents.map { sha256Hex($0) } ?? "00")

        try library.database.run(
            """
            INSERT INTO attachments (id, item_id, kind, sha256, rel_path, bytes, added_at, deleted_at)
            VALUES (?, ?, 'pdf', ?, ?, ?, ?, ?)
            """,
            [.text(id), .text(itemID), .text(sha), .text(relPath), .int(bytes), .text(Library.nowISO()),
             deleted ? .text(Library.nowISO()) : .null]
        )
        return id
    }

    private func addLink(_ library: Library, fromType: String, fromID: String, toType: String, toID: String) throws {
        try library.database.run(
            "INSERT INTO links (id, from_type, from_id, to_type, to_id, rel, created_at) VALUES (?, ?, ?, ?, ?, 'related', ?)",
            [.text(UUID().uuidString), .text(fromType), .text(fromID), .text(toType), .text(toID), .text(Library.nowISO())]
        )
    }

    // MARK: F-48 · healthy library

    func testEmptyLibraryIsClean() async throws {
        let library = try makeLibrary()

        let report = try await IntegrityChecker.run(on: library, depth: .deep)

        XCTAssertTrue(report.isClean, report.issues.map(\.title).joined(separator: "; "))
        XCTAssertTrue(report.isHealthy)
        XCTAssertEqual(report.issues.count, 0)
    }

    func testHealthyLibraryWithFilesAndLinksIsClean() async throws {
        let library = try makeLibrary()
        let item = try addItem(library)
        let data = Data("pdf bytes".utf8)

        try addAttachment(library, itemID: item, relPath: "files/ab/one.pdf", contents: data)
        try addLink(library, fromType: "item", fromID: item, toType: "item", toID: item)

        let report = try await IntegrityChecker.run(on: library, depth: .deep)

        XCTAssertTrue(report.isClean, report.issues.map(\.title).joined(separator: "; "))
        XCTAssertEqual(report.attachmentsChecked, 1)
        XCTAssertEqual(report.linksChecked, 1)
        XCTAssertEqual(report.filesOnDisk, 1)
    }

    // MARK: F-48 · files

    func testMissingPDFIsAnError() async throws {
        let library = try makeLibrary()
        let item = try addItem(library)
        let attachment = try addAttachment(library, itemID: item, relPath: "files/ab/gone.pdf", contents: nil)

        let report = try await IntegrityChecker.run(on: library)

        let issue = try XCTUnwrap(report.issues(in: .missingFile).first)
        XCTAssertEqual(issue.severity, .error)
        XCTAssertEqual(issue.entityID, attachment)
        XCTAssertEqual(issue.path, "files/ab/gone.pdf")
        XCTAssertFalse(report.isHealthy)
    }

    func testTrashedAttachmentWithNoFileIsNotReported() async throws {
        let library = try makeLibrary()
        let item = try addItem(library)
        try addAttachment(library, itemID: item, relPath: "files/ab/gone.pdf", contents: nil, deleted: true)

        let report = try await IntegrityChecker.run(on: library)

        XCTAssertEqual(report.issues(in: .missingFile).count, 0)
    }

    func testAttachmentPathOutsideTheLibraryIsReported() async throws {
        let library = try makeLibrary()
        let item = try addItem(library)
        try addAttachment(library, itemID: item, relPath: "../outside.pdf", contents: nil)

        let report = try await IntegrityChecker.run(on: library)

        XCTAssertEqual(report.issues(in: .missingFile).count, 1)
        XCTAssertEqual(report.errorCount, 1)
    }

    func testChangedSizeIsFoundEvenInQuickMode() async throws {
        let library = try makeLibrary()
        let item = try addItem(library)
        try addAttachment(
            library, itemID: item, relPath: "files/ab/one.pdf",
            contents: Data("short".utf8), recordedBytes: 9_999
        )

        let report = try await IntegrityChecker.run(on: library, depth: .quick)

        XCTAssertEqual(report.issues(in: .damagedFile).count, 1)
    }

    func testChangedContentIsFoundOnlyInDeepMode() async throws {
        let library = try makeLibrary()
        let item = try addItem(library)
        let data = Data("same length".utf8)

        // Right size, wrong fingerprint.
        try addAttachment(
            library, itemID: item, relPath: "files/ab/one.pdf",
            contents: data, recordedSHA: sha256Hex(Data("other data".utf8))
        )

        let quick = try await IntegrityChecker.run(on: library, depth: .quick)
        XCTAssertEqual(quick.issues(in: .damagedFile).count, 0)

        let deep = try await IntegrityChecker.run(on: library, depth: .deep)
        XCTAssertEqual(deep.issues(in: .damagedFile).count, 1)
    }

    // MARK: F-48 · orphaned files

    func testUnusedFileIsAWarningAndHiddenFilesAreIgnored() async throws {
        let library = try makeLibrary()

        let stray = try library.url(forRelativePath: "files/zz/stray.bin")
        try FileManager.default.createDirectory(at: stray.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: stray)

        let hidden = try library.url(forRelativePath: "files/.DS_Store")
        try Data("x".utf8).write(to: hidden)

        let report = try await IntegrityChecker.run(on: library)

        let orphans = report.issues(in: .orphanedFile)
        XCTAssertEqual(orphans.count, 1)
        XCTAssertEqual(orphans.first?.path, "files/zz/stray.bin")
        XCTAssertEqual(orphans.first?.severity, .warning)
        XCTAssertTrue(report.isHealthy)
    }

    func testFileOfATrashedAttachmentIsNotAnOrphan() async throws {
        let library = try makeLibrary()
        let item = try addItem(library)
        try addAttachment(
            library, itemID: item, relPath: "files/ab/kept.pdf",
            contents: Data("kept".utf8), deleted: true
        )

        let report = try await IntegrityChecker.run(on: library)

        XCTAssertEqual(report.issues(in: .orphanedFile).count, 0)
    }

    // MARK: F-48 · links

    func testLinkToAMissingRecordIsReported() async throws {
        let library = try makeLibrary()
        let item = try addItem(library)
        try addLink(library, fromType: "item", fromID: item, toType: "thought", toID: "does-not-exist")

        let report = try await IntegrityChecker.run(on: library)

        XCTAssertEqual(report.issues(in: .brokenLink).count, 1)
        XCTAssertEqual(report.warningCount, 1)
    }

    func testLinkToATrashedRecordIsNotBroken() async throws {
        let library = try makeLibrary()
        let live = try addItem(library, key: "live2024")
        let trashed = try addItem(library, key: "trashed2024", deleted: true)
        try addLink(library, fromType: "item", fromID: live, toType: "item", toID: trashed)

        let report = try await IntegrityChecker.run(on: library)

        XCTAssertEqual(report.issues(in: .brokenLink).count, 0)
    }

    func testLinkWithAnUnknownTypeIsReportedOnce() async throws {
        let library = try makeLibrary()
        let item = try addItem(library)
        try addLink(library, fromType: "spaceship", fromID: "x", toType: "item", toID: item)

        let report = try await IntegrityChecker.run(on: library)

        XCTAssertEqual(report.issues(in: .brokenLink).count, 1)
    }

    func testLinkWithBothEndsMissingIsReportedOnce() async throws {
        let library = try makeLibrary()
        try addLink(library, fromType: "item", fromID: "a", toType: "item", toID: "b")

        let report = try await IntegrityChecker.run(on: library)

        XCTAssertEqual(report.issues(in: .brokenLink).count, 1)
    }

    // MARK: F-48 · database

    func testForeignKeyViolationIsReported() async throws {
        let library = try makeLibrary()

        // The library normally refuses this, so switch enforcement off for the insert only.
        try library.database.exec("PRAGMA foreign_keys = OFF")
        try library.database.run(
            """
            INSERT INTO attachments (id, item_id, kind, sha256, rel_path, bytes, added_at)
            VALUES ('a1', 'no-such-item', 'pdf', '00', 'files/x.pdf', 1, ?)
            """,
            [.text(Library.nowISO())]
        )
        try library.database.exec("PRAGMA foreign_keys = ON")

        let report = try await IntegrityChecker.run(on: library)

        XCTAssertEqual(report.issues(in: .foreignKeys).count, 1)
        XCTAssertFalse(report.isHealthy)
    }

    func testSearchIndexCheckPassesOnAFreshLibrary() async throws {
        let library = try makeLibrary()

        let report = try await IntegrityChecker.run(on: library, depth: .deep)

        XCTAssertEqual(report.issues(in: .searchIndex).count, 0)
    }

    // MARK: F-48 · drafts

    func testMissingDraftFolderIsAnError() async throws {
        let library = try makeLibrary()
        let now = Library.nowISO()

        try library.database.run(
            "INSERT INTO drafts (id, title, kind, folder, created_at, updated_at) VALUES ('d1', 'My paper', 'paper', 'drafts/d1/', ?, ?)",
            [.text(now), .text(now)]
        )

        let report = try await IntegrityChecker.run(on: library)

        XCTAssertEqual(report.issues(in: .draftFolder).count, 1)
        XCTAssertEqual(report.issues(in: .draftFolder).first?.severity, .error)
    }

    func testDraftWithFolderAndMainFileIsFineAndStrayFolderIsInfo() async throws {
        let library = try makeLibrary()
        let now = Library.nowISO()

        try library.database.run(
            "INSERT INTO drafts (id, title, kind, folder, created_at, updated_at) VALUES ('d1', 'My paper', 'paper', 'drafts/d1/', ?, ?)",
            [.text(now), .text(now)]
        )

        let draftFolder = library.draftsURL.appendingPathComponent("d1", isDirectory: true)
        try FileManager.default.createDirectory(at: draftFolder, withIntermediateDirectories: true)
        try Data("\\documentclass{article}".utf8).write(to: draftFolder.appendingPathComponent("main.tex"))

        let stray = library.draftsURL.appendingPathComponent("not-a-draft", isDirectory: true)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)

        let report = try await IntegrityChecker.run(on: library)

        let issues = report.issues(in: .draftFolder)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.severity, .info)
        XCTAssertEqual(issues.first?.path, "drafts/not-a-draft")
        XCTAssertEqual(report.errorCount, 0)
        XCTAssertEqual(report.warningCount, 0)
        XCTAssertEqual(report.infoCount, 1)
    }

    // MARK: F-48 · bookkeeping

    func testRunRecordsItsResultAndDeepRunsAreTracked() async throws {
        let library = try makeLibrary()
        XCTAssertNil(IntegrityChecker.lastRun(in: library))
        XCTAssertTrue(IntegrityChecker.isDeepCheckDue(in: library))

        let now = Date()
        _ = try await IntegrityChecker.run(on: library, depth: .quick, now: now)

        let afterQuick = try XCTUnwrap(IntegrityChecker.lastRun(in: library))
        XCTAssertEqual(afterQuick.result, .ok)
        XCTAssertNotNil(afterQuick.at)
        XCTAssertNil(afterQuick.deepAt)
        XCTAssertTrue(IntegrityChecker.isDeepCheckDue(in: library, now: now))

        _ = try await IntegrityChecker.run(on: library, depth: .deep, now: now)

        XCTAssertNotNil(IntegrityChecker.lastRun(in: library)?.deepAt)
        XCTAssertFalse(IntegrityChecker.isDeepCheckDue(in: library, now: now.addingTimeInterval(60)))
        XCTAssertTrue(IntegrityChecker.isDeepCheckDue(
            in: library,
            now: now.addingTimeInterval(IntegrityChecker.deepCheckInterval + 60)
        ))
    }

    func testRecordedResultReflectsProblems() async throws {
        let library = try makeLibrary()
        let item = try addItem(library)
        try addAttachment(library, itemID: item, relPath: "files/ab/gone.pdf", contents: nil)

        _ = try await IntegrityChecker.run(on: library)

        XCTAssertEqual(IntegrityChecker.lastRun(in: library)?.result, .errors)
    }

    func testRecordResultFalseWritesNothing() async throws {
        let library = try makeLibrary()

        _ = try await IntegrityChecker.run(on: library, recordResult: false)

        XCTAssertNil(IntegrityChecker.lastRun(in: library))
    }

    func testRunForLaunchIsDeepFirstThenQuick() async throws {
        let library = try makeLibrary()
        let now = Date()

        let first = try await IntegrityChecker.runForLaunch(on: library, now: now)
        XCTAssertEqual(first.depth, .deep)

        let second = try await IntegrityChecker.runForLaunch(on: library, now: now.addingTimeInterval(3_600))
        XCTAssertEqual(second.depth, .quick)

        let weekLater = try await IntegrityChecker.runForLaunch(
            on: library,
            now: now.addingTimeInterval(IntegrityChecker.deepCheckInterval + 60)
        )
        XCTAssertEqual(weekLater.depth, .deep)
    }

    func testRunDoesNotChangeUserTables() async throws {
        let library = try makeLibrary()
        let item = try addItem(library)
        try addAttachment(library, itemID: item, relPath: "files/ab/gone.pdf", contents: nil)
        try addLink(library, fromType: "item", fromID: "a", toType: "item", toID: "b")

        func counts() throws -> [Int64] {
            try ["items", "attachments", "links", "changes"].map {
                try library.database.scalarInt("SELECT COUNT(*) FROM \($0)") ?? -1
            }
        }

        let before = try counts()
        _ = try await IntegrityChecker.run(on: library, depth: .deep)

        XCTAssertEqual(try counts(), before)
    }

    func testIssuesAreSortedWorstFirstAndTotalsAreTrue() async throws {
        let library = try makeLibrary()
        let item = try addItem(library)

        try addAttachment(library, itemID: item, relPath: "files/ab/gone.pdf", contents: nil)   // error
        try addLink(library, fromType: "item", fromID: "a", toType: "item", toID: "b")          // warning

        let report = try await IntegrityChecker.run(on: library)

        XCTAssertEqual(report.issues.first?.severity, .error)
        XCTAssertEqual(report.issues.last?.severity, .warning)
        XCTAssertEqual(report.totals[.missingFile], 1)
        XCTAssertEqual(report.totals[.brokenLink], 1)
        XCTAssertFalse(report.wasTruncated)
    }

    func testCancellationStopsTheCheck() async throws {
        let library = try makeLibrary()

        let task = Task { () throws -> IntegrityReport in
            try await IntegrityChecker.run(on: library)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled check should throw")
        } catch is CancellationError {
            // expected
        }
    }

    // MARK: F-55 · self-test

    func testSelfTestPassesOnAFreshLibrary() async throws {
        let library = try makeLibrary()

        let report = await IntegrityChecker.runSelfTest(on: library)

        XCTAssertTrue(
            report.passed,
            report.failedChecks.map { "\($0.title): \($0.detail)" }.joined(separator: "; ")
        )
        XCTAssertEqual(report.checks.first { $0.id == "fts5" }?.status, .pass)
        XCTAssertEqual(report.checks.first { $0.id == "schema" }?.status, .pass)
        XCTAssertEqual(report.checks.first { $0.id == "tables" }?.status, .pass)
        XCTAssertEqual(report.checks.first { $0.id == "wal" }?.status, .pass)
        XCTAssertEqual(report.checks.first { $0.id == "folder-write" }?.status, .pass)
    }

    func testSelfTestLeavesNoProbeFileBehind() async throws {
        let library = try makeLibrary()

        _ = await IntegrityChecker.runSelfTest(on: library)

        let names = try FileManager.default.contentsOfDirectory(atPath: library.root.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".rb-selftest-") })
    }

    func testSelfTestFlagsAMissingTable() async throws {
        let library = try makeLibrary()
        try library.database.exec("DROP TABLE capture_log")

        let report = await IntegrityChecker.runSelfTest(on: library)

        XCTAssertFalse(report.passed)
        let tables = try XCTUnwrap(report.checks.first { $0.id == "tables" })
        XCTAssertEqual(tables.status, .fail)
        XCTAssertTrue(tables.detail.contains("capture_log"))
    }

    func testSelfTestNotesAMissingSubfolderAsAWarning() async throws {
        let library = try makeLibrary()
        try FileManager.default.removeItem(at: library.exportsURL)

        let report = await IntegrityChecker.runSelfTest(on: library)

        XCTAssertEqual(report.checks.first { $0.id == "folders" }?.status, .warning)
        XCTAssertTrue(report.passed)
    }

    func testMacOSChangeIsDetectedUntilASelfTestIsRecorded() async throws {
        let library = try makeLibrary()

        XCTAssertTrue(IntegrityChecker.macOSChangedSinceLastSelfTest(in: library))

        let first = await IntegrityChecker.runSelfTest(on: library)
        XCTAssertTrue(first.macOSChangedSinceLastTest)
        XCTAssertFalse(IntegrityChecker.macOSChangedSinceLastSelfTest(in: library))

        // Pretend the last test ran on another macOS.
        try library.database.run(
            "INSERT OR REPLACE INTO meta (key, value) VALUES ('last_selftest_os', 'Version 1.0 (Build 1A1)')"
        )
        XCTAssertTrue(IntegrityChecker.macOSChangedSinceLastSelfTest(in: library))
    }

    // MARK: F-55 · recovery info

    func testRecoveryInfoHasVersionsCountsAndNotes() throws {
        let library = try makeLibrary()
        let item = try addItem(library)
        try addLink(library, fromType: "item", fromID: item, toType: "item", toID: item)

        let info = IntegrityChecker.recoveryInfo(for: library)

        XCTAssertEqual(info.schemaVersionOnDisk, info.schemaVersionSupported)
        XCTAssertFalse(info.sqliteVersion.isEmpty)
        XCTAssertFalse(info.macOSVersion.isEmpty)
        XCTAssertEqual(info.libraryPath, library.root.path)
        XCTAssertNotNil(info.createdAt)
        XCTAssertEqual(info.recordCounts.first { $0.table == "items" }?.count, 1)
        XCTAssertEqual(info.recordCounts.first { $0.table == "links" }?.count, 1)
        XCTAssertFalse(info.rebuildNotes.isEmpty)
        XCTAssertTrue((info.databaseBytes ?? 0) > 0)
    }

    func testRecoveryInfoListsBackupsNewestFirst() throws {
        let library = try makeLibrary()

        let older = library.backupsURL.appendingPathComponent("older.sqlite")
        let newer = library.backupsURL.appendingPathComponent("newer.sqlite")
        try Data("1".utf8).write(to: older)
        try Data("22".utf8).write(to: newer)

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -86_400)],
            ofItemAtPath: older.path
        )

        let info = IntegrityChecker.recoveryInfo(for: library)

        XCTAssertEqual(info.recentBackups.map(\.name), ["newer.sqlite", "older.sqlite"])
        XCTAssertEqual(info.recentBackups.first?.bytes, 2)
    }
}