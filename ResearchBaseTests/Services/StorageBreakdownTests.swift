//
//  StorageBreakdownTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 21/10/26.
//


//
//  StorageBreakdownTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 29 · X-04. Builds fake library folders in a temp directory.
//

import XCTest
@testable import ResearchBase

final class StorageBreakdownTests: XCTestCase {

    // MARK: Helpers

    private func makeRoot() throws -> URL {
        let root = try TestSupport.makeTempDirectory(self).appendingPathComponent("lib", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func write(_ root: URL, _ path: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
        return url
    }

    private func measure(_ root: URL) -> StorageBreakdown {
        StorageBreakdown.measure(root: root, mode: .logical)
    }

    // MARK: Sorting into kinds

    func testEveryKindIsCountedUnderItsOwnName() throws {
        let root = try makeRoot()
        try write(root, "files/ab/ab12.pdf", bytes: 1000)
        try write(root, "files/cd/cd34.pdf", bytes: 500)
        try write(root, "library.sqlite", bytes: 300)
        try write(root, "library.sqlite-wal", bytes: 40)
        try write(root, "library.sqlite-shm", bytes: 10)
        try write(root, "drafts/abc/main.tex", bytes: 70)
        try write(root, "drafts/abc/figures/f.png", bytes: 30)
        try write(root, "backups/b1/library.sqlite", bytes: 200)
        try write(root, "inbox/new.pdf", bytes: 60)
        try write(root, "exports/all.json", bytes: 20)
        try write(root, ".DS_Store", bytes: 5)

        let b = measure(root)

        XCTAssertTrue(b.exists)
        XCTAssertEqual(b.bytes(.filesAndPDFs), 1500)
        XCTAssertEqual(b.bytes(.database), 350, "the database file and its -wal and -shm files")
        XCTAssertEqual(b.bytes(.drafts), 100)
        XCTAssertEqual(b.bytes(.backups), 200)
        XCTAssertEqual(b.bytes(.inbox), 60)
        XCTAssertEqual(b.bytes(.exports), 20)
        XCTAssertEqual(b.bytes(.other), 5)
        XCTAssertEqual(b.totalBytes, 2235)
        XCTAssertEqual(b.fileCount(.filesAndPDFs), 2)
        XCTAssertEqual(b.totalFiles, 11)
    }

    func testAlwaysReturnsAllCategoriesInBarOrder() throws {
        let b = measure(try makeRoot())
        XCTAssertEqual(b.entries.map(\.category), StorageCategory.allCases)
        XCTAssertEqual(b.totalBytes, 0)
        XCTAssertTrue(b.exists)
    }

    // MARK: Fractions and the bar

    func testFractionsAddUpToOneAndSkipEmptyKinds() throws {
        let root = try makeRoot()
        try write(root, "files/a.pdf", bytes: 600)
        try write(root, "library.sqlite", bytes: 300)
        try write(root, "drafts/d/main.tex", bytes: 100)

        let b = measure(root)

        XCTAssertEqual(b.fraction(.filesAndPDFs), 0.6, accuracy: 0.0001)
        XCTAssertEqual(b.fraction(.backups), 0)
        XCTAssertEqual(b.segments.map(\.category), [.filesAndPDFs, .database, .drafts])
        XCTAssertEqual(b.segments.map(\.fraction).reduce(0, +), 1, accuracy: 0.0001)
    }

    func testEmptyLibraryHasNoSegmentsAndNoDivisionByZero() throws {
        let b = measure(try makeRoot())
        XCTAssertEqual(b.fraction(.database), 0)
        XCTAssertTrue(b.segments.isEmpty)
    }

    // MARK: Odd folders

    func testMissingFolderIsReportedNotThrown() {
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)")
        let b = measure(gone)
        XCTAssertFalse(b.exists)
        XCTAssertEqual(b.totalBytes, 0)
        XCTAssertNil(b.freeBytes)
    }

    func testAFileInsteadOfAFolderCountsAsMissing() throws {
        let url = try write(try makeRoot(), "just-a-file", bytes: 10)
        XCTAssertFalse(measure(url).exists)
    }

    func testSymbolicLinksAreNotFollowed() throws {
        let root = try makeRoot()
        let outside = try TestSupport.makeTempDirectory(self)
        try Data(count: 100_000).write(to: outside.appendingPathComponent("huge.bin"))

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("files"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("files/link"), withDestinationURL: outside)
        // A loop must not hang either.
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("files/loop"), withDestinationURL: root)

        let b = measure(root)

        XCTAssertLessThan(b.bytes(.filesAndPDFs), 10_000, "the 100 KB file behind the link is not counted")
        XCTAssertEqual(b.fileCount(.filesAndPDFs), 2, "each link counts as one small item")
    }

