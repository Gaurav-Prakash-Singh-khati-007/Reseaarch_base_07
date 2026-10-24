//
//  RunStatistics.swift
//  ResearchBase
//
//  Owner: Agent 26 · Features: F-42
//
//  Spread and significance for repeated runs of an experiment.
//  Runs with the same `setting` are repeats (different seeds). For one metric
//  this gives, per setting: count, mean, standard deviation, min-max (and more);
//  and for every pair of settings: the difference and Welch's two-sided t-test
//  ("Likely real" / "Unclear"). Same maths as the prototype's Statistics tab.
//
//  Reads the database only (runs and metrics). Writes nothing.
//  With 3 to 5 seeds, the test is a guide, not proof; `smallSample` says so.
//
//  PUBLIC API
//    struct SpreadSummary              count, mean, sd, sem, min, max, median, ci95HalfWidth
//    enum SignificanceVerdict          .likelyReal / .unclear / .notEnoughData / .noVariation
//    struct WelchResult                meanDifference, t, degreesOfFreedom, p,
//                                      confidenceInterval95, cohensD, verdict, smallSample
//    struct OneSampleResult            same idea against a single number (a published baseline)
//    struct SettingSamples             name + the metric value of each run
//    struct SettingComparison          baseline, candidate, result, label ("B vs A")
//    enum RunStatistics                pure maths, no database, safe on any thread
//      static func summarize(_:) -> SpreadSummary?
//      static func welch(_ b:versus:) -> WelchResult          (difference = mean(b) - mean(a))
//      static func oneSample(_:against:) -> OneSampleResult
//      static func compareAll(_:) -> [SettingComparison]      (every pair, in the order given)
//      static func bestSetting(_:higherIsBetter:) -> String?
//      static func formatP(_:), formatMeanSD(_:decimals:), formatRange(_:decimals:)
//      static let smallSampleNote
//    struct MetricInfo                 name, higherIsBetter, runCount
//    struct RunAnalysis                the whole Statistics tab for one metric
//    final class RunStatisticsLoader   main actor, reads through LibraryModel
//      init(model:)
//      func metrics(experimentID:) throws -> [MetricInfo]
//      func settings(experimentID:metric:) throws -> [SettingSamples]
//      func analysis(experimentID:metric:) throws -> RunAnalysis
//
//  Uses finished code: LibraryModel / LibraryDatabase (read-only SQL on runs and metrics).
//  Only completed runs count, and only final values (step IS NULL), not curves.
//

import Foundation

// MARK: - Results

nonisolated struct SpreadSummary: Equatable, Sendable {
    var count: Int
    var mean: Double
    /// Sample standard deviation (n - 1). 0 when there is a single run.
    var sd: Double
    /// Standard error of the mean. 0 when there is a single run.
    var sem: Double
    var min: Double
    var max: Double
    var median: Double
    /// Half-width of the 95% confidence interval of the mean. Nil when there are fewer than 2 runs.
    var ci95HalfWidth: Double?
}

nonisolated enum SignificanceVerdict: Equatable, Sendable {
    /// p below 0.05.
    case likelyReal
    case unclear
    /// A setting has fewer than 2 runs.
    case notEnoughData
    /// Every run of both settings gave the same value, so the test has nothing to measure.
    case noVariation

    var chipText: String {
        switch self {
        case .likelyReal: return "Likely real"
        case .unclear: return "Unclear"
        case .notEnoughData: return "Needs 2+ runs each"
        case .noVariation: return "No spread to test"
        }
    }
}

nonisolated struct WelchResult: Equatable, Sendable {
    /// mean(second) - mean(first). Nil when a setting has no runs.
    var meanDifference: Double?
    var t: Double?
    var degreesOfFreedom: Double?
    /// Two-sided. Nil when the test cannot be done.
    var p: Double?
    var confidenceInterval95: ClosedRange<Double>?
    /// Effect size: the difference in units of the pooled standard deviation.
    var cohensD: Double?
    var verdict: SignificanceVerdict
    /// Either setting has fewer than 5 runs: treat the answer as a guide.
    var smallSample: Bool
}

nonisolated struct OneSampleResult: Equatable, Sendable {
    /// mean(values) - reference.
    var meanDifference: Double?
    var t: Double?
    var degreesOfFreedom: Double?
    var p: Double?
    var confidenceInterval95: ClosedRange<Double>?
    var verdict: SignificanceVerdict
    var smallSample: Bool
}

nonisolated struct SettingSamples: Equatable, Sendable {
    var name: String
    var values: [Double]
}

