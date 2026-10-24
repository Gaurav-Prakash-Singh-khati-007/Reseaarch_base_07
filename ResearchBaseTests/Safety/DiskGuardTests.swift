//
//  DiskGuardTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 3 · Features: F-53 (low-disk and crash safety)
//  The free space is faked, so these tests never fill a real disk.
//

import XCTest
@testable import ResearchBase

@MainActor
final class DiskGuardTests: XCTestCase {

    /// A fake amount of free space the tests can change.
    private final class FreeSpace: @unchecked Sendable {
        var bytes: Int64?
        init(_ bytes: Int64?) { self.bytes = bytes }
    }

    private let mb: Int64 = 1_000_000
    private let gb: Int64 = 1_000_000_000

    private func makeGuard(_ free: FreeSpace) -> DiskGuard {
        DiskGuard(lowBytes: 2 * gb, criticalBytes: 500 * mb, capacity: { _ in free.bytes })
    }

    private func tempFolder() throws -> URL {
        try TestSupport.makeTempDirectory(self)
    }

    private func visibleFiles(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    // MARK: Levels

    func testLevelsFollowTheThresholds() throws {
        let free = FreeSpace(10 * gb)
        let diskGuard = makeGuard(free)
        let folder = try tempFolder()

        XCTAssertEqual(diskGuard.status(for: folder).level, .ok)
        XCTAssertNil(diskGuard.status(for: folder).message)

        free.bytes = 2 * gb - 1
        XCTAssertEqual(diskGuard.status(for: folder).level, .low)
        XCTAssertTrue(diskGuard.status(for: folder).message?.contains("getting full") == true)

        free.bytes = 500 * mb - 1
        XCTAssertEqual(diskGuard.status(for: folder).level, .critical)
        XCTAssertTrue(diskGuard.status(for: folder).message?.contains("almost full") == true)
    }

    func testUnknownFreeSpaceNeverBlocksOrWarns() throws {
        let diskGuard = makeGuard(FreeSpace(nil))
        let folder = try tempFolder()

        let status = diskGuard.status(for: folder)
        XCTAssertEqual(status.level, .ok)
        XCTAssertNil(status.availableBytes)
        XCTAssertEqual(status.availableText, "unknown")
        XCTAssertNoThrow(try diskGuard.ensureRoom(for: 50 * gb, at: folder))
    }

    func testStatusWorksForAPathThatDoesNotExistYet() throws {
        let diskGuard = makeGuard(FreeSpace(10 * gb))
        let notYet = try tempFolder().appendingPathComponent("a/b/c/file.pdf")
        XCTAssertEqual(diskGuard.status(for: notYet).level, .ok)
    }

    func testTheRealSystemReportsSomeFreeSpace() throws {
        let status = DiskGuard().status(for: try tempFolder())
        XCTAssertNotNil(status.availableBytes)
    }

    // MARK: ensureRoom

    func testEnsureRoomKeepsTheReserveFree() throws {
        let free = FreeSpace(1 * gb)
        let diskGuard = makeGuard(free)
        let folder = try tempFolder()

        // 1 GB free, 500 MB reserve: 400 MB fits, 600 MB does not.
        XCTAssertNoThrow(try diskGuard.ensureRoom(for: 400 * mb, at: folder))
        XCTAssertThrowsError(try diskGuard.ensureRoom(for: 600 * mb, at: folder)) { error in
            XCTAssertEqual(error as? DiskGuardError, .notEnoughSpace(needed: 600 * mb, available: 1 * gb))
        }
        // A smaller reserve lets the bigger write through.
        XCTAssertNoThrow(try diskGuard.ensureRoom(for: 600 * mb, at: folder, reserve: 100 * mb))
    }

    // MARK: All-or-nothing writes

    func testWriteAtomicallyCreatesAndReplacesAndLeavesNoTemporaryFiles() throws {
        let diskGuard = makeGuard(FreeSpace(10 * gb))
        let folder = try tempFolder()
        let file = folder.appendingPathComponent("notes.txt")

        try diskGuard.writeAtomically(Data("first".utf8), to: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "first")

        try diskGuard.writeAtomically(Data("second".utf8), to: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "second")

        XCTAssertEqual(try visibleFiles(in: folder), ["notes.txt"])
    }

    func testAWriteThatDoesNotFitTouchesNothing() throws {
        let free = FreeSpace(10 * gb)
        let diskGuard = makeGuard(free)
        let folder = try tempFolder()
        let file = folder.appendingPathComponent("library-export.json")

        try diskGuard.writeAtomically(Data("old and valuable".utf8), to: file)

        free.bytes = 100 * mb
        XCTAssertThrowsError(try diskGuard.writeAtomically(Data("new".utf8), to: file)) { error in
            guard case DiskGuardError.notEnoughSpace = error else {
                return XCTFail("Expected notEnoughSpace, got \(error)")
            }
        }

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "old and valuable")
        XCTAssertEqual(try visibleFiles(in: folder), ["library-export.json"])
    }

