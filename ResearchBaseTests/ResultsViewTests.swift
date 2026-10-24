//
//  ResultsViewTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 74 · Features: F-42, F-35
//
//  Tests the logic behind the "Repeated runs" and "Use in draft" tabs of ResultsView:
//  the row builders, the LaTeX package helpers, and inserting into / refreshing a real
//  draft folder. The SwiftUI views themselves are not rendered here.
//

import XCTest
@testable import ResearchBase

// MARK: - Pure helpers

final class RBA74LatexTests: XCTestCase {

    func testLoadedPackagesIgnoreCommentsAndReadLists() {
        let source = """
        \\documentclass{article}
        \\usepackage[utf8]{inputenc}
        \\usepackage{amsmath, graphicx}
        % \\usepackage{booktabs}
        \\usepackage{xcolor} % \\usepackage{tikz}
        """
        XCTAssertEqual(RBA74Latex.loadedPackages(in: source), ["inputenc", "amsmath", "graphicx", "xcolor"])
    }

    func testEscapedPercentIsNotAComment() {
        let source = "\\usepackage{a}\\%\\usepackage{b}"
        XCTAssertEqual(RBA74Latex.loadedPackages(in: source), ["a", "b"])
    }

    func testMissingPackagesKeepsOrderAndDropsDuplicates() {
        let source = "\\documentclass{article}\n\\usepackage{graphicx}\n"
        XCTAssertEqual(RBA74Latex.missingPackages(["booktabs", "graphicx", "booktabs"], in: source), ["booktabs"])
    }

    func testPackagesGoRightAfterDocumentclass() throws {
        let source = "% header\n\\documentclass[11pt]{article}\n\\begin{document}\nHi\n\\end{document}\n"
        let out = try XCTUnwrap(RBA74Latex.addingPackages(["booktabs", "graphicx"], to: source))
        XCTAssertEqual(out, "% header\n\\documentclass[11pt]{article}\n\\usepackage{booktabs}\n\\usepackage{graphicx}\n\\begin{document}\nHi\n\\end{document}\n")
    }

    func testPackagesKeepWindowsLineEndings() throws {
        let source = "\\documentclass{article}\r\n\\begin{document}\r\n\\end{document}\r\n"
        let out = try XCTUnwrap(RBA74Latex.addingPackages(["booktabs"], to: source))
        XCTAssertEqual(out, "\\documentclass{article}\r\n\\usepackage{booktabs}\r\n\\begin{document}\r\n\\end{document}\r\n")
    }

    func testNoDocumentclassMeansNoPackagesAreAdded() {
        XCTAssertNil(RBA74Latex.addingPackages(["booktabs"], to: "\\chapter{Intro}\n"))
        XCTAssertNil(RBA74Latex.addingPackages(["booktabs"], to: "% \\documentclass{article}\n"), "a commented line does not count")
    }

    func testNothingToAddReturnsTheSourceUnchanged() {
        XCTAssertEqual(RBA74Latex.addingPackages([], to: "abc"), "abc")
    }
}

// MARK: - With a real library

@MainActor
final class RBA74ResultsTests: XCTestCase {

    private var counter = 0