nonisolated struct SettingComparison: Equatable, Sendable {
    /// The earlier setting; the difference is measured from it.
    var baseline: String
    var candidate: String
    var result: WelchResult

    /// "SCAFFOLD vs FedAvg"
    var label: String { "\(candidate) vs \(baseline)" }
}

// MARK: - Pure maths

nonisolated enum RunStatistics {

    static let significanceLevel = 0.05
    /// Fewer runs than this per setting counts as a small sample.
    static let smallSampleBelow = 5

    static let smallSampleNote = "Welch’s two-sided t-test. With 3 to 5 seeds, treat it as a guide, not proof."

    // MARK: Spread

    /// Non-finite values (NaN, infinity) are ignored. Nil when nothing is left.
    static func summarize(_ values: [Double]) -> SpreadSummary? {
        let data = values.filter(\.isFinite)
        guard !data.isEmpty else { return nil }

        let n = data.count
        let mean = data.reduce(0, +) / Double(n)
        let sd = n < 2 ? 0 : (data.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n - 1)).squareRoot()
        let sem = n < 2 ? 0 : sd / Double(n).squareRoot()

        let sorted = data.sorted()
        let median = n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2

        return SpreadSummary(
            count: n, mean: mean, sd: sd, sem: sem,
            min: sorted[0], max: sorted[n - 1], median: median,
            ci95HalfWidth: n < 2 ? nil : tQuantile(0.975, degreesOfFreedom: Double(n - 1)) * sem
        )
    }

    // MARK: Welch's t-test

    /// Compares two settings. The difference is mean(b) - mean(a), so "b vs a" reads naturally.
    static func welch(_ b: [Double], versus a: [Double]) -> WelchResult {

        guard let sb = summarize(b), let sa = summarize(a) else {
            return WelchResult(verdict: .notEnoughData, smallSample: true)
        }
        let difference = sb.mean - sa.mean
        let small = Swift.min(sa.count, sb.count) < smallSampleBelow

        guard sa.count >= 2, sb.count >= 2 else {
            return WelchResult(meanDifference: difference, verdict: .notEnoughData, smallSample: small)
        }

        let va = sa.sd * sa.sd / Double(sa.count)
        let vb = sb.sd * sb.sd / Double(sb.count)
        let combined = va + vb

        guard combined > 0 else {
            // Identical values everywhere: same means is "no difference at all"; different means cannot be tested.
            return WelchResult(
                meanDifference: difference,
                p: difference == 0 ? 1.0 : nil,
                verdict: .noVariation,
                smallSample: small
            )
        }

        let se = combined.squareRoot()
        let t = difference / se
        let df = combined * combined / (va * va / Double(sa.count - 1) + vb * vb / Double(sb.count - 1))
        let p = twoSidedP(t: t, degreesOfFreedom: df)
        let margin = tQuantile(0.975, degreesOfFreedom: df) * se

        let pooledVariance = (Double(sa.count - 1) * sa.sd * sa.sd + Double(sb.count - 1) * sb.sd * sb.sd)
            / Double(sa.count + sb.count - 2)
        let d: Double? = pooledVariance > 0 ? difference / pooledVariance.squareRoot() : nil

        return WelchResult(
            meanDifference: difference,
            t: t,
            degreesOfFreedom: df,
            p: p,
            confidenceInterval95: (difference - margin)...(difference + margin),
            cohensD: d,
            verdict: p < significanceLevel ? .likelyReal : .unclear,
            smallSample: small
        )
    }

    /// One setting against a single number, such as a published baseline.
    static func oneSample(_ values: [Double], against reference: Double) -> OneSampleResult {

        guard reference.isFinite, let s = summarize(values) else {
            return OneSampleResult(verdict: .notEnoughData, smallSample: true)
        }
        let difference = s.mean - reference
        let small = s.count < smallSampleBelow

        guard s.count >= 2 else {
            return OneSampleResult(meanDifference: difference, verdict: .notEnoughData, smallSample: small)
        }
        guard s.sem > 0 else {
            return OneSampleResult(
                meanDifference: difference, p: difference == 0 ? 1.0 : nil, verdict: .noVariation, smallSample: small
            )
        }

        let df = Double(s.count - 1)
        let t = difference / s.sem
        let p = twoSidedP(t: t, degreesOfFreedom: df)
        let margin = tQuantile(0.975, degreesOfFreedom: df) * s.sem

        return OneSampleResult(
            meanDifference: difference,
            t: t,
            degreesOfFreedom: df,
            p: p,
            confidenceInterval95: (difference - margin)...(difference + margin),
            verdict: p < significanceLevel ? .likelyReal : .unclear,
            smallSample: small
        )
    }

    // MARK: Many settings

    /// Every pair, in the order given: for settings [A, B, C] the rows are "B vs A", "C vs A", "C vs B".
    static func compareAll(_ settings: [SettingSamples]) -> [SettingComparison] {
        var rows: [SettingComparison] = []
        for (i, first) in settings.enumerated() {
            for second in settings.dropFirst(i + 1) {
                rows.append(SettingComparison(
                    baseline: first.name,
                    candidate: second.name,
                    result: welch(second.values, versus: first.values)
                ))
            }
        }
        return rows
    }

    /// The setting with the best mean. A tie goes to the earlier setting. Settings with no runs are skipped.
    static func bestSetting(_ settings: [SettingSamples], higherIsBetter: Bool = true) -> String? {
        var best: (name: String, mean: Double)?
        for setting in settings {
            guard let s = summarize(setting.values) else { continue }
            if let current = best {
                let better = higherIsBetter ? s.mean > current.mean : s.mean < current.mean
                if better { best = (setting.name, s.mean) }
            } else {
                best = (setting.name, s.mean)
            }
        }
        return best?.name
    }

    // MARK: Text

    /// "0.032", "< 0.001", or "n/a".
    static func formatP(_ p: Double?) -> String {
        guard let p, p.isFinite else { return "n/a" }
        return p < 0.001 ? "< 0.001" : String(format: "%.3f", p)
    }

    /// "86.4 ± 0.3", or "86.4 (1 run)" when there is no spread to show.
    static func formatMeanSD(_ summary: SpreadSummary, decimals: Int = 1) -> String {
        let mean = String(format: "%.\(decimals)f", summary.mean)
        if summary.count < 2 { return "\(mean) (1 run)" }
        return "\(mean) ± " + String(format: "%.\(decimals)f", summary.sd)
    }

    /// "85.9–86.9"
    static func formatRange(_ summary: SpreadSummary, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f–%.\(decimals)f", summary.min, summary.max)
    }

    // MARK: Student's t (shared with the tests)

    /// Two-sided p-value of a t statistic.
    static func twoSidedP(t: Double, degreesOfFreedom df: Double) -> Double {
        guard t.isFinite, df > 0 else { return 1 }
        let p = regularizedIncompleteBeta(df / (df + t * t), a: df / 2, b: 0.5)
        return Swift.min(1, Swift.max(0, p))
    }

    /// P(T <= t) for Student's t.
    static func tCDF(_ t: Double, degreesOfFreedom df: Double) -> Double {
        let tail = 0.5 * regularizedIncompleteBeta(df / (df + t * t), a: df / 2, b: 0.5)
        return t >= 0 ? 1 - tail : tail
    }

    /// The t value with `probability` of the distribution below it (probability in 0.5..<1).
    static func tQuantile(_ probability: Double, degreesOfFreedom df: Double) -> Double {
        guard probability > 0.5, probability < 1, df > 0 else { return 0 }

        var high = 1.0
        while tCDF(high, degreesOfFreedom: df) < probability, high < 1e9 { high *= 2 }
        var low = 0.0
        for _ in 0..<200 {
            let mid = (low + high) / 2
            if tCDF(mid, degreesOfFreedom: df) < probability { low = mid } else { high = mid }
            if high - low < 1e-12 * Swift.max(1, high) { break }
        }
        return (low + high) / 2
    }

    // MARK: Numerical recipes (ported from the prototype)

    /// ln Γ(x) for x > 0 (Lanczos).
    private static func logGamma(_ x: Double) -> Double {
        let coefficients: [Double] = [
            76.18009172947146, -86.50532032941677, 24.01409824083091,
            -1.231739572450155, 0.1208650973866179e-2, -0.5395239384953e-5
        ]
        var y = x
        var t = x + 5.5
        t -= (x + 0.5) * log(t)
        var series = 1.000000000190015
        for c in coefficients {
            y += 1
            series += c / y
        }
        return -t + log(2.5066282746310005 * series / x)
    }

    /// I_x(a, b): the regularized incomplete beta function.
    static func regularizedIncompleteBeta(_ x: Double, a: Double, b: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let front = exp(
            logGamma(a + b) - logGamma(a) - logGamma(b) + a * log(x) + b * log(1 - x)
        )
        if x < (a + 1) / (a + b + 2) {
            return front * betaContinuedFraction(a, b, x) / a
        }
        return 1 - front * betaContinuedFraction(b, a, 1 - x) / b
    }

    private static func betaContinuedFraction(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let tiny = 1e-30
        let qab = a + b, qap = a + 1, qam = a - 1
        var c = 1.0
        var d = 1 - qab * x / qap
        if abs(d) < tiny { d = tiny }
        d = 1 / d
        var h = d

        for m in 1...200 {
            let m = Double(m)
            let m2 = 2 * m

            var aa = m * (b - m) * x / ((qam + m2) * (a + m2))
            d = 1 + aa * d
            if abs(d) < tiny { d = tiny }
            c = 1 + aa / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            h *= d * c

            aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
            d = 1 + aa * d
            if abs(d) < tiny { d = tiny }
            c = 1 + aa / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            let delta = d * c
            h *= delta
            if abs(delta - 1) < 3e-12 { break }
        }
        return h
    }
}

