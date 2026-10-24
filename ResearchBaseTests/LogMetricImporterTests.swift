//
//  LogMetricImporterTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 27 · Features: F-43
//
//  Pure steps (parse, detect, map, plan) are tested on small in-memory logs.
//  `commit` is tested on a real temporary library.
//

import XCTest
@testable import ResearchBase

// MARK: - Fixtures

private func rbA27_lines(_ lines: [String]) -> String { lines.joined(separator: "\n") }

private let rbA27_mlflowCSV = rbA27_lines([
    "Start Time,Duration,Run ID,Run Name,Source Type,Source Name,User,Status,lr,seed,test_acc,loss",
    "2026-10-01 10:00:00,1.2min,r1,FedAvg-seed11,LOCAL,train.py,gk,FINISHED,0.01,11,84.1,0.52",
    "2026-10-01 10:05:00,1.2min,r2,FedAvg-seed22,LOCAL,train.py,gk,FINISHED,0.01,22,84.5,0.50",
    "2026-10-01 10:10:00,1.2min,r3,FedProx-seed11,LOCAL,train.py,gk,FINISHED,0.01,11,85.0,0.45",
    "2026-10-01 10:15:00,1.2min,r4,FedProx-seed22,LOCAL,train.py,gk,FINISHED,0.01,22,85.4,0.44"
])

private func rbA27_role(_ mapping: [ColumnMapping], _ header: String) -> ColumnRole? {
    mapping.first { $0.header == header }?.role
}

private func rbA27_plan(
    _ text: String, name: String = "log.csv", options: ImportOptions = ImportOptions()
) throws -> (parsed: ParsedLog, mapping: [ColumnMapping], plan: LogImportPlan) {
    let parsed = try LogMetricParser.parse(text: text, fileName: name)
    let mapping = LogMetricParser.suggestMapping(for: parsed)
    return (parsed, mapping, LogMetricParser.makePlan(from: parsed, mapping: mapping, options: options))
}

// MARK: - CSV reading

final class LogMetricParserCSVTests: XCTestCase {

    func testQuotesCommasEscapedQuotesAndLineBreaksInsideQuotes() {
        let text = "a,b,c\r\n1,\"x, y\",\"say \"\"hi\"\"\"\r\n2,\"line1\nline2\",z\r\n"
        let rows = LogMetricParser.parseCSV(text)

        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1], ["1", "x, y", "say \"hi\""])
        XCTAssertEqual(rows[2], ["2", "line1\nline2", "z"])
    }

    func testSemicolonAndTabDelimiters() {
        XCTAssertEqual(LogMetricParser.parseCSV("a;b\n1;2"), [["a", "b"], ["1", "2"]])
        XCTAssertEqual(LogMetricParser.parseCSV("a\tb\n1\t2"), [["a", "b"], ["1", "2"]])
    }

    func testBlankLinesAreSkippedAndBOMIsIgnored() throws {
        let log = try LogMetricParser.parse(text: "\u{FEFF}loss,acc\n\n0.5,80\n\n0.4,82\n", fileName: "x.csv")
        XCTAssertEqual(log.table.headers, ["loss", "acc"])
        XCTAssertEqual(log.rowCount, 2)
    }

    func testCellTyping() {
        XCTAssertEqual(LogMetricParser.cell("84.1"), .number(84.1))
        XCTAssertEqual(LogMetricParser.cell(" 85.8% "), .number(85.8))
        XCTAssertEqual(LogMetricParser.cell("1e-3"), .number(0.001))
        XCTAssertEqual(LogMetricParser.cell("FedAvg"), .text("FedAvg"))
        for blank in ["", "  ", "nan", "NaN", "null", "None", "N/A", "inf", "-"] {
            XCTAssertEqual(LogMetricParser.cell(blank), .empty, "'\(blank)'")
        }
        XCTAssertEqual(LogMetricParser.cell("1,5", decimalComma: true), .number(1.5))
        XCTAssertEqual(LogMetricParser.cell("1,5", decimalComma: false), .text("1,5"))
    }

    func testDecimalCommaWithSemicolonDelimiter() throws {
        let log = try LogMetricParser.parse(text: "name;acc\nA;84,5\nB;85,5", fileName: "eu.csv")
        XCTAssertEqual(log.table.rows[0][1], .number(84.5))
    }

    func testShortRowsArePaddedAndDuplicateHeadersMadeUnique() throws {
        let log = try LogMetricParser.parse(text: "a,a,\n1\n2,3,4", fileName: "x.csv")
        XCTAssertEqual(log.table.headers, ["a", "a (2)", "column 3"])
        XCTAssertEqual(log.table.rows[0], [.number(1), .empty, .empty])
    }

    func testEmptyAndHeaderOnlyFilesAreRejected() {
        XCTAssertThrowsError(try LogMetricParser.parse(text: "   \n", fileName: "x.csv")) {
            XCTAssertEqual($0 as? LogImportError, .empty)
        }
        XCTAssertThrowsError(try LogMetricParser.parse(text: "a,b", fileName: "x.csv"))
        XCTAssertThrowsError(try LogMetricParser.parse(data: Data(), fileName: "x.csv"))
    }
}

