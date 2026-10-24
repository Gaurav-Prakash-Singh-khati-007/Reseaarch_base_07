//
//  WorkspaceExportServiceTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 22/10/26.
//


//
//  WorkspaceExportServiceTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 54  Features: F-40 (draft export hook), F-50 (open-format export everything)
//

import XCTest
import SwiftData
@testable import ResearchBase

@MainActor
final class WorkspaceExportServiceTests: XCTestCase {

    private func exists(_ folder: URL, _ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(relative).path)
    }

    // MARK: F-50

    func testExportEverythingWritesOpenFormats() async throws {

        let work = try TestSupport.makeTempDirectory(self)
        let context = try TestSupport.makeContext()
        let pdf = try TestSupport.makeFakePDF(in: work)
        try TestSupport.addSampleData(to: context, pdfPath: pdf.path)

        let destination = work.appendingPathComponent("Export")

        let result = try await WorkspaceExportService.exportEverything(
            context: context,
            to: destination
        )

        XCTAssertEqual(result.folderURL, destination)
        XCTAssertTrue(exists(destination, "library.json"))
        XCTAssertTrue(exists(destination, "references.bib"))
        XCTAssertTrue(exists(destination, "summary.md"))
        XCTAssertTrue(exists(destination, "README.txt"))
        XCTAssertTrue(exists(destination, "notes/FedAvg baseline.md"))
        XCTAssertTrue(exists(destination, WorkspaceFormat.papersFolderName))
        XCTAssertGreaterThan(result.byteCount, 0)
        XCTAssertTrue(result.summary.contains("2 papers"))
        XCTAssertTrue(result.summary.contains("1 PDF files"))

        let note = try String(
            contentsOf: destination.appendingPathComponent("notes/FedAvg baseline.md"),
            encoding: .utf8
        )
        XCTAssertTrue(note.contains("Use as the baseline in chapter 4."))
    }

    func testExportEverythingWithoutLibraryWarnsAboutDrafts() async throws {

        let work = try TestSupport.makeTempDirectory(self)
        let context = try TestSupport.makeContext()
        try TestSupport.addSampleData(to: context)

        let result = try await WorkspaceExportService.exportEverything(
            context: context,
            to: work.appendingPathComponent("Export")
        )

        XCTAssertTrue(result.warnings.contains { $0.contains("no drafts were exported") })
        XCTAssertFalse(exists(result.folderURL, "drafts"))
    }

    func testExportEverythingIncludesDraftFolders() async throws {

        let work = try TestSupport.makeTempDirectory(self)
        let context = try TestSupport.makeContext()
        try TestSupport.addSampleData(to: context)

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let store = DraftFolderStore(model: model)
        store.useSystemTrash = false
        let draft = try store.create(title: "My Paper")

        let result = try await WorkspaceExportService.exportEverything(
            context: context,
            model: model,
            to: work.appendingPathComponent("Export")
        )

        let name = "My Paper \(draft.id.prefix(8))"

        XCTAssertTrue(exists(result.folderURL, "drafts/\(name)/main.tex"))
        XCTAssertTrue(result.summary.contains("1 drafts"))
    }

    func testExportEverythingRefusesExistingDestination() async throws {

        let work = try TestSupport.makeTempDirectory(self)
        let context = try TestSupport.makeContext()
        try TestSupport.addSampleData(to: context)

        let destination = work.appendingPathComponent("Export")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        do {
            _ = try await WorkspaceExportService.exportEverything(context: context, to: destination)
            XCTFail("Expected an error because the folder already exists.")
        } catch let error as WorkspaceExportError {
            guard case .writeFailed = error else { return XCTFail("Wrong error: \(error)") }
        }
    }

    func testExportEverythingOfEmptyWorkspaceThrows() async throws {

        let work = try TestSupport.makeTempDirectory(self)
        let context = try TestSupport.makeContext()

        do {
            _ = try await WorkspaceExportService.exportEverything(
                context: context,
                to: work.appendingPathComponent("Export")
            )
            XCTFail("Expected nothingToExport.")
        } catch let error as WorkspaceExportError {
            guard case .nothingToExport = error else { return XCTFail("Wrong error: \(error)") }
        }

        XCTAssertFalse(exists(work, "Export"))
    }

    func testVerifyOpenExportCatchesMissingPDF() async throws {

        let work = try TestSupport.makeTempDirectory(self)
        let context = try TestSupport.makeContext()
        let pdf = try TestSupport.makeFakePDF(in: work)
        try TestSupport.addSampleData(to: context, pdfPath: pdf.path)

        let destination = work.appendingPathComponent("Export")

        _ = try await WorkspaceExportService.exportEverything(context: context, to: destination)

        let counts = try WorkspaceSnapshot.capture(from: context).snapshot.entityCounts

        XCTAssertNoThrow(
            try WorkspaceExportService.verifyOpenExport(at: destination, expectedCounts: counts)
        )

        let papers = destination.appendingPathComponent(WorkspaceFormat.papersFolderName)
        for file in try FileManager.default.contentsOfDirectory(atPath: papers.path) {
            try FileManager.default.removeItem(at: papers.appendingPathComponent(file))
        }

        XCTAssertThrowsError(
            try WorkspaceExportService.verifyOpenExport(at: destination, expectedCounts: counts)
        )
    }

    // MARK: F-40

    func testExportDraftMarkdownAndZip() throws {

        let work = try TestSupport.makeTempDirectory(self)
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let store = DraftFolderStore(model: model)
        store.useSystemTrash = false
        let draft = try store.create(
            title: "Export Me",
            mainTex: "\\documentclass{article}\n\\begin{document}\nHello world.\n\\end{document}\n"
        )

        let md = try WorkspaceExportService.exportDraft(
            draftID: draft.id, model: model, format: .markdown,
            to: work.appendingPathComponent("out")
        )

        XCTAssertEqual(md.url.pathExtension, "md")
        XCTAssertGreaterThan(md.byteCount, 0)
        XCTAssertTrue(try String(contentsOf: md.url, encoding: .utf8).contains("Hello world."))

        let zip = try WorkspaceExportService.exportDraft(
            draftID: draft.id, model: model, format: .latexZip,
            to: work.appendingPathComponent("project.zip")
        )

        XCTAssertEqual(zip.url.pathExtension, "zip")
        XCTAssertTrue(try Data(contentsOf: zip.url).starts(with: [0x50, 0x4B]))
    }

    func testExportDraftPDFWithoutBuildThrowsNothingToExport() throws {

        let work = try TestSupport.makeTempDirectory(self)
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let store = DraftFolderStore(model: model)
        store.useSystemTrash = false
        let draft = try store.create(title: "Unbuilt")

        XCTAssertThrowsError(
            try WorkspaceExportService.exportDraft(
                draftID: draft.id, model: model, format: .pdf,
                to: work.appendingPathComponent("out.pdf")
            )
        ) { error in
            guard case WorkspaceExportError.nothingToExport = error else {
                return XCTFail("Wrong error: \(error)")
            }
        }
    }

    func testExportDraftRefusesToOverwriteUnlessAsked() throws {

        let work = try TestSupport.makeTempDirectory(self)
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let store = DraftFolderStore(model: model)
        store.useSystemTrash = false
        let draft = try store.create(title: "Twice")

        let target = work.appendingPathComponent("twice.txt")

        try WorkspaceExportService.exportDraft(
            draftID: draft.id, model: model, format: .plainText, to: target
        )

        XCTAssertThrowsError(
            try WorkspaceExportService.exportDraft(
                draftID: draft.id, model: model, format: .plainText, to: target
            )
        )

        XCTAssertNoThrow(
            try WorkspaceExportService.exportDraft(
                draftID: draft.id, model: model, format: .plainText, to: target, overwrite: true
            )
        )
    }

    func testSuggestedNames() {
        XCTAssertEqual(
            WorkspaceExportService.suggestedDraftFileName(title: "A/B: Paper", format: .docx),
            "A B Paper.docx"
        )
        XCTAssertTrue(
            WorkspaceExportService.suggestedEverythingFolderName().hasPrefix("ResearchBase Export ")
        )
    }
}