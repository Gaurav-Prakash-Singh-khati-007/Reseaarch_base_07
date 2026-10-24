//
//  WorkspaceBackupTests.swift
//  ResearchBaseTests
//
//  F-01 / F-03: a backup must be complete, must be checked when it is
//  read back, and must refuse damaged or unsafe packages.
//

import XCTest
import SwiftData
@testable import ResearchBase

@MainActor
final class WorkspaceBackupTests: XCTestCase {

    // MARK: Helpers

    private func makeBackup(
        pdf: Bool = false
    ) async throws -> (context: ModelContext, result: WorkspaceBackupResult, folder: URL) {

        let folder = try TestSupport.makeTempDirectory(self)
        let context = try TestSupport.makeContext()

        var pdfPath = ""

        if pdf {
            pdfPath = try TestSupport.makeFakePDF(in: folder).path
        }

        try TestSupport.addSampleData(to: context, pdfPath: pdfPath)

        let result = try await WorkspaceBackupService.createBackup(
            context: context,
            to: folder.appendingPathComponent("test.researchbase")
        )

        return (context, result, folder)
    }

    private func assertThrowsBackupError(
        _ expression: () throws -> Void,
        matches check: (WorkspaceBackupError) -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            try expression()
            XCTFail("Expected an error. \(message)", file: file, line: line)
        } catch let error as WorkspaceBackupError {
            XCTAssertTrue(check(error), "\(message) Got: \(error)", file: file, line: line)
        } catch {
            XCTFail("Wrong error type: \(error). \(message)", file: file, line: line)
        }
    }

    // MARK: Tests

    func testBackupKeepsEveryRecordCount() async throws {

        let (context, result, _) = try await makeBackup()
        let live = try TestSupport.counts(context)

        XCTAssertEqual(result.manifest.entityCounts, live)
        XCTAssertEqual(result.manifest.entityCounts["Papers"], 2)
        XCTAssertEqual(result.manifest.entityCounts["Research Notes"], 1)
        XCTAssertEqual(result.manifest.entityCounts["Tasks"], 1)
        XCTAssertEqual(result.manifest.entityCounts["PDF Annotations"], 1)
    }

    func testBackupCanBeReadBackAndVerified() async throws {

        let (_, result, _) = try await makeBackup()

        let loaded = try WorkspaceBackupService.loadPackage(at: result.packageURL)

        XCTAssertEqual(loaded.snapshot.papers.count, 2)
        XCTAssertTrue(loaded.pdfProblems.isEmpty)
    }

    func testBackupNeverChangesTheDatabase() async throws {

        let folder = try TestSupport.makeTempDirectory(self)
        let context = try TestSupport.makeContext()
        try TestSupport.addSampleData(to: context)

        let before = try TestSupport.counts(context)

        _ = try await WorkspaceBackupService.createBackup(
            context: context,
            to: folder.appendingPathComponent("x.researchbase")
        )

        XCTAssertEqual(try TestSupport.counts(context), before)
    }

    func testPDFIsCopiedAndChecksummed() async throws {

        let (_, result, _) = try await makeBackup(pdf: true)

        XCTAssertEqual(result.pdfCount, 1)
        XCTAssertTrue(result.papersWithMissingPDF.isEmpty)

        let loaded = try WorkspaceBackupService.loadPackage(at: result.packageURL)

        XCTAssertTrue(loaded.pdfProblems.isEmpty)

        let paper = try XCTUnwrap(loaded.snapshot.papers.first { $0.pdfFileName != nil })
        XCTAssertNotNil(loaded.pdfURL(for: paper))
    }

    func testMissingPDFIsReportedNotHidden() async throws {

        let folder = try TestSupport.makeTempDirectory(self)
        let context = try TestSupport.makeContext()

        // The path is set, but no file exists there.
        try TestSupport.addSampleData(
            to: context,
            pdfPath: folder.appendingPathComponent("gone.pdf").path
        )

        let result = try await WorkspaceBackupService.createBackup(
            context: context,
            to: folder.appendingPathComponent("m.researchbase")
        )

        XCTAssertEqual(result.pdfCount, 0)
        XCTAssertEqual(result.papersWithMissingPDF.count, 1)
    }

    func testChangedWorkspaceFileIsRejected() async throws {

        let (_, result, _) = try await makeBackup()

        let file = result.packageURL.appendingPathComponent(WorkspaceFormat.workspaceFileName)
        var data = try Data(contentsOf: file)
        data.append(contentsOf: Array(" ".utf8))
        try data.write(to: file)

        assertThrowsBackupError(
            { _ = try WorkspaceBackupService.loadPackage(at: result.packageURL) },
            matches: { if case .checksumMismatch = $0 { return true } else { return false } },
            "A changed workspace.json must fail its checksum."
        )
    }

    func testDamagedPDFIsReportedAsProblem() async throws {

        let (_, result, _) = try await makeBackup(pdf: true)

        let papers = result.packageURL
            .appendingPathComponent(WorkspaceFormat.papersFolderName)
        let pdf = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(atPath: papers.path).first
        )

        try Data("damaged".utf8).write(to: papers.appendingPathComponent(pdf))

        let loaded = try WorkspaceBackupService.loadPackage(at: result.packageURL)

        XCTAssertEqual(loaded.pdfProblems.count, 1)
    }

    func testMissingManifestIsNotAPackage() async throws {

        let (_, result, _) = try await makeBackup()

        try FileManager.default.removeItem(
            at: result.packageURL.appendingPathComponent(WorkspaceFormat.manifestFileName)
        )

        assertThrowsBackupError(
            { _ = try WorkspaceBackupService.loadPackage(at: result.packageURL) },
            matches: { if case .notAPackage = $0 { return true } else { return false } },
            "A folder without manifest.json is not a backup."
        )
    }

    func testNewerFormatIsRefusedWithAClearError() async throws {

        let (_, result, _) = try await makeBackup()

        try editManifest(at: result.packageURL) { $0["formatVersion"] = 999 }

        assertThrowsBackupError(
            { _ = try WorkspaceBackupService.loadPackage(at: result.packageURL) },
            matches: { if case .unsupportedVersion(let v) = $0 { return v == 999 } else { return false } },
            "A backup from a newer format must be refused, not half-read."
        )
    }

    func testPathEscapingFileNameIsRejected() async throws {

        let (_, result, _) = try await makeBackup()

        try editManifest(at: result.packageURL) { manifest in
            manifest["pdfFiles"] = [[
                "paperID": UUID().uuidString,
                "fileName": "../../outside.pdf",
                "byteCount": 1,
                "sha256": "00"
            ]]
        }

        assertThrowsBackupError(
            { _ = try WorkspaceBackupService.loadPackage(at: result.packageURL) },
            matches: { if case .unsafeFileName = $0 { return true } else { return false } },
            "A file name that points outside the package must be rejected."
        )
    }

    func testPlainFileNameRules() {

        XCTAssertTrue(WorkspaceBackupService.isPlainFileName("a.pdf"))
        XCTAssertFalse(WorkspaceBackupService.isPlainFileName(""))
        XCTAssertFalse(WorkspaceBackupService.isPlainFileName(".."))
        XCTAssertFalse(WorkspaceBackupService.isPlainFileName("../a.pdf"))
        XCTAssertFalse(WorkspaceBackupService.isPlainFileName("dir/a.pdf"))
        XCTAssertFalse(WorkspaceBackupService.isPlainFileName("dir\\a.pdf"))
    }

    // MARK: Editing manifest.json for the tamper tests

    private func editManifest(
        at package: URL,
        _ change: (inout [String: Any]) -> Void
    ) throws {

        let url = package.appendingPathComponent(WorkspaceFormat.manifestFileName)

        let data = try Data(contentsOf: url)
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        change(&object)

        try JSONSerialization
            .data(withJSONObject: object, options: [.sortedKeys])
            .write(to: url)
    }
}
