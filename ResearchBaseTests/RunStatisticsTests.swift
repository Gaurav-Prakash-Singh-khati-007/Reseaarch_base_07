//
//  RunStatisticsTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 26 · Features: F-42
//
//  The reference numbers (t, df, p, intervals, quantiles) were computed
//  independently with SciPy, not with this code.
//

import XCTest
@testable import ResearchBase

// MARK: - Pure maths

final class RunStatisticsMathTests: XCTestCase {

    private let a = [84.1, 84.5, 84.9, 84.3, 84.7]
    private let b = [86.2, 86.8, 86.5, 86.9, 86.4]

    // MARK: Spread

    func testSummaryOfFiveRuns() throws {
        let s = try XCTUnwrap(RunStatistics.summarize(a))
        XCTAssertEqual(s.count, 5)
        XCTAssertEqual(s.mean, 84.5, accuracy: 1e-9)
        XCTAssertEqual(s.sd, 0.31622776601684244, accuracy: 1e-9)
        XCTAssertEqual(s.sem, 0.1414213562373115, accuracy: 1e-9)
        XCTAssertEqual(s.min, 84.1, accuracy: 1e-12)
        XCTAssertEqual(s.max, 84.9, accuracy: 1e-12)
        XCTAssertEqual(s.median, 84.5, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(s.ci95HalfWidth), 0.392648632295517, accuracy: 1e-6)
    }

    func testSummaryEdgeCases() throws {
        XCTAssertNil(RunStatistics.summarize([]))
        XCTAssertNil(RunStatistics.summarize([.nan, .infinity]))

        let one = try XCTUnwrap(RunStatistics.summarize([7]))
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one.sd, 0)
        XCTAssertNil(one.ci95HalfWidth)

