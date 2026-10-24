//
//  ExperimentFigureExporterTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 22/10/26.
//


//
//  ExperimentFigureExporterTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 38 · Feature: F-35
//

import XCTest
@testable import ResearchBase

@MainActor
final class ExperimentFigureExporterTests: XCTestCase {

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
                        status: String = "completed", metric: String = "test_accuracy", value: Double,
                        unit: String = "%", better: Bool = true, steps: [(Int, Double)] = []) throws -> String {
        let id = nextID("run")
        try model.database.run(
            "INSERT INTO runs (id, experiment_id, setting, run_number, status) VALUES (?, ?, ?, ?, ?)",
            [.text(id), .text(experiment), .text(setting), .int(Int64(number)), .text(status)])
        try addMetric(model, id, metric, value, unit: unit, better: better, step: nil)
        for (step, v) in steps { try addMetric(model, id, metric, v, unit: unit, better: better, step: step) }
        return id
    }

    private func addMetric(_ model: LibraryModel, _ run: String, _ name: String, _ value: Double,
                           unit: String, better: Bool, step: Int?) throws {
        try model.database.run(
            "INSERT INTO metrics (id, run_id, name, value, unit, higher_is_better, step) VALUES (?, ?, ?, ?, ?, ?, ?)",
            [.text(nextID("m")), .text(run), .text(name), .double(value), .text(unit), .int(better ? 1 : 0),
             step.map { SQLValue.int(Int64($0)) } ?? SQLValue.null])
    }

    private func addBaseline(_ model: LibraryModel, _ experiment: String, name: String, value: Double, unit: String = "%") throws {
        try model.database.run("INSERT INTO baselines (id, experiment_id, name, value, unit) VALUES (?, ?, ?, ?, ?)",
                               [.text(nextID("b")), .text(experiment), .text(name), .double(value), .text(unit)])
    }

    private func standardExperiment(_ model: LibraryModel) throws -> String {
        let e = try addExperiment(model)
        for (n, v) in [85.0, 86.0, 87.0].enumerated() { try addRun(model, e, setting: "FedAvg", number: n + 1, value: v) }
        for (n, v) in [88.0, 89.0].enumerated() { try addRun(model, e, setting: "SCAFFOLD", number: n + 4, value: v) }
        try addRun(model, e, setting: "FedProx", number: 6, value: 86.5)
        try addRun(model, e, setting: "Broken", number: 7, status: "failed", value: 1)
        return e
    }

    // MARK: Results

    func testResultsGroupCompletedRunsBySetting() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let e = try standardExperiment(model)
        let exporter = ExperimentFigureExporter(model: model)

        let results = try exporter.results(experimentID: e)

        XCTAssertEqual(results.settings.map(\.name), ["FedAvg", "SCAFFOLD", "FedProx"], "failed runs are ignored, order of first run kept")
        XCTAssertEqual(results.settings[0].values, [85, 86, 87])
        XCTAssertEqual(results.settings[0].mean, 86, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(results.settings[0].standardDeviation), 1, accuracy: 1e-9, "sample standard deviation")
        XCTAssertNil(results.settings[2].standardDeviation, "one run has no spread")
        XCTAssertEqual(results.bestSetting, "SCAFFOLD")
        XCTAssertEqual(results.metric.name, "test_accuracy")
        XCTAssertFalse(results.metric.hasCurve)
    }

    func testLowerIsBetterPicksTheSmallestMean() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let e = try addExperiment(model)
        try addRun(model, e, setting: "A", number: 1, metric: "loss", value: 0.9, unit: "", better: false)
        try addRun(model, e, setting: "B", number: 2, metric: "loss", value: 0.4, unit: "", better: false)

        XCTAssertEqual(try ExperimentFigureExporter(model: model).results(experimentID: e).bestSetting, "B")
    }

    func testMetricsAreListedByHowManyRunsReportThem() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let e = try standardExperiment(model)
        let run = try addRun(model, e, setting: "FedAvg", number: 8, metric: "f1", value: 0.8, unit: "", steps: [(1, 0.5), (2, 0.8)])
        _ = run

        let metrics = try ExperimentFigureExporter(model: model).availableMetrics(experimentID: e)
        XCTAssertEqual(metrics.map(\.name), ["test_accuracy", "f1"])
        XCTAssertEqual(metrics[0].runCount, 6)
        XCTAssertFalse(metrics[0].hasCurve)
        XCTAssertTrue(metrics[1].hasCurve)

        XCTAssertThrowsError(try ExperimentFigureExporter(model: model).results(experimentID: e, metric: "nope"))
        XCTAssertThrowsError(try ExperimentFigureExporter(model: model).results(experimentID: "missing"))
    }

    func testSteppedMetricUsesTheLastStepAsTheFinalValue() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let e = try addExperiment(model)
        for n in 1...2 {
            let run = nextID("run")
            try model.database.run("INSERT INTO runs (id, experiment_id, setting, run_number, status) VALUES (?, ?, 'S', ?, 'completed')",
                                   [.text(run), .text(e), .int(Int64(n))])
            try addMetric(model, run, "acc", 50, unit: "", better: true, step: 10)
            try addMetric(model, run, "acc", Double(70 + n), unit: "", better: true, step: 20)
        }
        let results = try ExperimentFigureExporter(model: model).results(experimentID: e, metric: "acc")

        XCTAssertEqual(results.settings[0].values, [71, 72])
        XCTAssertEqual(results.settings[0].curve, [CurvePoint(step: 10, value: 50), CurvePoint(step: 20, value: 71.5)])
    }

    // MARK: Table

    func testResultsTableHasBestInBoldSpreadRunsAndBaselines() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let e = try standardExperiment(model)
        try addBaseline(model, e, name: "Li et al. 2020", value: 84.7)
        try addBaseline(model, e, name: "Other unit", value: 3, unit: "s")

        let block = try ExperimentFigureExporter(model: model, now: { Date(timeIntervalSince1970: 0) })
            .resultsTable(experimentID: e)
        let tex = block.text

        XCTAssertEqual(block.kind, .table)
        XCTAssertEqual(block.requiredPackages, ["booktabs"])
        XCTAssertTrue(tex.hasPrefix("% ResearchBase:begin experiment-table id=\(e) metric=test_accuracy decimals=1 baselines=1\n"))
        XCTAssertTrue(tex.hasSuffix("% ResearchBase:end experiment-table id=\(e) metric=test_accuracy"))
        XCTAssertTrue(tex.contains("on 1970-01-01"))
        XCTAssertTrue(tex.contains("\\caption{Test accuracy (\\%), mean $\\pm$ standard deviation over seeds.}"), tex)
        XCTAssertTrue(tex.contains("Setting & Test accuracy (\\%) & Runs \\\\"))
        XCTAssertTrue(tex.contains("FedAvg & 86.0 $\\pm$ 1.0 & 3 \\\\"))
        XCTAssertTrue(tex.contains("SCAFFOLD & \\textbf{88.5} $\\pm$ 0.7 & 2 \\\\"))
        XCTAssertTrue(tex.contains("FedProx & 86.5 & 1 \\\\"), "one run: no ±")
        XCTAssertFalse(tex.contains("Broken"))
        XCTAssertTrue(tex.contains("Li et al. 2020 (baseline) & 84.7 & -- \\\\"))
        XCTAssertFalse(tex.contains("Other unit"), "baselines in another unit are left out")
        XCTAssertTrue(tex.contains("\\label{tab:fedavg-vs-fedprox-test-accuracy}"))
        XCTAssertTrue(tex.contains("\\toprule") && tex.contains("\\bottomrule"))

        let plain = try ExperimentFigureExporter(model: model)
            .resultsTable(experimentID: e, options: ExperimentTexOptions(decimals: 2, includeBaselines: false))
        XCTAssertTrue(plain.text.contains("SCAFFOLD & \\textbf{88.50} $\\pm$ 0.71"))
        XCTAssertFalse(plain.text.contains("baseline)"))
    }

    func testTableEscapesLatexAndSkipsBoldForASingleSetting() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let e = try addExperiment(model, name: "A & B_test")
        try addRun(model, e, setting: "lr=1e-3 #1", number: 1, value: 50.25)

        let tex = try ExperimentFigureExporter(model: model).resultsTable(experimentID: e).text
        XCTAssertTrue(tex.contains("lr=1e-3 \\#1 & 50.3 & 1 \\\\") || tex.contains("lr=1e-3 \\#1 & 50.2 & 1 \\\\"), tex)
        XCTAssertFalse(tex.contains("\\textbf"))
        XCTAssertFalse(tex.contains("mean $\\pm$"), "no spread without repeats")
    }

    func testGeneralLatexTableEscapesAndPads() {
        let tex = ExperimentFigureExporter.latexTable(
            columns: ["Paper", "Method", "Score"], rows: [["Li & Co", "FedAvg_v2"], ["B", "C", "100%"]],
            caption: "Comparison #1", label: "tab:cmp")

        XCTAssertTrue(tex.contains("\\begin{tabular}{lcc}"))
        XCTAssertTrue(tex.contains("Li \\& Co & FedAvg\\_v2 &  \\\\"))
        XCTAssertTrue(tex.contains("B & C & 100\\% \\\\"))
        XCTAssertTrue(tex.contains("\\caption{Comparison \\#1}"))
    }

    // MARK: Figure

    func testFigureBlockAndPDF() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let e = try standardExperiment(model)
        try addBaseline(model, e, name: "Li", value: 84.7)

        let exporter = ExperimentFigureExporter(model: model)
        let made = try exporter.figure(experimentID: e)

        XCTAssertEqual(made.block.figureFile, "figures/fedavg-vs-fedprox_test-accuracy.pdf")
        XCTAssertEqual(made.block.requiredPackages, ["graphicx"])
        XCTAssertTrue(made.block.text.contains("\\includegraphics[width=0.8\\linewidth]{figures/fedavg-vs-fedprox_test-accuracy.pdf}"))
        XCTAssertTrue(made.block.text.contains("style=bar"))

        let bytes = [UInt8](made.pdf)
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("%PDF-1.4"))
        XCTAssertTrue(text.hasSuffix("%%EOF\n"))
        XCTAssertTrue(text.contains("(FedAvg)") && text.contains("(SCAFFOLD)") && text.contains("(88.5)"))

        // startxref points at the xref table, and every object offset points at "n 0 obj".
        let startRange = try XCTUnwrap(text.range(of: "startxref\n", options: .backwards))
        let xrefOffset = try XCTUnwrap(Int(text[startRange.upperBound...].split(separator: "\n").first ?? ""))
        XCTAssertEqual(String(decoding: bytes[xrefOffset..<(xrefOffset + 4)], as: UTF8.self), "xref")

        let table = text[text.range(of: "xref\n")!.upperBound...].split(separator: "\n")
        let count = Int(table[0].split(separator: " ")[1])!
        for number in 1..<count {
            let offset = Int(table[number + 1].prefix(10))!
            XCTAssertTrue(String(decoding: bytes[offset...], as: UTF8.self).hasPrefix("\(number) 0 obj"), "object \(number)")
        }

        // Stream length is right.
        let lengthRange = try XCTUnwrap(text.range(of: "/Length "))
        let length = Int(text[lengthRange.upperBound...].prefix { $0.isNumber })!
        let streamStart = try XCTUnwrap(text.range(of: "stream\n")).upperBound
        let streamEnd = try XCTUnwrap(text.range(of: "\nendstream"))
        XCTAssertEqual(text[streamStart..<streamEnd.lowerBound].utf8.count, length)
    }

    func testCurveFigureNeedsSteps() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let e = try addExperiment(model)
        try addRun(model, e, setting: "A", number: 1, value: 80, steps: [(10, 50), (20, 80)])
        try addRun(model, e, setting: "B", number: 2, value: 85, steps: [(10, 55), (20, 85)])

        let exporter = ExperimentFigureExporter(model: model)
        let made = try exporter.figure(experimentID: e)   // curve is chosen automatically

        XCTAssertTrue(made.block.text.contains("style=curve"))
        XCTAssertEqual(made.block.figureFile, "figures/fedavg-vs-fedprox_test-accuracy_curve.pdf")
        XCTAssertTrue(String(decoding: made.pdf, as: UTF8.self).contains("(Step)"))

        let flat = try standardExperiment(model)
        XCTAssertThrowsError(try exporter.figure(experimentID: flat, style: .curve))
    }

    func testWriteFigureCreatesTheFiguresFolder() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let e = try standardExperiment(model)
        let folder = try TestSupport.makeTempDirectory(self)

        let exporter = ExperimentFigureExporter(model: model)
        let made = try exporter.figure(experimentID: e)
        let url = try exporter.writeFigure(made.pdf, for: made.block, in: folder)

        XCTAssertEqual(url, folder.appendingPathComponent("figures/fedavg-vs-fedprox_test-accuracy.pdf"))
        XCTAssertEqual(try Data(contentsOf: url), made.pdf)

        var bad = made.block
        bad.figureFile = "../escape.pdf"
        XCTAssertThrowsError(try exporter.writeFigure(made.pdf, for: bad, in: folder))
        let table = try exporter.resultsTable(experimentID: e)
        XCTAssertThrowsError(try exporter.writeFigure(made.pdf, for: table, in: folder))
    }

    // MARK: Inserting and refreshing

    func testInsertReplacesTheSameBlockInsteadOfDuplicatingIt() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let e = try standardExperiment(model)
        let exporter = ExperimentFigureExporter(model: model)

        let source = "\\begin{document}\nIntro.\n\nMore.\n\\end{document}\n"
        let block = try exporter.resultsTable(experimentID: e)

        let first = ExperimentFigureExporter.insert(block, into: source)
        XCTAssertFalse(first.replaced)
        XCTAssertTrue(first.text.contains("Intro.\n\nMore.\n% ResearchBase:begin"), "goes before \\end{document}")
        XCTAssertTrue(first.text.hasSuffix("\\end{document}\n"))

        let second = ExperimentFigureExporter.insert(block, into: first.text)
        XCTAssertTrue(second.replaced)
        XCTAssertEqual(second.text, first.text, "same block, same text")
        XCTAssertEqual(second.text.components(separatedBy: "ResearchBase:begin").count - 1, 1)

        try addRun(model, e, setting: "FedProx", number: 9, value: 95)
        let updated = ExperimentFigureExporter.insert(try exporter.resultsTable(experimentID: e), into: second.text)
        XCTAssertTrue(updated.replaced)
        XCTAssertTrue(updated.text.contains("FedProx & \\textbf{"), "new run shows up in the replaced block")
        XCTAssertEqual(updated.text.components(separatedBy: "ResearchBase:begin").count - 1, 1)
    }

    func testInsertAtCursorAndWithWindowsLineEndings() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let e = try standardExperiment(model)
        let block = try ExperimentFigureExporter(model: model).resultsTable(experimentID: e)

        let atCursor = ExperimentFigureExporter.insert(block, into: "AAA BBB", at: 3).text
        XCTAssertTrue(atCursor.hasPrefix("AAA\n% ResearchBase:begin"))
        XCTAssertTrue(atCursor.hasSuffix("\n\n BBB") || atCursor.contains("\n\n BBB"), atCursor)

        let crlf = "one\r\ntwo\r\n"
        let inserted = ExperimentFigureExporter.insert(block, into: crlf).text
        XCTAssertFalse(inserted.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "all line breaks stay Windows style")
        let again = ExperimentFigureExporter.insert(block, into: inserted)
        XCTAssertTrue(again.replaced)
        XCTAssertEqual(again.text, inserted)
    }

    func testBarAndCurveFiguresOfOneMetricCanCoexist() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let e = try addExperiment(model)
        try addRun(model, e, setting: "A", number: 1, value: 80, steps: [(10, 50), (20, 80)])
        try addRun(model, e, setting: "A", number: 2, value: 82, steps: [(10, 52), (20, 82)])
        let exporter = ExperimentFigureExporter(model: model)

        let bar = try exporter.figure(experimentID: e, style: .bar).block
        let curve = try exporter.figure(experimentID: e, style: .curve).block

        var text = ExperimentFigureExporter.insert(bar, into: "x\n").text
        text = ExperimentFigureExporter.insert(curve, into: text).text
        XCTAssertEqual(ExperimentFigureExporter.existingBlocks(in: text).count, 2)
        XCTAssertTrue(ExperimentFigureExporter.insert(bar, into: text).replaced)
    }

    func testExistingBlocksAreFoundWithTheirParameters() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let e = try addExperiment(model)
        try addRun(model, e, setting: "A", number: 1, metric: "F1 score", value: 0.8, unit: "")
        let block = try ExperimentFigureExporter(model: model)
            .resultsTable(experimentID: e, metric: "F1 score", options: ExperimentTexOptions(decimals: 3))

        let markers = ExperimentFigureExporter.existingBlocks(in: "before\n" + block.text + "\nafter")
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].metric, "F1 score", "metric names with spaces survive")
        XCTAssertEqual(markers[0].parameters["decimals"], "3")
        XCTAssertEqual(markers[0].beginLine, 1)
        XCTAssertTrue(markers[0].endLine > markers[0].beginLine)
        XCTAssertTrue(ExperimentFigureExporter.existingBlocks(in: "no blocks here").isEmpty)
    }

    func testRefreshUpdatesEveryBlockAndKeepsBrokenOnes() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let e = try standardExperiment(model)
        let gone = try addExperiment(model, name: "Gone")
        try addRun(model, gone, setting: "X", number: 1, value: 1)
        let exporter = ExperimentFigureExporter(model: model)
        let folder = try TestSupport.makeTempDirectory(self)

        var source = "Start\n"
        source = ExperimentFigureExporter.insert(try exporter.resultsTable(experimentID: e), into: source).text
        let fig = try exporter.figure(experimentID: e)
        source = ExperimentFigureExporter.insert(fig.block, into: source).text
        source = ExperimentFigureExporter.insert(try exporter.resultsTable(experimentID: gone), into: source).text

        try addRun(model, e, setting: "FedAvg", number: 20, value: 99)
        try model.database.run("UPDATE experiments SET deleted_at = ? WHERE id = ?", [.text(Library.nowISO()), .text(gone)])

        let result = try exporter.refreshBlocks(in: source, draftFolder: folder)

        XCTAssertEqual(result.refreshed, 2)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.text.contains("FedAvg & \\textbf{89."), result.text)
        XCTAssertTrue(result.text.contains("& 4 \\\\"), "the new run is counted")
        XCTAssertTrue(result.text.contains("X & 1.0 & 1"), "the deleted experiment's block stays as it was")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(fig.block.figureFile!).path))
        XCTAssertEqual(ExperimentFigureExporter.existingBlocks(in: result.text).count, 3)
    }

    func testSlugsAndEscaping() {
        XCTAssertEqual(ExperimentFigureExporter.slug("FedAvg vs. FedProx!"), "fedavg-vs-fedprox")
        XCTAssertEqual(ExperimentFigureExporter.slug("???"), "experiment")
        XCTAssertEqual(ExperimentFigureExporter.escapeLatex("a_b & 50% {x} ~ ^ \\"),
                       "a\\_b \\& 50\\% \\{x\\} \\textasciitilde{} \\textasciicircum{} \\textbackslash{}")
        XCTAssertEqual(ExperimentFigureExporter.format(-0.04, 1), "0.0")
    }
}