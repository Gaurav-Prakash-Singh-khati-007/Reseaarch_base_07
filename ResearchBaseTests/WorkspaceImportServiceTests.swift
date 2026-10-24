//
//  WorkspaceImportServiceTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 53 · F-19
//
//  Tests for the library-file import added to WorkspaceImportService:
//  detection, preview, duplicate flags, the single save, tags and log import.
//  Every test uses a temporary library and temporary files.
//

import XCTest
@testable import ResearchBase

private let rbA53_bib = """
@article{smith2020,
  author = {Smith, Jane and Doe, John},
  title = {Deep Learning for Libraries},
  journal = {Nature},
  year = {2020},
  doi = {10.1000/abc}
}

@inproceedings{lee2021,
  author = {Lee, Ann},
  title = {Federated Averaging in Practice},
  booktitle = {ICML},
  year = {2021}
}
"""

private let rbA53_ris = """
TY  - JOUR
AU  - Smith, Jane
TI  - A Paper From RIS
PY  - 2019
ER  - 
"""

private let rbA53_csv = """
Title,Author,Publication Year,DOI
First Paper,"Smith, Jane",2020,10.1000/one
Second Paper,"Doe, John",2021,10.1000/two
"""

private let rbA53_csl = """
[
  {"id": "a1", "type": "article-journal", "title": "Deep Learning",
   "author": [{"family": "Smith", "given": "Jane"}],
   "issued": {"date-parts": [[2020]]}, "DOI": "10.1000/ABC"}
]
"""

private let rbA53_log = [
    "Start Time,Duration,Run ID,Run Name,Source Type,Source Name,User,Status,lr,seed,test_acc,loss",
    "2026-10-01 10:00:00,1.2min,r1,FedAvg-seed11,LOCAL,train.py,gk,FINISHED,0.01,11,84.1,0.52",
    "2026-10-01 10:05:00,1.2min,r2,FedAvg-seed22,LOCAL,train.py,gk,FINISHED,0.01,22,84.5,0.50",
    "2026-10-01 10:10:00,1.2min,r3,FedProx-seed11,LOCAL,train.py,gk,FINISHED,0.01,11,85.0,0.45",
    "2026-10-01 10:15:00,1.2min,r4,FedProx-seed22,LOCAL,train.py,gk,FINISHED,0.01,22,85.4,0.44"
].joined(separator: "\n")

@MainActor
final class WorkspaceImportServiceLibraryImportTests: XCTestCase {

    private func write(_ text: String, as name: String) throws -> URL {
        let url = try TestSupport.makeTempDirectory(self).appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Detect

    func testDetectsByExtension() throws {
        XCTAssertEqual(try WorkspaceImportService.detectLibrarySource(fileAt: write(rbA53_bib, as: "a.bib")), .bibtex)
        XCTAssertEqual(try WorkspaceImportService.detectLibrarySource(fileAt: write(rbA53_ris, as: "a.ris")), .ris)
        XCTAssertEqual(try WorkspaceImportService.detectLibrarySource(fileAt: write(rbA53_csv, as: "a.csv")), .csv)
        XCTAssertEqual(try WorkspaceImportService.detectLibrarySource(fileAt: write(rbA53_csl, as: "a.json")), .cslJSON)
    }

    func testDetectsByContentWhenExtensionIsUnknown() throws {
        XCTAssertEqual(try WorkspaceImportService.detectLibrarySource(fileAt: write(rbA53_bib, as: "export.txt")), .bibtex)
        XCTAssertEqual(try WorkspaceImportService.detectLibrarySource(fileAt: write(rbA53_ris, as: "export.txt")), .ris)
        XCTAssertEqual(try WorkspaceImportService.detectLibrarySource(fileAt: write(rbA53_csv, as: "export.txt")), .csv)
        XCTAssertEqual(try WorkspaceImportService.detectLibrarySource(fileAt: write(rbA53_csl, as: "export.txt")), .cslJSON)
    }

    func testUnrecognisedAndMissingFilesThrow() throws {
        let junk = try write("just some words", as: "notes.txt")
        XCTAssertThrowsError(try WorkspaceImportService.detectLibrarySource(fileAt: junk)) {
            XCTAssertEqual($0 as? LibraryImportError, .unrecognisedFile)
        }
        let missing = junk.deletingLastPathComponent().appendingPathComponent("nope.bib")
        XCTAssertThrowsError(try WorkspaceImportService.detectLibrarySource(fileAt: missing))
    }

    // MARK: Preview

    func testPreviewListsRowsAndSavesNothing() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let preview = try WorkspaceImportService.previewLibraryFile(
            at: write(rbA53_bib, as: "a.bib"), checkingAgainst: model
        )
        XCTAssertEqual(preview.source, .bibtex)
        XCTAssertEqual(preview.fileName, "a.bib")
        XCTAssertEqual(preview.rows.map(\.id), [1, 2])
        XCTAssertEqual(preview.rows.map(\.item.title), ["Deep Learning for Libraries", "Federated Averaging in Practice"])
        XCTAssertEqual(preview.defaultSelection, [1, 2])
        XCTAssertTrue(preview.canImport)
        XCTAssertEqual(try ModelTestSupport.count(model, "items"), 0)
    }