        XCTAssertEqual(try XCTUnwrap(RunStatistics.summarize([3, 1, 2, 10])).median, 2.5, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(RunStatistics.summarize([1, .nan, 3])).count, 2, "non-finite values are ignored")
    }

    // MARK: Welch

    func testWelchMatchesSciPy() throws {
        let r = RunStatistics.welch(b, versus: a)

        XCTAssertEqual(try XCTUnwrap(r.meanDifference), 2.06, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(r.t), 10.767792493879787, accuracy: 1e-8)
        XCTAssertEqual(try XCTUnwrap(r.degreesOfFreedom), 7.9315530818875954, accuracy: 1e-8)

        let p = try XCTUnwrap(r.p)
        XCTAssertEqual(p, 5.204113927055701e-06, accuracy: 5e-10)

        let ci = try XCTUnwrap(r.confidenceInterval95)
        XCTAssertEqual(ci.lowerBound, 1.6181718732083639, accuracy: 1e-5)
        XCTAssertEqual(ci.upperBound, 2.5018281267916125, accuracy: 1e-5)

        XCTAssertEqual(try XCTUnwrap(r.cohensD), 6.810149930544963, accuracy: 1e-6)
        XCTAssertEqual(r.verdict, .likelyReal)
        XCTAssertFalse(r.smallSample, "5 runs each is not a small sample")
    }

    func testUnclearDifferenceWithThreeRuns() throws {
        let r = RunStatistics.welch([84.0, 84.9, 85.2], versus: a)

        XCTAssertEqual(try XCTUnwrap(r.t), 0.5163977794943271, accuracy: 1e-8)
        XCTAssertEqual(try XCTUnwrap(r.p), 0.6457879909882117, accuracy: 1e-6)
        XCTAssertEqual(r.verdict, .unclear)
        XCTAssertTrue(r.smallSample)
    }

    func testSwappingTheSettingsFlipsTheSignOnly() throws {
        let forward = RunStatistics.welch(b, versus: a)
        let backward = RunStatistics.welch(a, versus: b)

        XCTAssertEqual(try XCTUnwrap(backward.meanDifference), -2.06, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(backward.t), -10.767792493879787, accuracy: 1e-8)
        XCTAssertEqual(try XCTUnwrap(backward.p), try XCTUnwrap(forward.p), accuracy: 1e-12)
        let forwardCI = try XCTUnwrap(forward.confidenceInterval95)
        let backwardCI = try XCTUnwrap(backward.confidenceInterval95)
        XCTAssertEqual(backwardCI.lowerBound, -forwardCI.upperBound, accuracy: 1e-6)
    }

    func testOneGroupWithNoSpreadStillTests() throws {
        let r = RunStatistics.welch([6, 7, 8], versus: [5, 5, 5])

        XCTAssertEqual(try XCTUnwrap(r.t), 3.464101615137755, accuracy: 1e-8)
        XCTAssertEqual(try XCTUnwrap(r.degreesOfFreedom), 2.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(r.p), 0.07417990022744854, accuracy: 1e-6)
        XCTAssertEqual(r.verdict, .unclear)
    }

    func testTooFewRuns() throws {
        let one = RunStatistics.welch([90], versus: a)
        XCTAssertEqual(one.verdict, .notEnoughData)
        XCTAssertNil(one.p)
        XCTAssertEqual(try XCTUnwrap(one.meanDifference), 90 - 84.5, accuracy: 1e-9)

        let none = RunStatistics.welch([], versus: a)
        XCTAssertEqual(none.verdict, .notEnoughData)
        XCTAssertNil(none.meanDifference)
    }

    func testNoVariationAnywhere() {
        let same = RunStatistics.welch([5, 5, 5], versus: [5, 5, 5])
        XCTAssertEqual(same.verdict, .noVariation)
        XCTAssertEqual(same.p, 1.0)

        let different = RunStatistics.welch([6, 6], versus: [5, 5])
        XCTAssertEqual(different.verdict, .noVariation)
        XCTAssertNil(different.p, "a difference between constants cannot be tested")
        XCTAssertEqual(different.meanDifference, 1.0)
    }

    // MARK: One sample

    func testOneSampleAgainstABaselineMatchesSciPy() throws {
        let r = RunStatistics.oneSample(b, against: 84.7)

        XCTAssertEqual(try XCTUnwrap(r.t), 14.436399778137707, accuracy: 1e-7)
        XCTAssertEqual(try XCTUnwrap(r.degreesOfFreedom), 4)
        XCTAssertEqual(try XCTUnwrap(r.p), 0.0001338287728436079, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(r.meanDifference), 86.56 - 84.7, accuracy: 1e-9)
        XCTAssertEqual(r.verdict, .likelyReal)
    }

    func testOneSampleEdgeCases() {
        XCTAssertEqual(RunStatistics.oneSample([1], against: 0).verdict, .notEnoughData)
        XCTAssertEqual(RunStatistics.oneSample([], against: 0).verdict, .notEnoughData)
        XCTAssertEqual(RunStatistics.oneSample([2, 2, 2], against: 2).p, 1.0)
        XCTAssertEqual(RunStatistics.oneSample([2, 2, 2], against: 3).verdict, .noVariation)
    }

    // MARK: Student's t pieces

    func testTwoSidedP() {
        XCTAssertEqual(RunStatistics.twoSidedP(t: 2.5, degreesOfFreedom: 7), 0.04099221858575289, accuracy: 1e-8)
        XCTAssertEqual(RunStatistics.twoSidedP(t: 0, degreesOfFreedom: 7), 1.0, accuracy: 1e-12)
        XCTAssertEqual(RunStatistics.twoSidedP(t: -2.5, degreesOfFreedom: 7), 0.04099221858575289, accuracy: 1e-8)
    }

    func testTQuantiles() {
        let expected: [(df: Double, q: Double)] = [
            (1, 12.70620474), (2, 4.30265273), (4, 2.77644511), (10, 2.22813885), (30, 2.04227246)
        ]
        for (df, q) in expected {
            XCTAssertEqual(RunStatistics.tQuantile(0.975, degreesOfFreedom: df), q, accuracy: 1e-4, "df \(df)")
        }
    }

    // MARK: Many settings

    func testCompareAllListsEveryPairInOrder() {
        let settings = [
            SettingSamples(name: "FedAvg", values: a),
            SettingSamples(name: "FedProx", values: [84.0, 84.9, 85.2]),
            SettingSamples(name: "SCAFFOLD", values: b)
        ]
        let rows = RunStatistics.compareAll(settings)

        XCTAssertEqual(rows.map(\.label), ["FedProx vs FedAvg", "SCAFFOLD vs FedAvg", "SCAFFOLD vs FedProx"])
        XCTAssertEqual(rows[1].result.verdict, .likelyReal)
        XCTAssertEqual(rows[0].result.verdict, .unclear)
        XCTAssertTrue(RunStatistics.compareAll([settings[0]]).isEmpty)
        XCTAssertTrue(RunStatistics.compareAll([]).isEmpty)
    }

    func testBestSetting() {
        let settings = [
            SettingSamples(name: "A", values: [1, 2, 3]),
            SettingSamples(name: "empty", values: []),
            SettingSamples(name: "B", values: [5, 5]),
            SettingSamples(name: "C", values: [5, 5])
        ]
        XCTAssertEqual(RunStatistics.bestSetting(settings, higherIsBetter: true), "B", "a tie goes to the earlier setting")
        XCTAssertEqual(RunStatistics.bestSetting(settings, higherIsBetter: false), "A")
        XCTAssertNil(RunStatistics.bestSetting([]))
    }

    // MARK: Text

    func testFormatting() throws {
        XCTAssertEqual(RunStatistics.formatP(0.0004), "< 0.001")
        XCTAssertEqual(RunStatistics.formatP(0.03199), "0.032")
        XCTAssertEqual(RunStatistics.formatP(nil), "n/a")
        XCTAssertEqual(RunStatistics.formatP(.nan), "n/a")

        let s = try XCTUnwrap(RunStatistics.summarize(b))
        XCTAssertEqual(RunStatistics.formatMeanSD(s), "86.6 ± 0.3")
        XCTAssertEqual(RunStatistics.formatMeanSD(s, decimals: 2), "86.56 ± 0.29")
        XCTAssertEqual(RunStatistics.formatRange(s), "86.2–86.9")
        XCTAssertEqual(RunStatistics.formatMeanSD(try XCTUnwrap(RunStatistics.summarize([90]))), "90.0 (1 run)")

        XCTAssertEqual(SignificanceVerdict.likelyReal.chipText, "Likely real")
        XCTAssertEqual(SignificanceVerdict.unclear.chipText, "Unclear")
    }
}