// MARK: - Detecting formats

final class LogMetricParserFormatTests: XCTestCase {

    func testMLflowCSV() throws {
        let parsed = try LogMetricParser.parse(text: rbA27_mlflowCSV, fileName: "runs.csv")
        XCTAssertEqual(parsed.format, .mlflowCSV)
        XCTAssertEqual(parsed.format.displayName, "MLflow CSV export")
        XCTAssertTrue(parsed.format.isRecognised)
        XCTAssertEqual(parsed.rowCount, 4)
        XCTAssertEqual(parsed.columnCount, 12)
    }

    func testMLflowSearchRunsDataFrameCSV() throws {
        let text = rbA27_lines([
            "run_id,experiment_id,status,metrics.acc,params.lr,tags.mlflow.runName",
            "a,1,FINISHED,84.5,0.01,FedAvg"
        ])
        XCTAssertEqual(try LogMetricParser.parse(text: text, fileName: "x.csv").format, .mlflowCSV)
    }

    func testWandbRunsAndHistoryCSV() throws {
        let runs = rbA27_lines([
            "Name,State,Notes,User,Tags,Created,Runtime,Sweep,lr,test_acc",
            "fedavg-1,finished,,gk,,2026-10-01,120,,0.01,84.1"
        ])
        XCTAssertEqual(try LogMetricParser.parse(text: runs, fileName: "w.csv").format, .wandbRunsCSV)

        let history = rbA27_lines([
            "Step,test_acc,test_acc__MIN,test_acc__MAX",
            "0,70,69,71",
            "1,80,79,81"
        ])
        XCTAssertEqual(try LogMetricParser.parse(text: history, fileName: "h.csv").format, .wandbHistoryCSV)
    }

    func testUnknownCSVIsGenericAndNotRecognised() throws {
        let parsed = try LogMetricParser.parse(text: "epoch,loss\n1,0.5\n2,0.4", fileName: "x.csv")
        XCTAssertEqual(parsed.format, .genericCSV)
        XCTAssertFalse(parsed.format.isRecognised)
    }

    func testWandbHistoryJSON() throws {
        let text = #"[{"_step":0,"loss":0.9,"_runtime":1.2},{"_step":1,"loss":0.5,"_runtime":2.2}]"#
        let parsed = try LogMetricParser.parse(text: text, fileName: "h.json")
        XCTAssertEqual(parsed.format, .wandbHistoryJSON)
        XCTAssertEqual(parsed.rowCount, 2)
    }

    func testMLflowRESTJSON() throws {
        let parsed = try LogMetricParser.parse(text: rbA27_mlflowRESTJSON, fileName: "runs.json")
        XCTAssertEqual(parsed.format, .mlflowJSON)
        XCTAssertEqual(parsed.rowCount, 2)
        XCTAssertTrue(parsed.table.headers.contains("params.lr"))
        XCTAssertTrue(parsed.table.headers.contains("run_name"))
    }