// MARK: - The Statistics tab for one metric

nonisolated struct MetricInfo: Equatable, Sendable {
    var name: String
    var higherIsBetter: Bool
    /// Completed runs that recorded this metric.
    var runCount: Int
}

nonisolated struct RunAnalysis: Equatable, Sendable {
    var metric: String
    var higherIsBetter: Bool
    /// In the order the settings first appear (by run number).
    var settings: [SettingSamples]
    var summaries: [SpreadSummary?]          // same order as `settings`
    var comparisons: [SettingComparison]
    var bestSetting: String?

    func summary(for setting: String) -> SpreadSummary? {
        guard let i = settings.firstIndex(where: { $0.name == setting }) else { return nil }
        return summaries[i]
    }
}

// MARK: - Reading the library

final class RunStatisticsLoader {

    unowned let model: LibraryModel

    init(model: LibraryModel) {
        self.model = model
    }

    /// The metrics worth analysing for an experiment: final values of completed runs, most-recorded first.
    func metrics(experimentID: String) throws -> [MetricInfo] {
        let rows = try model.database.rows(
            """
            SELECT m.name AS name, MIN(m.higher_is_better) AS higher_is_better,
                   COUNT(DISTINCT m.run_id) AS run_count
            FROM metrics m JOIN runs r ON r.id = m.run_id
            WHERE r.experiment_id = ? AND r.status = 'completed' AND m.step IS NULL
            GROUP BY m.name
            ORDER BY run_count DESC, m.name
            """,
            [.text(experimentID)]
        )
        return rows.compactMap { row -> MetricInfo? in
            guard let name = row.text("name") else { return nil }
            return MetricInfo(
                name: name,
                higherIsBetter: (row.int("higher_is_better") ?? 1) != 0,
                runCount: Int(row.int("run_count") ?? 0)
            )
        }
    }