// MARK: - Reading the library

@MainActor
final class RunStatisticsLoaderTests: XCTestCase {

    private func addRun(
        _ model: LibraryModel, experiment: String, setting: String, number: Int,
        status: String = "completed", metrics: [(name: String, value: Double, step: Int?, higher: Bool)] = []
    ) throws -> String {
        let runID = UUID().uuidString
        try model.database.run(
            "INSERT INTO runs (id, experiment_id, setting, run_number, seed, status) VALUES (?, ?, ?, ?, ?, ?)",
            [.text(runID), .text(experiment), .text(setting), .int(Int64(number)), .int(Int64(number * 11)), .text(status)]
        )
        for metric in metrics {
            try model.database.run(
                "INSERT INTO metrics (id, run_id, name, value, unit, higher_is_better, step) VALUES (?, ?, ?, ?, '', ?, ?)",
                [.text(UUID().uuidString), .text(runID), .text(metric.name), .double(metric.value),
                 .int(metric.higher ? 1 : 0), metric.step.map { SQLValue.int(Int64($0)) } ?? SQLValue.null]
            )
        }
        return runID
    }

    private func acc(_ value: Double) -> [(name: String, value: Double, step: Int?, higher: Bool)] {
        [("test_accuracy", value, nil, true)]
    }

    func testSettingsAreGroupedInOrderOfFirstRun() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let exp = try ModelTestSupport.insertExperiment(model)

        _ = try addRun(model, experiment: exp, setting: "FedAvg", number: 1, metrics: acc(84.1))
        _ = try addRun(model, experiment: exp, setting: "SCAFFOLD", number: 2, metrics: acc(86.2))
        _ = try addRun(model, experiment: exp, setting: "FedAvg", number: 3, metrics: acc(84.5))
        _ = try addRun(model, experiment: exp, setting: "SCAFFOLD", number: 4, metrics: acc(86.8))

        let samples = try RunStatisticsLoader(model: model).settings(experimentID: exp, metric: "test_accuracy")