    func testMLflowMetricHistoryJSONIsPivotedByStep() throws {
        let text = #"{"metrics":[{"key":"loss","value":0.9,"step":0},{"key":"loss","value":0.5,"step":1},{"key":"acc","value":70,"step":1}]}"#
        let parsed = try LogMetricParser.parse(text: text, fileName: "history.json")

        XCTAssertEqual(parsed.format, .mlflowJSON)
        XCTAssertEqual(parsed.rowCount, 2)
        XCTAssertEqual(parsed.table.headers, ["acc", "loss", "step"])
    }

    func testOtherJSONShapes() throws {
        let wrapped = try LogMetricParser.parse(text: #"{"history":[{"loss":0.5},{"loss":0.4}]}"#, fileName: "a.json")
        XCTAssertEqual(wrapped.rowCount, 2)

        let columns = try LogMetricParser.parse(text: #"{"step":[0,1,2],"loss":[0.9,0.5,0.3]}"#, fileName: "b.json")
        XCTAssertEqual(columns.rowCount, 3)
        XCTAssertEqual(columns.format, .genericJSON)

        let summary = try LogMetricParser.parse(text: #"{"loss":0.3,"acc":90.5}"#, fileName: "wandb-summary.json")
        XCTAssertEqual(summary.rowCount, 1)

        let lines = try LogMetricParser.parse(text: "{\"loss\":0.5}\n{\"loss\":0.4}\n", fileName: "c.jsonl")
        XCTAssertEqual(lines.rowCount, 2)

        let nested = try LogMetricParser.parse(text: #"[{"config":{"lr":0.01},"loss":0.5,"tags":["a","b"]}]"#, fileName: "d.json")
        XCTAssertEqual(nested.table.headers, ["config.lr", "loss"], "arrays are skipped, objects are flattened")
    }

    func testBrokenJSONIsRejected() {
        XCTAssertThrowsError(try LogMetricParser.parse(text: "{ nope", fileName: "x.json")) {
            guard case .some(.unreadable) = ($0 as? LogImportError) else { return XCTFail("expected .unreadable") }
        }
    }
}

private let rbA27_mlflowRESTJSON = """
{"runs":[
 {"info":{"run_id":"a","run_name":"FedAvg","status":"FINISHED"},
  "data":{"metrics":[{"key":"acc","value":80,"step":1},{"key":"acc","value":84.5,"step":3}],
          "params":[{"key":"seed","value":"11"},{"key":"lr","value":"0.01"}],
          "tags":[{"key":"mlflow.source.git.commit","value":"abc123"}]}},
 {"info":{"run_id":"b","run_name":"FedAvg","status":"FAILED"},
  "data":{"metrics":[{"key":"acc","value":70,"step":2}],
          "params":[{"key":"seed","value":"22"},{"key":"lr","value":"0.01"}],
          "tags":[]}}
]}
"""

// MARK: - Mapping

final class LogMetricParserMappingTests: XCTestCase {

    func testMLflowCSVColumnsGetSensibleRoles() throws {
        let (_, mapping, _) = try rbA27_plan(rbA27_mlflowCSV)

        XCTAssertEqual(rbA27_role(mapping, "Run ID"), .runID)
        XCTAssertEqual(rbA27_role(mapping, "Run Name"), .setting)
        XCTAssertEqual(rbA27_role(mapping, "seed"), .seed)
        XCTAssertEqual(rbA27_role(mapping, "Status"), .status)
        XCTAssertEqual(rbA27_role(mapping, "lr"), .parameter)
        XCTAssertEqual(rbA27_role(mapping, "test_acc"), .metric)
        XCTAssertEqual(rbA27_role(mapping, "loss"), .metric)
        for ignored in ["Start Time", "Duration", "Source Type", "Source Name", "User"] {
            XCTAssertEqual(rbA27_role(mapping, ignored), .ignore, ignored)
        }
    }

    func testMetricDirectionUnitAndExample() throws {
        let (_, mapping, _) = try rbA27_plan(rbA27_mlflowCSV)
        let accuracy = try XCTUnwrap(mapping.first { $0.header == "test_acc" })
        let loss = try XCTUnwrap(mapping.first { $0.header == "loss" })

        XCTAssertTrue(accuracy.higherIsBetter)
        XCTAssertEqual(accuracy.unit, "%")
        XCTAssertEqual(accuracy.example, "84.1")
        XCTAssertFalse(loss.higherIsBetter)
        XCTAssertEqual(loss.unit, "")
        XCTAssertEqual(loss.metricName, "loss")
    }

    func testPrefixesAreStrippedFromMetricNames() throws {
        let parsed = try LogMetricParser.parse(text: rbA27_mlflowRESTJSON, fileName: "runs.json")
        let mapping = LogMetricParser.suggestMapping(for: parsed)

        XCTAssertEqual(rbA27_role(mapping, "run_id"), .runID)
        XCTAssertEqual(rbA27_role(mapping, "run_name"), .setting)
        XCTAssertEqual(rbA27_role(mapping, "status"), .status)
        XCTAssertEqual(rbA27_role(mapping, "params.seed"), .seed)
        XCTAssertEqual(rbA27_role(mapping, "params.lr"), .parameter)
        XCTAssertEqual(rbA27_role(mapping, "tags.mlflow.source.git.commit"), .codeCommit)
        XCTAssertEqual(rbA27_role(mapping, "acc"), .metric)
        XCTAssertEqual(mapping.first { $0.header == "params.lr" }?.metricName, "lr")
    }

    func testWandbRunsTable() throws {
        let text = rbA27_lines([
            "Name,State,Notes,User,Tags,Created,Runtime,Sweep,lr,test_acc",
            "fedavg,finished,,gk,,2026-10-01,120,,0.01,84.1"
        ])
        let (_, mapping, plan) = try rbA27_plan(text)

        XCTAssertEqual(rbA27_role(mapping, "Name"), .setting)
        XCTAssertEqual(rbA27_role(mapping, "State"), .status)
        XCTAssertEqual(rbA27_role(mapping, "Runtime"), .ignore)
        XCTAssertEqual(rbA27_role(mapping, "test_acc"), .metric)
        XCTAssertEqual(plan.runs.first?.setting, "fedavg")
        XCTAssertEqual(plan.runs.first?.status, "completed")
    }

    func testHistoryMinMaxColumnsAreIgnored() throws {
        let text = rbA27_lines(["Step,test_acc,test_acc__MIN,test_acc__MAX", "0,70,69,71", "1,80,79,81"])
        let (_, mapping, plan) = try rbA27_plan(text)

        XCTAssertEqual(rbA27_role(mapping, "Step"), .step)
        XCTAssertEqual(rbA27_role(mapping, "test_acc"), .metric)
        XCTAssertEqual(rbA27_role(mapping, "test_acc__MIN"), .ignore)
        XCTAssertEqual(rbA27_role(mapping, "test_acc__MAX"), .ignore)
        XCTAssertEqual(plan.runCount, 1, "a history file is one run")
    }

    func testOnlyOneSettingColumnIsChosen() throws {
        let text = rbA27_lines(["name,method,acc", "x,FedAvg,80", "y,FedProx,81"])
        let (_, mapping, _) = try rbA27_plan(text)
        XCTAssertEqual(mapping.filter { $0.role == .setting }.count, 1)
    }
}

// MARK: - Plans

final class LogMetricParserPlanTests: XCTestCase {

    func testOneRowPerRunWithSeedSuffixRemoved() throws {
        let (_, _, plan) = try rbA27_plan(rbA27_mlflowCSV, name: "mlruns.csv")

        XCTAssertEqual(plan.sourceFileName, "mlruns.csv")
        XCTAssertEqual(plan.format, .mlflowCSV)
        XCTAssertEqual(plan.runCount, 4)
        XCTAssertEqual(plan.metricRowCount, 8)
        XCTAssertEqual(plan.runs.map(\.setting), ["FedAvg", "FedAvg", "FedProx", "FedProx"])
        XCTAssertEqual(plan.runs.map(\.seed), [11, 22, 11, 22])
        XCTAssertEqual(plan.runs.map(\.status), Array(repeating: "completed", count: 4))
        XCTAssertEqual(plan.runs[0].config, ["lr": "0.01"])
        XCTAssertTrue(plan.warnings.contains { $0.contains("seed") && $0.contains("FedAvg-seed11") })

        let first = plan.runs[0].metrics
        XCTAssertEqual(first.map(\.name), ["test_acc", "loss"])
        XCTAssertEqual(first.map(\.value), [84.1, 0.52])
        XCTAssertEqual(first.map(\.step), [nil, nil])
        XCTAssertEqual(first.map(\.unit), ["%", ""])
        XCTAssertEqual(first.map(\.higherIsBetter), [true, false])
        XCTAssertEqual(plan.summaryLine, "Import 4 runs")
    }

    func testSeedSuffixCanBeKept() throws {
        let (_, _, plan) = try rbA27_plan(rbA27_mlflowCSV, options: ImportOptions(stripSeedSuffix: false))
        XCTAssertEqual(plan.runs.map(\.setting), ["FedAvg-seed11", "FedAvg-seed22", "FedProx-seed11", "FedProx-seed22"])
        XCTAssertFalse(plan.warnings.contains { $0.contains("Removed") })
    }

    func testModelNamesWithNumbersAreNotMistakenForSeeds() throws {
        let text = rbA27_lines(["run_name,acc", "resnet-50,80", "resnet-50,81", "resnet-18,78", "resnet-18,79"])
        let (_, _, plan) = try rbA27_plan(text)
        XCTAssertEqual(Set(plan.runs.map(\.setting)), ["resnet-50", "resnet-18"])
    }

    func testTrailingNumberIsStrippedWhenItEqualsTheSeedColumn() throws {
        let text = rbA27_lines(["run_name,seed,acc", "base-11,11,80", "base-22,22,81", "base-33,33,82"])
        let (_, _, plan) = try rbA27_plan(text)
        XCTAssertEqual(Set(plan.runs.map(\.setting)), ["base"])
        XCTAssertEqual(plan.runs.map(\.seed), [11, 22, 33])
    }

    func testPrototypeExampleFifteenRunsThirtyMetrics() throws {
        var lines = ["run_name,seed,step,test_acc,loss"]
        for setting in ["FedAvg", "FedProx", "SCAFFOLD"] {
            for seed in [11, 22, 33, 44, 55] { lines.append("\(setting),\(seed),100,85.\(seed % 10),0.4\(seed % 10)") }
        }
        let (parsed, mapping, plan) = try rbA27_plan(rbA27_lines(lines))

        XCTAssertEqual(parsed.rowCount, 15)
        XCTAssertEqual(parsed.columnCount, 5)
        XCTAssertEqual(rbA27_role(mapping, "step"), .step)
        XCTAssertEqual(plan.runCount, 15)
        XCTAssertEqual(plan.metricRowCount, 30)
        XCTAssertEqual(plan.summaryLine, "Import 15 runs")
        XCTAssertEqual(plan.runs[0].config["step"], "100", "a single final row keeps its round as information")
        XCTAssertTrue(plan.runs.allSatisfy { run in run.metrics.allSatisfy { $0.step == nil } })
    }

    func testRowsOfOneRunBecomeACurveWithAFinalValue() throws {
        let text = rbA27_lines([
            "run_name,seed,step,test_acc,loss",
            "FedAvg,11,50,80.0,0.9",
            "FedAvg,11,100,84.1,0.5",
            "FedAvg,22,50,81.0,0.8",
            "FedAvg,22,100,84.5,0.4",
            "FedProx,11,100,85.0,0.45"
        ])
        let (_, _, plan) = try rbA27_plan(text)

        XCTAssertEqual(plan.runCount, 3)
        XCTAssertEqual(plan.metricRowCount, 6 + 6 + 2)

        let curve = plan.runs[0].metrics
        XCTAssertEqual(curve.map(\.name), ["test_acc", "test_acc", "test_acc", "loss", "loss", "loss"])
        XCTAssertEqual(curve.map(\.step), [50, 100, nil, 50, 100, nil])
        XCTAssertEqual(curve.map(\.value), [80.0, 84.1, 84.1, 0.9, 0.5, 0.5])
        XCTAssertEqual(plan.runs[2].metrics.map(\.step), [nil, nil])
    }

    func testFinalValuesOnlyWhenCurvesAreOff() throws {
        let text = rbA27_lines(["run_name,seed,step,acc", "A,1,10,70", "A,1,20,80", "A,1,30,85"])
        let (_, _, plan) = try rbA27_plan(text, options: ImportOptions(includeCurves: false))

        XCTAssertEqual(plan.runCount, 1)
        XCTAssertEqual(plan.runs[0].metrics.map(\.value), [85])
        XCTAssertEqual(plan.runs[0].metrics.map(\.step), [nil])
    }

    func testFinalValueIsTheLastStepEvenWhenRowsAreOutOfOrder() throws {
        let text = rbA27_lines(["run_name,seed,step,acc", "A,1,30,85", "A,1,10,70", "A,1,20,80"])
        let (_, _, plan) = try rbA27_plan(text)

        XCTAssertEqual(plan.runs[0].metrics.map(\.step), [10, 20, 30, nil])
        XCTAssertEqual(plan.runs[0].metrics.last?.value, 85)
    }

    func testSameSettingSeedAndStepTwiceMeansSeparateRuns() throws {
        let text = rbA27_lines(["run_name,seed,step,acc", "A,1,100,80", "A,1,100,82", "A,2,100,81"])
        let (_, _, plan) = try rbA27_plan(text)

        XCTAssertEqual(plan.runCount, 3)
        XCTAssertTrue(plan.warnings.contains { $0.contains("separate runs") })
    }

    func testRunIDRepeatedWithoutAStepUsesRowOrder() throws {
        let text = rbA27_lines(["run_id,run_name,loss", "r1,A,0.9", "r1,A,0.5", "r2,A,0.8"])
        let (_, _, plan) = try rbA27_plan(text)

        XCTAssertEqual(plan.runCount, 2)
        XCTAssertEqual(plan.runs[0].metrics.map(\.step), [0, 1, nil])
        XCTAssertTrue(plan.warnings.contains { $0.contains("row order") })
    }

    func testWandbHistoryJSONIsOneRunWithACurve() throws {
        let text = #"[{"_step":0,"loss":0.9,"_runtime":1.2},{"_step":1,"loss":0.5,"_runtime":2.2}]"#
        let (_, _, plan) = try rbA27_plan(text, name: "history.json")

        XCTAssertEqual(plan.runCount, 1)
        XCTAssertEqual(plan.runs[0].setting, "default")
        XCTAssertEqual(plan.runs[0].metrics.map(\.step), [0, 1, nil])
        XCTAssertEqual(plan.runs[0].metrics.map(\.value), [0.9, 0.5, 0.5])
    }

    func testMLflowRESTJSON() throws {
        let (_, _, plan) = try rbA27_plan(rbA27_mlflowRESTJSON, name: "runs.json")

        XCTAssertEqual(plan.runCount, 2)
        XCTAssertEqual(plan.runs[0].metrics.first?.value, 84.5, "the highest step of a metric wins")
        XCTAssertEqual(plan.runs[0].codeCommit, "abc123")
        XCTAssertEqual(plan.runs[0].seed, 11)
        XCTAssertEqual(plan.runs[0].config["lr"], "0.01")
        XCTAssertEqual(plan.runs.map(\.status), ["completed", "failed"])
        XCTAssertEqual(plan.runs.map(\.setting), ["FedAvg", "FedAvg"])
    }

    func testRowsWithoutMetricValuesAreSkipped() throws {
        let text = rbA27_lines(["run_name,acc", "A,80", "B,", "C,nan", "D,82"])
        let (_, _, plan) = try rbA27_plan(text)

        XCTAssertEqual(plan.runs.map(\.setting), ["A", "D"])
        XCTAssertEqual(plan.skippedRows, 2)
        XCTAssertTrue(plan.warnings.contains { $0.contains("2 rows have no metric value") })
    }

    func testNoMetricColumnGivesAnEmptyPlanWithAWarning() throws {
        let (parsed, mapping, _) = try rbA27_plan(rbA27_mlflowCSV)
        let ignoreAll = mapping.map { m -> ColumnMapping in var copy = m; if copy.role == .metric { copy.role = .ignore }; return copy }
        let plan = LogMetricParser.makePlan(from: parsed, mapping: ignoreAll)

        XCTAssertEqual(plan.runCount, 0)
        XCTAssertTrue(plan.warnings.contains { $0.contains("No column is mapped as a metric") })
    }

    func testChangingTheMappingChangesThePlan() throws {
        let (parsed, mapping, _) = try rbA27_plan(rbA27_mlflowCSV)
        let withoutLoss = mapping.map { m -> ColumnMapping in var copy = m; if copy.header == "loss" { copy.role = .ignore }; return copy }
        let plan = LogMetricParser.makePlan(from: parsed, mapping: withoutLoss)

        XCTAssertEqual(plan.metricRowCount, 4)
        XCTAssertEqual(Set(plan.runs.flatMap { $0.metrics.map(\.name) }), ["test_acc"])
    }

    func testStatusWords() throws {
        let text = rbA27_lines(["name,status,acc", "a,RUNNING,1", "b,FAILED,2", "c,KILLED,3", "d,SCHEDULED,4", "e,FINISHED,5", "f,,6"])
        let (_, _, plan) = try rbA27_plan(text)
        XCTAssertEqual(plan.runs.map(\.status), ["running", "failed", "failed", "planned", "completed", "completed"])
    }
}

// MARK: - Writing to the library

@MainActor
final class LogMetricImporterTests: XCTestCase {

    private func count(_ model: LibraryModel, _ sql: String, _ params: [SQLValue] = []) throws -> Int {
        Int(try model.database.rows(sql, params).first?.int("n") ?? 0)
    }

    func testCommitWritesRunsAndMetrics() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let exp = try ModelTestSupport.insertExperiment(model)
        let importer = LogMetricImporter(model: model)

        let (_, _, plan) = try rbA27_plan(rbA27_mlflowCSV, name: "mlruns.csv")
        let result = try importer.commit(plan, toExperiment: exp)

        XCTAssertEqual(result.runsAdded, 4)
        XCTAssertEqual(result.metricsAdded, 8)
        XCTAssertEqual(result.runIDs.count, 4)
        XCTAssertEqual(result.summaryLine, "Imported 4 runs and 8 metrics")

        let runs = try model.database.rows(
            "SELECT setting, run_number, seed, status, source_file, notes, config_json FROM runs WHERE experiment_id = ? ORDER BY run_number",
            [.text(exp)]
        )
        XCTAssertEqual(runs.compactMap { $0.text("setting") }, ["FedAvg", "FedAvg", "FedProx", "FedProx"])
        XCTAssertEqual(runs.compactMap { $0.int("run_number") }, [1, 2, 3, 4])
        XCTAssertEqual(runs.compactMap { $0.int("seed") }, [11, 22, 11, 22])
        XCTAssertEqual(Set(runs.compactMap { $0.text("status") }), ["completed"])
        XCTAssertEqual(Set(runs.compactMap { $0.text("source_file") }), ["mlruns.csv"], "the file name is kept on every run")
        XCTAssertEqual(runs.first?.text("notes"), "Imported from mlruns.csv")
        XCTAssertEqual(runs.first?.text("config_json"), #"{"lr":"0.01"}"#)

        XCTAssertEqual(try count(model, "SELECT COUNT(*) AS n FROM metrics"), 8)
        XCTAssertEqual(try count(model, "SELECT COUNT(*) AS n FROM metrics WHERE name = 'loss' AND higher_is_better = 0"), 4)
        XCTAssertEqual(try count(model, "SELECT COUNT(*) AS n FROM metrics WHERE unit = '%'"), 4)
        XCTAssertEqual(try count(model, "SELECT COUNT(*) AS n FROM metrics WHERE step IS NOT NULL"), 0)
    }

    func testCurvesAreStoredWithStepsAndAFinalRow() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let exp = try ModelTestSupport.insertExperiment(model)

        let text = rbA27_lines(["run_name,seed,step,acc", "A,1,10,70", "A,1,20,80"])
        let (_, _, plan) = try rbA27_plan(text)
        _ = try LogMetricImporter(model: model).commit(plan, toExperiment: exp)

        XCTAssertEqual(try count(model, "SELECT COUNT(*) AS n FROM metrics WHERE step IS NOT NULL"), 2)
        let final = try model.database.rows("SELECT value FROM metrics WHERE step IS NULL")
        XCTAssertEqual(final.count, 1)
        guard case .double(let value) = final[0]["value"] else { return XCTFail("expected a REAL value") }
        XCTAssertEqual(value, 80, accuracy: 1e-12)
    }

    func testRunNumbersContinueAfterExistingRuns() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let exp = try ModelTestSupport.insertExperiment(model)
        let importer = LogMetricImporter(model: model)

        let (_, _, plan) = try rbA27_plan(rbA27_mlflowCSV)
        _ = try importer.commit(plan, toExperiment: exp)
        _ = try importer.commit(plan, toExperiment: exp)

        XCTAssertEqual(try count(model, "SELECT MAX(run_number) AS n FROM runs WHERE experiment_id = ?", [.text(exp)]), 8)
        XCTAssertEqual(try importer.alreadyImportedRunCount(sourceFile: "log.csv", experimentID: exp), 8)
        XCTAssertEqual(try importer.alreadyImportedRunCount(sourceFile: "other.csv", experimentID: exp), 0)
    }

    func testImportedRunsFeedTheStatisticsTab() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let exp = try ModelTestSupport.insertExperiment(model)

        let (_, _, plan) = try rbA27_plan(rbA27_mlflowCSV)
        _ = try LogMetricImporter(model: model).commit(plan, toExperiment: exp)

        let analysis = try RunStatisticsLoader(model: model).analysis(experimentID: exp, metric: "test_acc")
        XCTAssertEqual(analysis.settings.map(\.name), ["FedAvg", "FedProx"])
        XCTAssertEqual(analysis.settings[0].values, [84.1, 84.5])
        XCTAssertEqual(analysis.bestSetting, "FedProx")

        let lossInfo = try RunStatisticsLoader(model: model).metrics(experimentID: exp).first { $0.name == "loss" }
        XCTAssertEqual(lossInfo?.higherIsBetter, false)
    }

    func testCommitRefusesAMissingExperimentAndAnEmptyPlan() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let importer = LogMetricImporter(model: model)

        let (_, _, plan) = try rbA27_plan(rbA27_mlflowCSV)
        XCTAssertThrowsError(try importer.commit(plan, toExperiment: "nope")) {
            XCTAssertEqual($0 as? ModelError, .notFound(kind: "experiment", id: "nope"))
        }

        let exp = try ModelTestSupport.insertExperiment(model)
        var empty = plan
        empty.runs = []
        XCTAssertThrowsError(try importer.commit(empty, toExperiment: exp)) {
            XCTAssertEqual($0 as? LogImportError, .nothingToImport)
        }
        XCTAssertEqual(try count(model, "SELECT COUNT(*) AS n FROM runs"), 0)
    }

    func testParsingAFileFromDisk() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let url = try ModelTestSupport.makeFile(self, name: "mlruns.csv", content: rbA27_mlflowCSV)
        let parsed = try LogMetricImporter(model: model).parse(fileAt: url)

        XCTAssertEqual(parsed.fileName, "mlruns.csv")
        XCTAssertEqual(parsed.format, .mlflowCSV)

        let missing = url.deletingLastPathComponent().appendingPathComponent("nope.csv")
        XCTAssertThrowsError(try LogMetricImporter(model: model).parse(fileAt: missing))
    }
}
