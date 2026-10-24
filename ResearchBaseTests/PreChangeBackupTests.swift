//
//  PreChangeBackupTests.swift
//  ResearchBaseTests
//
//  F-01: the gate that must pass before any data-changing code runs.
//

import XCTest
import SwiftData
@testable import ResearchBase

@MainActor
final class PreChangeBackupTests: XCTestCase {

    func testMakeProducesAVerifiedBackupThatMatchesTheWorkspace() async throws {

        let folder = try TestSupport.makeTempDirectory(self)
        let context = try TestSupport.makeContext()
        try TestSupport.addSampleData(to: context)

        let result = try await PreChangeBackup.make(
            reason: "storage migration",
            context: context,
            directory: folder
        )

        XCTAssertEqual(result.entityCounts, try TestSupport.counts(context))
        XCTAssertFalse(result.workspaceWasEmpty)
        XCTAssertTrue(result.packageURL.lastPathComponent.hasPrefix(PreChangeBackup.filePrefix))
        XCTAssertEqual(result.packageURL.deletingLastPathComponent().path, folder.path)

        // It really is a valid package on disk.
        XCTAssertNoThrow(try WorkspaceBackupService.loadPackage(at: result.packageURL))
    }

    func testMakeSavesPendingEditsFirst() async throws {

        let folder = try TestSupport.makeTempDirectory(self)
        let context = try TestSupport.makeContext()

        // Inserted but NOT saved.
        context.insert(
            PaperRecord(pdfFilePath: "", title: "Unsaved", authors: "A", venue: "V", year: 2024)
        )

        let result = try await PreChangeBackup.make(
            reason: "test",
            context: context,
            directory: folder
        )

        XCTAssertEqual(result.entityCounts["Papers"], 1)
    }

    func testEmptyWorkspaceStillGetsAValidBackup() async throws {

        let folder = try TestSupport.makeTempDirectory(self)
        let context = try TestSupport.makeContext()

        let result = try await PreChangeBackup.make(
            reason: "first run",
            context: context,
            directory: folder
        )

        XCTAssertTrue(result.workspaceWasEmpty)
        XCTAssertNoThrow(try WorkspaceBackupService.loadPackage(at: result.packageURL))
    }

    func testReasonCannotEscapeTheBackupFolder() async throws {

        let folder = try TestSupport.makeTempDirectory(self)
        let context = try TestSupport.makeContext()
        try TestSupport.addSampleData(to: context)

        let result = try await PreChangeBackup.make(
            reason: "../../evil/name",
            context: context,
            directory: folder
        )

        XCTAssertEqual(result.packageURL.deletingLastPathComponent().path, folder.path)
        XCTAssertFalse(result.packageURL.lastPathComponent.contains("/"))
        XCTAssertEqual(PreChangeBackup.safeWords("../../evil/name"), "evilname")
        XCTAssertEqual(PreChangeBackup.safeWords("///"), "change")
    }

    func testTwoBackupsInTheSameSecondDoNotOverwriteEachOther() async throws {

        let folder = try TestSupport.makeTempDirectory(self)
        let context = try TestSupport.makeContext()
        try TestSupport.addSampleData(to: context)

        let sameMoment = Date()

        let first = try await PreChangeBackup.make(
            reason: "same", context: context, directory: folder, date: sameMoment
        )
        let second = try await PreChangeBackup.make(
            reason: "same", context: context, directory: folder, date: sameMoment
        )

        XCTAssertNotEqual(first.packageURL, second.packageURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.packageURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.packageURL.path))
    }

    func testFailureChangesNothing() async throws {

        let folder = try TestSupport.makeTempDirectory(self)
        let context = try TestSupport.makeContext()
        try TestSupport.addSampleData(to: context)

        // A regular FILE where the backup folder should be, so a
        // folder cannot be created there.
        let blocker = folder.appendingPathComponent("not-a-folder")
        try Data("x".utf8).write(to: blocker)

        let before = try TestSupport.counts(context)

        do {
            _ = try await PreChangeBackup.make(
                reason: "test",
                context: context,
                directory: blocker.appendingPathComponent("Backups")
            )
            XCTFail("Making a backup inside a file must fail.")
        } catch {
            // Expected.
        }

        XCTAssertEqual(try TestSupport.counts(context), before)
    }

    // MARK: Prune

    private func makeFakeBackup(named name: String, in folder: URL, age: TimeInterval) throws {

        let url = folder.appendingPathComponent(name, isDirectory: true)

        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)],
            ofItemAtPath: url.path
        )
    }

    func testPruneKeepsTheNewestAndOnlyTouchesItsOwnBackups() throws {

        let folder = try TestSupport.makeTempDirectory(self)

        try makeFakeBackup(named: "Before a 1.researchbase", in: folder, age: 400)
        try makeFakeBackup(named: "Before b 2.researchbase", in: folder, age: 300)
        try makeFakeBackup(named: "Before c 3.researchbase", in: folder, age: 200)
        try makeFakeBackup(named: "Before d 4.researchbase", in: folder, age: 100)

        // Not ours. Must never be removed.
        try makeFakeBackup(named: "ResearchBase Safety Backup 1.researchbase", in: folder, age: 900)
        try makeFakeBackup(named: "My own backup.researchbase", in: folder, age: 900)

        let removed = PreChangeBackup.prune(in: folder, keeping: 2)

        XCTAssertEqual(
            Set(removed.map(\.lastPathComponent)),
            ["Before a 1.researchbase", "Before b 2.researchbase"]
        )

        let left = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))

        XCTAssertEqual(left, [
            "Before c 3.researchbase",
            "Before d 4.researchbase",
            "ResearchBase Safety Backup 1.researchbase",
            "My own backup.researchbase"
        ])
    }

    func testPruneAlwaysKeepsAtLeastOne() throws {

        let folder = try TestSupport.makeTempDirectory(self)

        try makeFakeBackup(named: "Before a 1.researchbase", in: folder, age: 200)
        try makeFakeBackup(named: "Before b 2.researchbase", in: folder, age: 100)

        PreChangeBackup.prune(in: folder, keeping: 0)

        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)

        XCTAssertEqual(left, ["Before b 2.researchbase"])
    }

    func testPruneOnMissingFolderDoesNothing() {

        let nowhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")

        XCTAssertTrue(PreChangeBackup.prune(in: nowhere, keeping: 5).isEmpty)
    }
}