    func testAFailedWriteReportsPlainWordsAndLeavesNoTemporaryFile() throws {
        let diskGuard = makeGuard(FreeSpace(10 * gb))
        let folder = try tempFolder()
        let missingFolder = folder.appendingPathComponent("does-not-exist")
        let file = missingFolder.appendingPathComponent("x.txt")

        XCTAssertThrowsError(try diskGuard.writeAtomically(Data("x".utf8), to: file)) { error in
            guard case DiskGuardError.writeFailed = error else {
                return XCTFail("Expected writeFailed, got \(error)")
            }
            XCTAssertTrue((error as? LocalizedError)?.errorDescription?.contains("nothing was changed") == true)
        }
        XCTAssertEqual(try visibleFiles(in: folder), [])
    }

    func testCopyAtomically() throws {
        let diskGuard = makeGuard(FreeSpace(10 * gb))
        let folder = try tempFolder()
        let source = folder.appendingPathComponent("paper.pdf")
        let destination = folder.appendingPathComponent("stored.pdf")
        try Data("pdf bytes".utf8).write(to: source)

        try diskGuard.copyAtomically(from: source, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("pdf bytes".utf8))

        // Copying again over the top works and the source is untouched.
        try Data("newer pdf bytes".utf8).write(to: source)
        try diskGuard.copyAtomically(from: source, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("newer pdf bytes".utf8))
        XCTAssertEqual(try visibleFiles(in: folder), ["paper.pdf", "stored.pdf"])
    }

    func testCopyWithoutRoomLeavesTheDestinationAlone() throws {
        let free = FreeSpace(10 * gb)
        let diskGuard = makeGuard(free)
        let folder = try tempFolder()
        let source = folder.appendingPathComponent("a.pdf")
        let destination = folder.appendingPathComponent("b.pdf")
        try Data("source".utf8).write(to: source)
        try Data("existing".utf8).write(to: destination)

        free.bytes = 10 * mb
        XCTAssertThrowsError(try diskGuard.copyAtomically(from: source, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), Data("existing".utf8))
    }

    // MARK: Crash leftovers

    func testOnlyOldTemporaryFilesAreRemoved() throws {
        let diskGuard = makeGuard(FreeSpace(10 * gb))
        let folder = try tempFolder()
        let sub = folder.appendingPathComponent("drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let oldTemp = sub.appendingPathComponent("\(DiskGuard.temporaryPrefix)old-main.tex")
        let freshTemp = folder.appendingPathComponent("\(DiskGuard.temporaryPrefix)fresh-main.tex")
        let realFile = folder.appendingPathComponent("main.tex")
        for url in [oldTemp, freshTemp, realFile] { try Data("x".utf8).write(to: url) }

        let twoDaysAgo = Date().addingTimeInterval(-2 * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: oldTemp.path)
        try FileManager.default.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: realFile.path)

        XCTAssertEqual(diskGuard.removeStaleTemporaryFiles(in: folder), 1)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldTemp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshTemp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: realFile.path))
    }

    func testNonRecursiveCleanupLeavesSubfoldersAlone() throws {
        let diskGuard = makeGuard(FreeSpace(10 * gb))
        let folder = try tempFolder()
        let sub = folder.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let nested = sub.appendingPathComponent("\(DiskGuard.temporaryPrefix)old-a.pdf")
        try Data("x".utf8).write(to: nested)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3 * 24 * 60 * 60)],
            ofItemAtPath: nested.path
        )

        XCTAssertEqual(diskGuard.removeStaleTemporaryFiles(in: folder, recursive: false), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    // MARK: Banner

    func testBannerAppearsDismissesAndComesBackWhenWorse() throws {
        let free = FreeSpace(10 * gb)
        let monitor = DiskSpaceMonitor(guard: makeGuard(free), watching: try tempFolder())

        XCTAssertFalse(monitor.showsBanner)
        XCTAssertNil(monitor.bannerMessage)

        free.bytes = 1 * gb
        monitor.refresh()
        XCTAssertTrue(monitor.showsBanner)
        XCTAssertTrue(monitor.bannerMessage?.contains("getting full") == true)

        monitor.dismissBanner()
        XCTAssertFalse(monitor.showsBanner)

        // Still low after another check: stays dismissed.
        monitor.refresh()
        XCTAssertFalse(monitor.showsBanner)

        // Gets worse: comes back.
        free.bytes = 100 * mb
        monitor.refresh()
        XCTAssertTrue(monitor.showsBanner)
        XCTAssertTrue(monitor.bannerMessage?.contains("almost full") == true)

        // Recovers, then fills up again: the banner returns.
        free.bytes = 10 * gb
        monitor.refresh()
        XCTAssertFalse(monitor.showsBanner)
        free.bytes = 1 * gb
        monitor.refresh()
        XCTAssertTrue(monitor.showsBanner)
    }

    func testMonitorCanSwitchToAnotherFolder() throws {
        let free = FreeSpace(10 * gb)
        let monitor = DiskSpaceMonitor(guard: makeGuard(free), watching: try tempFolder())
        free.bytes = 300 * mb
        monitor.watch(try tempFolder())
        XCTAssertEqual(monitor.status.level, .critical)
        monitor.stop()
    }

    // MARK: Text

    func testErrorsReadInPlainWords() {
        let text = DiskGuardError.notEnoughSpace(needed: 600 * mb, available: 100 * mb).errorDescription ?? ""
        XCTAssertTrue(text.contains("not enough disk space"))
        XCTAssertTrue(text.contains("Nothing was changed"))
        XCTAssertTrue(DiskGuardError.diskFull.errorDescription?.contains("filled up") == true)
    }
}