    private func nextID(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)\(counter)"
    }

    @discardableResult
    private func addExperiment(_ model: LibraryModel, name: String = "FedAvg vs FedProx") throws -> String {
        let id = nextID("exp")
        let now = Library.nowISO()
        try model.database.run("INSERT INTO experiments (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)",
                               [.text(id), .text(name), .text(now), .text(now)])
        return id
    }

    @discardableResult
    private func addRun(_ model: LibraryModel, _ experiment: String, setting: String, number: Int,
                        metric: String = "test_accuracy", value: Double, unit: String = "%",
                        steps: [(Int, Double)] = []) throws -> String {
        let id = nextID("run")
        try model.database.run(
            "INSERT INTO runs (id, experiment_id, setting, run_number, status) VALUES (?, ?, ?, ?, 'completed')",
            [.text(id), .text(experiment), .text(setting), .int(Int64(number))])
        try addMetric(model, id, metric, value, unit: unit, step: nil)
        for (step, v) in steps { try addMetric(model, id, metric, v, unit: unit, step: step) }
        return id
    }

    private func addMetric(_ model: LibraryModel, _ run: String, _ name: String, _ value: Double,
                           unit: String, step: Int?) throws {
        try model.database.run(
            "INSERT INTO metrics (id, run_id, name, value, unit, higher_is_better, step) VALUES (?, ?, ?, ?, ?, 1, ?)",
            [.text(nextID("m")), .text(run), .text(name), .double(value), .text(unit),
             step.map { SQLValue.int(Int64($0)) } ?? SQLValue.null])
    }

    /// FedAvg x5 (mean 84.5), FedProx x5 (mean 86.56), Solo x1.
    private func seededExperiment(_ model: LibraryModel) throws -> String {
        let e = try addExperiment(model)
        for (n, v) in [84.1, 84.5, 84.9, 84.3, 84.7].enumerated() { try addRun(model, e, setting: "FedAvg", number: n + 1, value: v) }
        for (n, v) in [86.2, 86.8, 86.5, 86.9, 86.4].enumerated() { try addRun(model, e, setting: "FedProx", number: n + 6, value: v) }
        try addRun(model, e, setting: "Solo", number: 11, value: 80)
        return e
    }

    private func makeDraft(_ model: LibraryModel, mainTex: String? = nil) throws -> StoredDraft {
        let store = DraftFolderStore(model: model)
        store.useSystemTrash = false
        return try store.create(title: "Paper", mainTex: mainTex)
    }

    private let simpleTex = "\\documentclass{article}\n\\begin{document}\nIntro.\n\\end{document}\n"

    // MARK: F-42 rows

    func testSettingRowsShowRunsMeanSDAndBest() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let e = try seededExperiment(model)

        let analysis = try RunStatisticsLoader(model: model).analysis(experimentID: e, metric: "test_accuracy")
        let rows = RBA74Stats.settingRows(analysis)

        XCTAssertEqual(rows.map(\.name), ["FedAvg", "FedProx", "Solo"])
        XCTAssertEqual(rows.map(\.runs), [5, 5, 1])
        XCTAssertEqual(rows[0].meanSD, "84.50 ± 0.32")
        XCTAssertEqual(rows[0].range, "84.10–84.90")
        XCTAssertEqual(rows[2].meanSD, "80.00 (1 run)", "a single run has no spread")
        XCTAssertEqual(rows.filter(\.isBest).map(\.name), ["FedProx"])
    }

    func testComparisonRowsHaveDifferenceVerdictAndSmallSampleFlag() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let e = try seededExperiment(model)

        let analysis = try RunStatisticsLoader(model: model).analysis(experimentID: e, metric: "test_accuracy")
        let rows = RBA74Stats.comparisonRows(analysis)

        let pair = try XCTUnwrap(rows.first { $0.label == "FedProx vs FedAvg" })
        XCTAssertEqual(pair.verdict, .likelyReal)
        XCTAssertTrue(pair.difference.hasPrefix("+2.0"), pair.difference)
        XCTAssertTrue(pair.interval.hasPrefix("95% CI ["), pair.interval)
        XCTAssertFalse(pair.smallSample, "five seeds each is not flagged as a small sample")

        let solo = try XCTUnwrap(rows.first { $0.label.hasPrefix("Solo") })
        XCTAssertEqual(solo.verdict, .notEnoughData)

        XCTAssertFalse(RBA74Stats.needsSmallSampleNote(analysis), "no real test ran on few seeds")
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, "ids are unique")
    }

    func testSmallSampleNoteShowsForThreeSeeds() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let e = try addExperiment(model)
        for (n, v) in [84.1, 84.5, 84.9].enumerated() { try addRun(model, e, setting: "A", number: n + 1, value: v) }
        for (n, v) in [86.2, 86.8, 86.5].enumerated() { try addRun(model, e, setting: "B", number: n + 4, value: v) }

        let analysis = try RunStatisticsLoader(model: model).analysis(experimentID: e, metric: "test_accuracy")
        let rows = RBA74Stats.comparisonRows(analysis)

        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].smallSample)
        XCTAssertTrue(RBA74Stats.needsSmallSampleNote(analysis))
    }

    // MARK: F-35 insert

    func testInsertTableAddsBlockPackageAndSnapshot() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let e = try seededExperiment(model)
        let draft = try makeDraft(model, mainTex: simpleTex)
        let exporter = ExperimentFigureExporter(model: model)

        let made = try RBA74Export.build(exporter: exporter, experimentID: e, metric: "test_accuracy", kind: .table, options: ExperimentTexOptions())
        XCTAssertNil(made.pdf)
        let outcome = try RBA74Export.insert(made.block, pdf: made.pdf, intoDraft: draft.id, model: model)

        XCTAssertFalse(outcome.replaced)
        XCTAssertEqual(outcome.packagesAdded, ["booktabs"])
        XCTAssertNil(outcome.figureFile)

        let text = try DraftFolderStore(model: model).readText(draftID: draft.id, path: draft.mainFile)
        XCTAssertTrue(text.contains("\\usepackage{booktabs}"))
        XCTAssertTrue(text.contains("% ResearchBase:begin experiment-table"))
        XCTAssertTrue(text.contains("\\end{document}"))
        XCTAssertEqual(try DraftHistoryStore(model: model).count(forDraft: draft.id), 1, "a snapshot is taken before the change")
    }

    func testInsertingTwiceReplacesInsteadOfDuplicating() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let e = try seededExperiment(model)
        let draft = try makeDraft(model, mainTex: simpleTex)
        let exporter = ExperimentFigureExporter(model: model)
        let made = try RBA74Export.build(exporter: exporter, experimentID: e, metric: "test_accuracy", kind: .table, options: ExperimentTexOptions())

        _ = try RBA74Export.insert(made.block, pdf: nil, intoDraft: draft.id, model: model)
        let second = try RBA74Export.insert(made.block, pdf: nil, intoDraft: draft.id, model: model)

        XCTAssertTrue(second.replaced)
        XCTAssertTrue(second.packagesAdded.isEmpty, "booktabs is already there")
        let text = try DraftFolderStore(model: model).readText(draftID: draft.id, path: draft.mainFile)
        XCTAssertEqual(text.components(separatedBy: "ResearchBase:begin experiment-table").count - 1, 1)
        XCTAssertEqual(text.components(separatedBy: "\\usepackage{booktabs}").count - 1, 1)
    }

    func testInsertBarFigureWritesPDFIntoFiguresFolder() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let e = try seededExperiment(model)
        let draft = try makeDraft(model, mainTex: simpleTex)
        let exporter = ExperimentFigureExporter(model: model)

        let made = try RBA74Export.build(exporter: exporter, experimentID: e, metric: "test_accuracy", kind: .bar, options: ExperimentTexOptions())
        let pdf = try XCTUnwrap(made.pdf)
        XCTAssertFalse(pdf.isEmpty)
        let outcome = try RBA74Export.insert(made.block, pdf: pdf, intoDraft: draft.id, model: model)

        let file = try XCTUnwrap(outcome.figureFile)
        XCTAssertTrue(file.hasPrefix("figures/") && file.hasSuffix(".pdf"), file)
        let url = DraftFolderStore(model: model).folderURL(for: draft).appendingPathComponent(file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(outcome.packagesAdded, ["graphicx"])
    }

    func testChapterFileWithoutDocumentclassReportsPackagesToAddByHand() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let e = try seededExperiment(model)
        let draft = try makeDraft(model, mainTex: "\\chapter{Results}\n")
        let made = try RBA74Export.build(exporter: ExperimentFigureExporter(model: model), experimentID: e,
                                         metric: "test_accuracy", kind: .table, options: ExperimentTexOptions())

        let outcome = try RBA74Export.insert(made.block, pdf: nil, intoDraft: draft.id, model: model)

        XCTAssertTrue(outcome.packagesAdded.isEmpty)
        XCTAssertEqual(outcome.packagesToAddByHand, ["booktabs"])
        let text = try DraftFolderStore(model: model).readText(draftID: draft.id, path: draft.mainFile)
        XCTAssertFalse(text.contains("\\usepackage"))
        XCTAssertTrue(text.contains("\\chapter{Results}"))
    }

    func testInsertIntoMissingDraftChangesNothing() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let e = try seededExperiment(model)
        let made = try RBA74Export.build(exporter: ExperimentFigureExporter(model: model), experimentID: e,
                                         metric: "test_accuracy", kind: .table, options: ExperimentTexOptions())

        XCTAssertThrowsError(try RBA74Export.insert(made.block, pdf: nil, intoDraft: "nope", model: model))
    }

    func testCurveNeedsStepsAndBuildExplainsWhy() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let e = try seededExperiment(model)

        XCTAssertThrowsError(try RBA74Export.build(exporter: ExperimentFigureExporter(model: model), experimentID: e,
                                                   metric: "test_accuracy", kind: .curve, options: ExperimentTexOptions()))
    }

    // MARK: Update all blocks

    func testRefreshAllUsesNewRunsAndSnapshotsFirst() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let e = try seededExperiment(model)
        let draft = try makeDraft(model, mainTex: simpleTex)
        let made = try RBA74Export.build(exporter: ExperimentFigureExporter(model: model), experimentID: e,
                                         metric: "test_accuracy", kind: .table, options: ExperimentTexOptions())
        _ = try RBA74Export.insert(made.block, pdf: nil, intoDraft: draft.id, model: model)
        let before = try DraftFolderStore(model: model).readText(draftID: draft.id, path: draft.mainFile)

        try addRun(model, e, setting: "FedAvg", number: 12, value: 99)
        let result = try RBA74Export.refreshAll(inDraft: draft.id, model: model)

        XCTAssertEqual(result.refreshed, 1)
        let after = try DraftFolderStore(model: model).readText(draftID: draft.id, path: draft.mainFile)
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(try DraftHistoryStore(model: model).count(forDraft: draft.id), 2, "one for the insert, one for the refresh")
    }

    func testRefreshAllOnADraftWithoutBlocksDoesNothing() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let draft = try makeDraft(model, mainTex: simpleTex)

        let result = try RBA74Export.refreshAll(inDraft: draft.id, model: model)

        XCTAssertEqual(result.refreshed, 0)
        XCTAssertEqual(try DraftHistoryStore(model: model).count(forDraft: draft.id), 0, "no snapshot when nothing will change")
    }
}