        XCTAssertEqual(samples.map(\.name), ["FedAvg", "SCAFFOLD"])
        XCTAssertEqual(samples[0].values, [84.1, 84.5])
        XCTAssertEqual(samples[1].values, [86.2, 86.8])
    }

    func testOnlyCompletedRunsAndFinalValuesCount() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let exp = try ModelTestSupport.insertExperiment(model)

        _ = try addRun(model, experiment: exp, setting: "A", number: 1, metrics: acc(80))
        _ = try addRun(model, experiment: exp, setting: "A", number: 2, status: "failed", metrics: acc(10))
        _ = try addRun(model, experiment: exp, setting: "A", number: 3, status: "running", metrics: acc(20))
        // a training curve: step rows are not final values
        _ = try addRun(model, experiment: exp, setting: "A", number: 4, metrics: [
            ("test_accuracy", 50, 1, true), ("test_accuracy", 70, 2, true), ("test_accuracy", 82, nil, true)
        ])
        // another metric, and another experiment
        _ = try addRun(model, experiment: exp, setting: "A", number: 5, metrics: [("loss", 0.3, nil, false)])
        let other = try ModelTestSupport.insertExperiment(model)
        _ = try addRun(model, experiment: other, setting: "A", number: 1, metrics: acc(99))

        let samples = try RunStatisticsLoader(model: model).settings(experimentID: exp, metric: "test_accuracy")
        XCTAssertEqual(samples, [SettingSamples(name: "A", values: [80, 82])])
    }

    func testWhenARunRecordedAMetricTwiceTheLastWins() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let exp = try ModelTestSupport.insertExperiment(model)

        _ = try addRun(model, experiment: exp, setting: "A", number: 1, metrics: [
            ("test_accuracy", 70, nil, true), ("test_accuracy", 75, nil, true)
        ])
        let samples = try RunStatisticsLoader(model: model).settings(experimentID: exp, metric: "test_accuracy")
        XCTAssertEqual(samples.first?.values, [75])
    }

    func testMetricsListWithDirection() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let exp = try ModelTestSupport.insertExperiment(model)

        for n in 1...3 {
            _ = try addRun(model, experiment: exp, setting: "A", number: n, metrics: [
                ("test_accuracy", 80 + Double(n), nil, true), ("loss", 0.5, nil, false)
            ])
        }
        _ = try addRun(model, experiment: exp, setting: "A", number: 4, metrics: [("f1", 0.7, nil, true)])

        let list = try RunStatisticsLoader(model: model).metrics(experimentID: exp)

        XCTAssertEqual(list.map(\.name), ["loss", "test_accuracy", "f1"], "most-recorded first, then by name")
        XCTAssertEqual(list.first { $0.name == "loss" }?.higherIsBetter, false)
        XCTAssertEqual(list.first { $0.name == "test_accuracy" }?.higherIsBetter, true)
        XCTAssertEqual(list.first { $0.name == "test_accuracy" }?.runCount, 3)
    }

    func testAnalysisEndToEnd() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let exp = try ModelTestSupport.insertExperiment(model)

        let fedAvg = [84.1, 84.5, 84.9, 84.3, 84.7]
        let scaffold = [86.2, 86.8, 86.5, 86.9, 86.4]
        for (i, value) in fedAvg.enumerated() {
            _ = try addRun(model, experiment: exp, setting: "FedAvg", number: i + 1, metrics: acc(value))
        }
        for (i, value) in scaffold.enumerated() {
            _ = try addRun(model, experiment: exp, setting: "SCAFFOLD", number: i + 6, metrics: acc(value))
        }

        let analysis = try RunStatisticsLoader(model: model).analysis(experimentID: exp, metric: "test_accuracy")

        XCTAssertEqual(analysis.settings.map(\.name), ["FedAvg", "SCAFFOLD"])
        XCTAssertEqual(analysis.bestSetting, "SCAFFOLD")
        XCTAssertTrue(analysis.higherIsBetter)
        XCTAssertEqual(try XCTUnwrap(analysis.summary(for: "FedAvg")).mean, 84.5, accuracy: 1e-9)
        XCTAssertNil(analysis.summary(for: "nope"))

        XCTAssertEqual(analysis.comparisons.map(\.label), ["SCAFFOLD vs FedAvg"])
        XCTAssertEqual(analysis.comparisons[0].result.verdict, .likelyReal)
        XCTAssertEqual(try XCTUnwrap(analysis.comparisons[0].result.p), 5.204113927055701e-06, accuracy: 5e-10)
    }

    func testLowerIsBetterPicksTheSmallestMean() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let exp = try ModelTestSupport.insertExperiment(model)

        for (i, value) in [0.9, 1.0].enumerated() {
            _ = try addRun(model, experiment: exp, setting: "slow", number: i + 1, metrics: [("loss", value, nil, false)])
        }
        for (i, value) in [0.3, 0.4].enumerated() {
            _ = try addRun(model, experiment: exp, setting: "good", number: i + 3, metrics: [("loss", value, nil, false)])
        }

        let analysis = try RunStatisticsLoader(model: model).analysis(experimentID: exp, metric: "loss")
        XCTAssertFalse(analysis.higherIsBetter)
        XCTAssertEqual(analysis.bestSetting, "good")
    }

    func testExperimentWithNoRunsGivesAnEmptyAnalysis() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let exp = try ModelTestSupport.insertExperiment(model)

        let loader = RunStatisticsLoader(model: model)
        XCTAssertTrue(try loader.metrics(experimentID: exp).isEmpty)

        let analysis = try loader.analysis(experimentID: exp, metric: "test_accuracy")
        XCTAssertTrue(analysis.settings.isEmpty)
        XCTAssertTrue(analysis.comparisons.isEmpty)
        XCTAssertNil(analysis.bestSetting)
    }
}