    func testPreviewForRISCSVAndCSLJSON() throws {
        XCTAssertEqual(try WorkspaceImportService.previewLibraryFile(at: write(rbA53_ris, as: "a.ris")).rows.count, 1)
        XCTAssertEqual(try WorkspaceImportService.previewLibraryFile(at: write(rbA53_csv, as: "a.csv")).rows.count, 2)
        let csl = try WorkspaceImportService.previewLibraryFile(at: write(rbA53_csl, as: "a.json"))
        XCTAssertEqual(csl.source, .cslJSON)
        XCTAssertEqual(csl.rows.count, 1)
    }

    func testPreviewUsesTheGivenReviewState() throws {
        let inbox = try WorkspaceImportService.previewLibraryFile(at: write(rbA53_ris, as: "a.ris"))
        XCTAssertEqual(inbox.rows[0].item.reviewState, .inbox)
        let accepted = try WorkspaceImportService.previewLibraryFile(at: write(rbA53_ris, as: "a.ris"), reviewState: .accepted)
        XCTAssertEqual(accepted.rows[0].item.reviewState, .accepted)
    }

    func testRepeatInsideTheFileIsFlaggedAndUnticked() throws {
        let text = rbA53_csv + "\nFirst Paper,\"Smith, Jane\",2020,10.1000/one"
        let preview = try WorkspaceImportService.previewLibraryFile(at: write(text, as: "a.csv"))
        XCTAssertEqual(preview.rows.count, 3)
        XCTAssertEqual(preview.rows[2].repeatsRowID, 1)
        XCTAssertTrue(preview.rows[2].isLikelyDuplicate)
        XCTAssertEqual(preview.defaultSelection, [1, 2])
        XCTAssertEqual(preview.duplicateCount, 1)
        XCTAssertTrue(preview.summary.contains("1 possible duplicate"))
    }

    func testPaperAlreadyInLibraryIsFlaggedAndUnticked() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        try model.items.create(NewItem(title: "First Paper", doi: "10.1000/one"))