    /// One value per completed run, grouped by setting. When a run recorded the metric more than
    /// once, the last one wins. Settings are listed in the order of their first run.
    func settings(experimentID: String, metric: String) throws -> [SettingSamples] {
        let rows = try model.database.rows(
            """
            SELECT r.id AS run_id, r.setting AS setting, m.value AS value
            FROM runs r JOIN metrics m ON m.run_id = r.id
            WHERE r.experiment_id = ? AND r.status = 'completed' AND m.name = ? AND m.step IS NULL
            ORDER BY r.run_number, r.id, m.rowid
            """,
            [.text(experimentID), .text(metric)]
        )

        var runOrder: [String] = []
        var latest: [String: (setting: String, value: Double)] = [:]
        for row in rows {
            guard let runID = row.text("run_id"), let setting = row.text("setting"),
                  let value = rbA26_number(row["value"]) else { continue }
            if latest[runID] == nil { runOrder.append(runID) }
            latest[runID] = (setting, value)
        }

        var settingOrder: [String] = []
        var grouped: [String: [Double]] = [:]
        for runID in runOrder {
            guard let entry = latest[runID], entry.value.isFinite else { continue }
            if grouped[entry.setting] == nil { settingOrder.append(entry.setting) }
            grouped[entry.setting, default: []].append(entry.value)
        }
        return settingOrder.map { SettingSamples(name: $0, values: grouped[$0] ?? []) }
    }

    /// Everything the Statistics tab shows for one metric.
    func analysis(experimentID: String, metric: String) throws -> RunAnalysis {
        let info = try metrics(experimentID: experimentID).first { $0.name == metric }
        let higherIsBetter = info?.higherIsBetter ?? true
        let samples = try settings(experimentID: experimentID, metric: metric)

        return RunAnalysis(
            metric: metric,
            higherIsBetter: higherIsBetter,
            settings: samples,
            summaries: samples.map { RunStatistics.summarize($0.values) },
            comparisons: RunStatistics.compareAll(samples),
            bestSetting: RunStatistics.bestSetting(samples, higherIsBetter: higherIsBetter)
        )
    }
}

/// A number out of a database cell: REAL columns come back as doubles, whole numbers may come back as integers.
nonisolated private func rbA26_number(_ cell: SQLValue) -> Double? {
    switch cell {
    case .double(let value): return value
    case .int(let value): return Double(value)
    case .null, .text, .blob: return nil
    }
}
