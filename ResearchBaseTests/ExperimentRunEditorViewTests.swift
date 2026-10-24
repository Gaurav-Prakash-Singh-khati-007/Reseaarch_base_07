//
//  ExperimentRunEditorViewTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 23/10/26.
//


//
//  ExperimentRunEditorViewTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 73 · Features: F-41, F-43
//

import XCTest
@testable import ResearchBase

private let rbA73_mlflowCSV = [
    "Start Time,Duration,Run ID,Run Name,Source Type,Source Name,User,Status,lr,seed,test_acc,loss",
    "2026-10-01 10:00:00,1.2min,r1,FedAvg-seed11,LOCAL,train.py,gk,FINISHED,0.01,11,84.1,0.52",
    "2026-10-01 10:05:00,1.2min,r2,FedAvg-seed22,LOCAL,train.py,gk,FINISHED,0.01,22,84.5,0.50",
    "2026-10-01 10:10:00,1.2min,r3,FedProx-seed11,LOCAL,train.py,gk,FINISHED,0.01,11,85.0,0.45",
    "2026-10-01 10:15:00,1.2min,r4,FedProx-seed22,LOCAL,train.py,gk,FINISHED,0.01,22,85.4,0.44"
].joined(separator: "\n")

@MainActor
final class ExperimentRunEditorViewTests: XCTestCase {

    private func draft() throws -> RBA73ImportLogic.Draft {
        try RBA73ImportLogic.load(data: Data(rbA73_mlflowCSV.utf8), fileName: "runs.csv")
    }

    func testLoadDetectsFormatAndPlansRuns() throws {
        let d = try draft()
        XCTAssertEqual(d.parsed.format, .mlflowCSV)
        XCTAssertEqual(d.plan.runCount, 4)
        XCTAssertFalse(d.plan.runs[0].metrics.isEmpty)
    }

    func testChosenRunGivesFinalMetricsOnly() throws {
        let d = try draft()
        let metrics = RBA73ImportLogic.finalMetrics(of: d.plan.runs[0])
        XCTAssertTrue(metrics.contains { $0.name.lowercased().contains("acc") })
        XCTAssertTrue(metrics.contains { $0.name.lowercased().contains("loss") })
    }

    func testChangingAColumnToIgnoreReplans() throws {
        var d = try draft()
        let before = d.plan.metricRowCount
        if let index = d.mapping.firstIndex(where: { $0.role == .metric }) {
            d.mapping[index].role = .ignore
        }
        let after = RBA73ImportLogic.replan(d).plan.metricRowCount
        XCTAssertLessThan(after, before)
    }

    func testMergeReplacesSameNameAndKeepsIdentity() {
        let existingID = UUID()
        let current = [MetricEditorResult(existingID: existingID, name: "Accuracy", value: 80, unit: "%", higherIsBetter: true)]
        let incoming = [
            MetricEditorResult(name: "accuracy", value: 84.1, unit: "%", higherIsBetter: true),
            MetricEditorResult(name: "Loss", value: 0.5, unit: "", higherIsBetter: false)
        ]

        let merged = RBA73ImportLogic.merge(incoming, into: current)

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].existingID, existingID)
        XCTAssertEqual(merged[0].value, 84.1)
        XCTAssertEqual(merged[1].name, "Loss")
    }

    func testSeedParsing() {
        XCTAssertEqual(RBA73ImportLogic.parseSeeds(""), [])
        XCTAssertEqual(RBA73ImportLogic.parseSeeds("11, 22 33;44"), [11, 22, 33, 44])
        XCTAssertNil(RBA73ImportLogic.parseSeeds("11, abc"))
        XCTAssertEqual(RBA73ImportLogic.seedsText([11, 22]), "11, 22")
    }

    func testCommitValidation() {
        XCTAssertTrue(RBA73ImportLogic.commitIsAcceptable(""))
        XCTAssertTrue(RBA73ImportLogic.commitIsAcceptable(" A1B2C3D "))
        XCTAssertFalse(RBA73ImportLogic.commitIsAcceptable("xyz"))
        XCTAssertFalse(RBA73ImportLogic.commitIsAcceptable("abc12"))
    }

    func testConfigurationTextIsSortedLines() {
        XCTAssertEqual(RBA73ImportLogic.configurationText(["lr": "0.01", "batch": "32"]), "batch: 32\nlr: 0.01")
    }

    func testRunLabel() throws {
        let d = try draft()
        let label = RBA73ImportLogic.runLabel(d.plan.runs[0], index: 0)
        XCTAssertTrue(label.hasPrefix("Run 1"))
    }

    func testImportAllWritesRunsToTheLibrary() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let experimentID = try ModelTestSupport.insertExperiment(model)
        let target = RBA73LibraryTarget(model: model, experimentID: experimentID)

        let first = try RBA73ImportLogic.commitAll(try draft(), to: target)
        XCTAssertEqual(first.result.runsAdded, 4)
        XCTAssertEqual(first.alreadyThere, 0)

        let second = try RBA73ImportLogic.commitAll(try draft(), to: target)
        XCTAssertEqual(second.alreadyThere, 4)
        XCTAssertEqual(try ModelTestSupport.count(model, "runs"), 8)
    }
}