    func testMeasuringChangesNothing() throws {
        let root = try makeRoot()
        let file = try write(root, "files/a.pdf", bytes: 50)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date

        _ = measure(root)

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["files"])
    }

    // MARK: Size on disk

    func testOnDiskSizeIsNeverSmallerThanTheFileLengths() throws {
        let root = try makeRoot()
        try write(root, "files/a.pdf", bytes: 1)
        try write(root, "files/b.pdf", bytes: 5000)

        let logical = StorageBreakdown.measure(root: root, mode: .logical).totalBytes
        let onDisk = StorageBreakdown.measure(root: root, mode: .onDisk).totalBytes

        XCTAssertEqual(logical, 5001)
        XCTAssertGreaterThanOrEqual(onDisk, logical)
    }

    func testFreeSpaceIsReportedForAnExistingFolder() throws {
        let b = measure(try makeRoot())
        XCTAssertNotNil(b.freeBytes)
        XCTAssertGreaterThan(b.freeBytes ?? 0, 0)
    }

    // MARK: Real library

    func testRealLibraryFolderIsSortedCorrectly() throws {
        let folder = try TestSupport.makeTempDirectory(self)
            .appendingPathComponent(Library.folderName, isDirectory: true)
        let library = try Library.open(at: folder)
        defer { library.close() }
        try Data(count: 123).write(to: library.filesURL.appendingPathComponent("x.pdf"))

        let b = StorageBreakdown.measure(library: library, mode: .logical)

        XCTAssertEqual(b.root, library.root)
        XCTAssertEqual(b.bytes(.filesAndPDFs), 123)
        XCTAssertGreaterThan(b.bytes(.database), 0, "library.sqlite exists after opening")
        XCTAssertEqual(b.bytes(.other), 0, "nothing in a fresh library is unexplained")
    }

    // MARK: Text

    func testFormatAndChipText() throws {
        XCTAssertEqual(StorageBreakdown.format(0), "0 KB")
        XCTAssertTrue(StorageBreakdown.format(86_000_000).contains("MB"))
        XCTAssertTrue(StorageBreakdown.format(4_200_000_000).contains("GB"))

        let root = try makeRoot()
        try write(root, "library.sqlite", bytes: 2_000_000)
        let chip = measure(root).chipText(.database)
        XCTAssertTrue(chip.hasPrefix("Database "), chip)
        XCTAssertTrue(chip.contains("MB"), chip)
    }

    func testDisplayPathUsesTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let inside = home.appendingPathComponent("Documents/ResearchBase Library")
        XCTAssertEqual(measure(inside).displayPath, "~/Documents/ResearchBase Library")

        let outside = URL(fileURLWithPath: "/Volumes/Big/ResearchBase Library")
        XCTAssertEqual(measure(outside).displayPath, "/Volumes/Big/ResearchBase Library")
    }

    func testRevealRefusesAMissingFolder() {
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)")
        XCTAssertFalse(StorageReveal.reveal(gone))
    }

    func testCategoryNamesMatchTheChips() {
        XCTAssertEqual(StorageCategory.filesAndPDFs.displayName, "PDFs and files")
        XCTAssertEqual(StorageCategory.database.displayName, "Database")
        XCTAssertEqual(StorageCategory.backups.displayName, "Backups")
        XCTAssertEqual(StorageCategory.drafts.displayName, "Drafts")
        XCTAssertEqual(StorageCategory.forTopLevelName("library.sqlite-wal"), .database)
        XCTAssertEqual(StorageCategory.forTopLevelName("notes.txt"), .other)
    }
}