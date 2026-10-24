//
//  WorkspaceRestoreTests.swift
//  ResearchBaseTests
//
//  F-01: "Restore is tested." A backup restored into an empty
//  workspace must give back every record.
//
//  These tests use papers without PDFs and an empty target, so the
//  restore makes no safety backup and copies no PDFs. That keeps the
//  tests away from the real Application Support folder.
//

import XCTest
import SwiftData
@testable import ResearchBase

@MainActor
final class WorkspaceRestoreTests: XCTestCase {

    func testRestoreIntoEmptyWorkspaceBringsBackEveryRecord() async throws {

        let folder = try TestSupport.makeTempDirectory(self)

        // Source workspace and its backup.
        let source = try TestSupport.makeContext()
        try TestSupport.addSampleData(to: source)
        let originalCounts = try TestSupport.counts(source)

        let backup = try await WorkspaceBackupService.createBackup(
            context: source,
            to: folder.appendingPathComponent("restore-me.researchbase")
        )

        // Empty target.
        let target = try TestSupport.makeContext()
        XCTAssertEqual(try TestSupport.counts(target).values.reduce(0, +), 0)

        let preview = try await WorkspaceRestoreService.preview(
            packageAt: backup.packageURL,
            context: target
        )

        XCTAssertEqual(preview.backupRecordCount, originalCounts.values.reduce(0, +))
        XCTAssertEqual(preview.currentRecordCount, 0)

        _ = try await WorkspaceRestoreService.restore(
            preview: preview,
            userConfirmed: true,
            context: target
        )

        XCTAssertEqual(try TestSupport.counts(target), originalCounts)

        let titles = try target.fetch(FetchDescriptor<PaperRecord>()).map(\.title).sorted()
        XCTAssertEqual(titles, [
            "Communication-Efficient Learning of Deep Networks from Decentralized Data",
            "Federated Optimization in Heterogeneous Networks"
        ])
    }

    func testRestoreRefusesToRunWithoutConfirmation() async throws {

        let folder = try TestSupport.makeTempDirectory(self)

        let source = try TestSupport.makeContext()
        try TestSupport.addSampleData(to: source)

        let backup = try await WorkspaceBackupService.createBackup(
            context: source,
            to: folder.appendingPathComponent("b.researchbase")
        )

        let target = try TestSupport.makeContext()

        let preview = try await WorkspaceRestoreService.preview(
            packageAt: backup.packageURL,
            context: target
        )

        do {
            _ = try await WorkspaceRestoreService.restore(
                preview: preview,
                userConfirmed: false,
                context: target
            )
            XCTFail("Restore must not run without confirmation.")
        } catch WorkspaceRestoreError.notConfirmed {
            // Expected.
        }

        XCTAssertEqual(try TestSupport.counts(target).values.reduce(0, +), 0)
    }

    func testPreviewOfADamagedBackupFailsAndChangesNothing() async throws {

        let folder = try TestSupport.makeTempDirectory(self)

        let source = try TestSupport.makeContext()
        try TestSupport.addSampleData(to: source)

        let backup = try await WorkspaceBackupService.createBackup(
            context: source,
            to: folder.appendingPathComponent("d.researchbase")
        )

        let file = backup.packageURL
            .appendingPathComponent(WorkspaceFormat.workspaceFileName)
        var data = try Data(contentsOf: file)
        data.append(contentsOf: Array(" ".utf8))
        try data.write(to: file)

        let target = try TestSupport.makeContext()

        do {
            _ = try await WorkspaceRestoreService.preview(
                packageAt: backup.packageURL,
                context: target
            )
            XCTFail("A damaged backup must not preview.")
        } catch {
            // Expected.
        }

        XCTAssertEqual(try TestSupport.counts(target).values.reduce(0, +), 0)
    }
}