        let preview = try WorkspaceImportService.previewLibraryFile(
            at: write(rbA53_csv, as: "a.csv"), checkingAgainst: model
        )
        XCTAssertFalse(preview.rows[0].libraryMatches.isEmpty)
        XCTAssertTrue(preview.rows[1].libraryMatches.isEmpty)
        XCTAssertEqual(preview.defaultSelection, [2])
    }

    // MARK: Import

    func testImportCreatesTheChosenRows() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let preview = try WorkspaceImportService.previewLibraryFile(at: write(rbA53_bib, as: "a.bib"))
        let result = try WorkspaceImportService.importLibraryFile(preview, selecting: [2], into: model)

        XCTAssertEqual(result.createdItemIDs.count, 1)
        XCTAssertTrue(result.skippedRows.isEmpty)
        XCTAssertEqual(try ModelTestSupport.count(model, "items"), 1)

        let item = try XCTUnwrap(try model.items.fetch(id: result.createdItemIDs[0]))
        XCTAssertEqual(item.title, "Federated Averaging in Practice")
        XCTAssertEqual(item.reviewState, .inbox)
        XCTAssertEqual(item.sourceKind, .import)
    }

    func testImportWithNoSelectionThrowsAndSavesNothing() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let preview = try WorkspaceImportService.previewLibraryFile(at: write(rbA53_bib, as: "a.bib"))
        XCTAssertThrowsError(try WorkspaceImportService.importLibraryFile(preview, selecting: [], into: model)) {
            XCTAssertEqual($0 as? LibraryImportError, .nothingSelected)
        }
        XCTAssertEqual(try ModelTestSupport.count(model, "items"), 0)
    }

    func testDefaultSelectionSkipsDuplicates() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        try model.items.create(NewItem(title: "First Paper", doi: "10.1000/one"))

        let preview = try WorkspaceImportService.previewLibraryFile(
            at: write(rbA53_csv, as: "a.csv"), checkingAgainst: model
        )
        let result = try WorkspaceImportService.importLibraryFile(preview, into: model)
        XCTAssertEqual(result.createdItemIDs.count, 1)
        XCTAssertEqual(try ModelTestSupport.count(model, "items"), 2)
    }

    func testRowsTheLibraryWouldRefuseAreSkippedNotFatal() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let preview = LibraryImportPreview(
            source: .csv, fileName: "x.csv", reviewState: .inbox,
            rows: [
                LibraryImportRow(id: 1, label: "Row 2", item: NewItem(title: "Good")),
                LibraryImportRow(id: 2, label: "Row 3", item: NewItem(title: "   ")),
                LibraryImportRow(id: 3, label: "Row 4", item: NewItem(title: "Bad year", year: 12345))
            ],
            skipped: [], ignoredColumns: []
        )
        let result = try WorkspaceImportService.importLibraryFile(preview, selecting: [1, 2, 3], into: model)
        XCTAssertEqual(result.createdItemIDs.count, 1)
        XCTAssertEqual(result.skippedRows.count, 2)
        XCTAssertEqual(try ModelTestSupport.count(model, "items"), 1)
    }

    func testTagsAreCreatedOnceAndAssigned() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let preview = LibraryImportPreview(
            source: .zoteroLibrary, fileName: "z.sqlite", reviewState: .inbox,
            rows: [
                LibraryImportRow(id: 1, label: "Item 1", item: NewItem(title: "One"),
                                 tags: ["Federated", "federated", " "], attachmentHints: ["/tmp/one.pdf"]),
                LibraryImportRow(id: 2, label: "Item 2", item: NewItem(title: "Two"), tags: ["FEDERATED", "Survey"])
            ],
            skipped: [], ignoredColumns: []
        )
        let result = try WorkspaceImportService.importLibraryFile(preview, selecting: [1, 2], into: model)

        XCTAssertEqual(result.tagsAssigned, 3)
        XCTAssertEqual(try model.tags.all().count, 2)
        XCTAssertEqual(try model.tags.tags(of: result.createdItemIDs[0]).count, 1)
        XCTAssertEqual(try model.tags.tags(of: result.createdItemIDs[1]).count, 2)
        XCTAssertEqual(result.attachmentHints, [
            LibraryImportAttachmentHint(itemID: result.createdItemIDs[0], paths: ["/tmp/one.pdf"])
        ])

        let noTags = try WorkspaceImportService.importLibraryFile(preview, selecting: [2], into: model, applyTags: false)
        XCTAssertEqual(noTags.tagsAssigned, 0)
    }

    func testFailedSaveLeavesTheLibraryUnchanged() throws {
        // The second change report fails, so the first paper must be undone too.
        let model = try ModelTestSupport.makeModel(self, sink: FailingChangeSink(failOnCall: 1))
        defer { model.library.close() }

        let preview = try WorkspaceImportService.previewLibraryFile(at: write(rbA53_bib, as: "a.bib"))
        XCTAssertThrowsError(try WorkspaceImportService.importLibraryFile(preview, into: model))
        XCTAssertEqual(try ModelTestSupport.count(model, "items"), 0)
    }

    // MARK: Training logs

    func testLogPreviewDetectsFormatAndPlansRuns() throws {
        let preview = try WorkspaceImportService.previewLogImport(fileAt: write(rbA53_log, as: "runs.csv"))
        XCTAssertEqual(preview.detectedText, "Detected: MLflow CSV export")
        XCTAssertGreaterThan(preview.plan.runCount, 0)
        XCTAssertEqual(preview.plan.sourceFileName, "runs.csv")

        let ignoreAll = preview.mapping.map { column -> ColumnMapping in
            var copy = column
            copy.role = .ignore
            return copy
        }
        XCTAssertEqual(preview.replanned(mapping: ignoreAll, options: preview.options).plan.metricRowCount, 0)
    }

    func testLogCommitWritesOnceAndRefusesTheSameFileTwice() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let experimentID = try ModelTestSupport.insertExperiment(model)

        let preview = try WorkspaceImportService.previewLogImport(fileAt: write(rbA53_log, as: "runs.csv"))
        let result = try WorkspaceImportService.commitLogImport(preview, toExperiment: experimentID, into: model)
        XCTAssertEqual(result.runsAdded, preview.plan.runCount)
        XCTAssertEqual(try ModelTestSupport.count(model, "runs"), preview.plan.runCount)

        XCTAssertThrowsError(
            try WorkspaceImportService.commitLogImport(preview, toExperiment: experimentID, into: model)
        ) {
            XCTAssertEqual($0 as? LibraryImportError, .alreadyImported(runs: preview.plan.runCount, file: "runs.csv"))
        }

        _ = try WorkspaceImportService.commitLogImport(preview, toExperiment: experimentID, into: model, allowRepeat: true)
        XCTAssertEqual(try ModelTestSupport.count(model, "runs"), preview.plan.runCount * 2)
    }

    func testLogPreviewOfUnreadableFileThrows() throws {
        let missing = try TestSupport.makeTempDirectory(self).appendingPathComponent("nope.csv")
        XCTAssertThrowsError(try WorkspaceImportService.previewLogImport(fileAt: missing))
    }
}
