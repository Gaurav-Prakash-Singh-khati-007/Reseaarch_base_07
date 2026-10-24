//
//  ExperimentFigureExporter.swift
//  ResearchBase
//
//  Owner: Agent 38 · Features: F-35 (figures and tables from experiments, for drafts)
//
//  Turns the runs of an experiment into things a paper can use, without retyping numbers:
//    * a LaTeX results table (mean ± standard deviation over seeds, best value in bold,
//      baselines underneath);
//    * a LaTeX figure block plus the figure file itself, a vector PDF (bar chart of the
//      settings, or learning curves when the metric has steps);
//    * a general `latexTable(columns:rows:...)` for other tables (for example the paper
//      comparison matrix).
//
//  Only completed runs are used. A run's value for a metric is its un-stepped value, or
//  else its value at the last step. Runs with the same `setting` are repeats of one setting.
//
//  Generated LaTeX is wrapped in marker comment lines
//      % ResearchBase:begin experiment-table id=... metric=... decimals=1 baselines=1
//      % ResearchBase:end experiment-table id=... metric=...
//  so inserting again REPLACES the block instead of adding a second copy, and
//  `refreshBlocks(in:)` can update every generated block of a draft after new runs.
//
//  This file never edits a draft file. It returns the new text; the caller writes it
//  through the draft store. `writeFigure` only writes the figure PDF into figures/.
//
//  PUBLIC API
//    ExperimentMetricInfo, SettingSummary, BaselineValue, ExperimentResults
//    ExperimentTexOptions, ExperimentTexBlock, ExperimentFigureStyle, ExperimentBlockMarker, ExperimentRefreshResult
//    ExperimentFigureExporter(model:)
//      availableMetrics(experimentID:)                       -> [ExperimentMetricInfo]
//      results(experimentID:metric:)                         -> ExperimentResults
//      resultsTable(experimentID:metric:options:)            -> ExperimentTexBlock
//      figure(experimentID:metric:style:options:)            -> (block: ExperimentTexBlock, pdf: Data)
//      writeFigure(_:in:)                                    -> URL   (figures/<name>.pdf in the draft folder)
//      refreshBlocks(in:draftFolder:)                        -> ExperimentRefreshResult
//      static insert(_:into:at:)                             -> (text: String, replaced: Bool)
//      static existingBlocks(in:)                            -> [ExperimentBlockMarker]
//      static latexTable(columns:rows:caption:label:alignment:placement:) -> String
//      static escapeLatex(_:)                                -> String
//

import Foundation

// MARK: - Public types

struct ExperimentMetricInfo: Equatable {
    var name: String
    var unit: String
    var higherIsBetter: Bool
    /// Completed runs that report this metric.
    var runCount: Int
    /// True when runs report it at several steps, so a learning curve can be drawn.
    var hasCurve: Bool
}

struct SettingSummary: Equatable {
    var name: String
    /// One value per completed run.
    var values: [Double]
    var mean: Double
    /// Sample standard deviation; nil with a single run.
    var standardDeviation: Double?
    /// Mean over runs at each step (empty when the metric has no steps).
    var curve: [CurvePoint]

    var count: Int { values.count }
}

struct CurvePoint: Equatable {
    var step: Double
    var value: Double
}

struct BaselineValue: Equatable {
    var name: String
    var value: Double
    var unit: String
}

struct ExperimentResults: Equatable {
    var experimentID: String
    var experimentName: String
    var metric: ExperimentMetricInfo
    var settings: [SettingSummary]
    var baselines: [BaselineValue]

    /// The setting with the best mean (respecting `higherIsBetter`).
    var bestSetting: String? {
        let best = metric.higherIsBetter ? settings.max { $0.mean < $1.mean } : settings.min { $0.mean < $1.mean }
        return best?.name
    }
}

struct ExperimentTexOptions: Equatable {
    var decimals: Int = 1
    var includeBaselines: Bool = true
    /// Replaces the generated caption.
    var caption: String?
    var placement: String = "t"
    /// Bar charts start at zero unless this is false.
    var startAtZero: Bool = true
}

enum ExperimentFigureStyle: String, Equatable {
    case bar, curve
}

struct ExperimentTexBlock: Equatable {
    enum Kind: String { case table = "experiment-table", figure = "experiment-figure" }

    var kind: Kind
    var experimentID: String
    var metric: String
    /// The LaTeX, including the begin/end marker lines. No trailing newline.
    var text: String
    /// `\usepackage` names the block needs.
    var requiredPackages: [String]
    /// For figures: where the PDF goes, relative to the draft folder (figures/<name>.pdf).
    var figureFile: String?
    /// For figures: "bar" or "curve". A bar chart and a curve of the same metric can both be in a draft.
    var style: String? = nil
}

struct ExperimentBlockMarker: Equatable {
    var kind: ExperimentTexBlock.Kind
    var experimentID: String
    var metric: String
    var parameters: [String: String]
    /// Zero-based line numbers of the begin and end marker lines.
    var beginLine: Int
    var endLine: Int
}

struct ExperimentRefreshResult: Equatable {
    var text: String
    var refreshed: Int
    /// Blocks that could not be refreshed (experiment deleted, metric gone) and were left as they were.
    var warnings: [String]
}

// MARK: - Exporter

final class ExperimentFigureExporter {

    unowned let model: LibraryModel
    private let now: () -> Date

    init(model: LibraryModel, now: @escaping () -> Date = { Date() }) {
        self.model = model
        self.now = now
    }

    private var db: LibraryDatabase { model.database }

    // MARK: Reading results

    /// Metrics reported by completed runs, the most widely reported first.
    func availableMetrics(experimentID: String) throws -> [ExperimentMetricInfo] {

        guard try experimentName(experimentID) != nil else {
            throw ModelError.notFound(kind: "experiment", id: experimentID)
        }

        return try db.rows(
            """
            SELECT m.name AS name, MAX(m.unit) AS unit, MIN(m.higher_is_better) AS better,
                   COUNT(DISTINCT m.run_id) AS runs, COUNT(DISTINCT m.step) AS steps
            FROM metrics m JOIN runs r ON r.id = m.run_id
            WHERE r.experiment_id = ? AND r.status = 'completed'
            GROUP BY m.name ORDER BY runs DESC, m.name
            """, [.text(experimentID)]
        ).map { row in
            ExperimentMetricInfo(
                name: row.text("name") ?? "",
                unit: row.text("unit") ?? "",
                higherIsBetter: (row.int("better") ?? 1) != 0,
                runCount: Int(row.int("runs") ?? 0),
                hasCurve: (row.int("steps") ?? 0) > 1)
        }
    }

    /// Per-setting numbers for one metric. `metric` nil = the most widely reported one.
    func results(experimentID: String, metric: String? = nil) throws -> ExperimentResults {

        guard let name = try experimentName(experimentID) else {
            throw ModelError.notFound(kind: "experiment", id: experimentID)
        }

        let metrics = try availableMetrics(experimentID: experimentID)
        let info: ExperimentMetricInfo
        if let wanted = metric {
            guard let found = metrics.first(where: { $0.name == wanted }) else {
                throw ModelError.invalidValue("this experiment has no completed runs with the metric “\(wanted)”")
            }
            info = found
        } else {
            guard let first = metrics.first else {
                throw ModelError.invalidValue("this experiment has no completed runs with results")
            }
            info = first
        }

        let runs = try db.rows(
            "SELECT id, setting FROM runs WHERE experiment_id = ? AND status = 'completed' ORDER BY run_number, id",
            [.text(experimentID)])

        let rows = try db.rows(
            """
            SELECT m.run_id AS run_id, m.value AS value, m.step AS step FROM metrics m
            JOIN runs r ON r.id = m.run_id
            WHERE r.experiment_id = ? AND r.status = 'completed' AND m.name = ?
            ORDER BY m.run_id, m.rowid
            """, [.text(experimentID), .text(info.name)])

        var byRun: [String: [(step: Double?, value: Double)]] = [:]
        for row in rows {
            guard let runID = row.text("run_id"), let value = Self.double(row["value"]) else { continue }
            byRun[runID, default: []].append((Self.double(row["step"]), value))
        }

        var order: [String] = []
        var finals: [String: [Double]] = [:]
        var curves: [String: [Double: [Double]]] = [:]

        for run in runs {
            guard let runID = run.text("id"), let entries = byRun[runID], !entries.isEmpty else { continue }
            let setting = run.text("setting") ?? "default"

            let plain = entries.last(where: { $0.step == nil })
            let stepped = entries.filter { $0.step != nil }
            guard let finalValue = plain?.value ?? stepped.max(by: { $0.step! < $1.step! })?.value else { continue }

            if finals[setting] == nil { order.append(setting) }
            finals[setting, default: []].append(finalValue)

            for entry in stepped {
                curves[setting, default: [:]][entry.step!, default: []].append(entry.value)
            }
        }

        let settings = order.map { setting -> SettingSummary in
            let values = finals[setting] ?? []
            let curve = (curves[setting] ?? [:]).keys.sorted().map { step -> CurvePoint in
                let at = curves[setting]![step]!
                return CurvePoint(step: step, value: Self.mean(at))
            }
            return SettingSummary(name: setting, values: values, mean: Self.mean(values),
                                  standardDeviation: Self.standardDeviation(values), curve: curve)
        }

        let baselines = try db.rows(
            "SELECT name, value, unit FROM baselines WHERE experiment_id = ? ORDER BY rowid", [.text(experimentID)]
        ).compactMap { row -> BaselineValue? in
            guard let name = row.text("name"), let value = Self.double(row["value"]) else { return nil }
            let unit = row.text("unit") ?? ""
            // Baselines have no metric column: keep the ones in the same unit as this metric.
            guard unit.isEmpty || info.unit.isEmpty || unit == info.unit else { return nil }
            return BaselineValue(name: name, value: value, unit: unit)
        }

        return ExperimentResults(experimentID: experimentID, experimentName: name, metric: info,
                                 settings: settings, baselines: baselines)
    }

    // MARK: LaTeX table

    func resultsTable(experimentID: String, metric: String? = nil,
                      options: ExperimentTexOptions = ExperimentTexOptions()) throws -> ExperimentTexBlock {

        let data = try results(experimentID: experimentID, metric: metric)
        let title = Self.metricTitle(data.metric)
        let best = data.bestSetting
        let repeated = data.settings.contains { $0.count > 1 }
        let d = min(max(options.decimals, 0), 6)

        var lines: [String] = []
        lines.append(Self.beginMarker(.table, data, options))
        lines.append("% Generated from experiment “\(Self.commentSafe(data.experimentName))” on \(Self.isoDate(now())). Re-insert or refresh to update; edits here are overwritten.")
        lines.append("% Needs \\usepackage{booktabs}")
        lines.append("\\begin{table}[\(options.placement)]")
        lines.append("  \\centering")
        let caption = options.caption ?? (Self.escapeLatex(title) + (repeated ? ", mean $\\pm$ standard deviation over seeds." : "."))
        lines.append("  \\caption{\(caption)}")
        lines.append("  \\label{tab:\(Self.slug(data.experimentName))-\(Self.slug(data.metric.name))}")
        lines.append("  \\begin{tabular}{lcc}")
        lines.append("    \\toprule")
        lines.append("    Setting & \(Self.escapeLatex(title)) & Runs \\\\")
        lines.append("    \\midrule")

        for setting in data.settings {
            var cell = Self.format(setting.mean, d)
            if setting.name == best, data.settings.count > 1 { cell = "\\textbf{\(cell)}" }
            if let sd = setting.standardDeviation { cell += " $\\pm$ " + Self.format(sd, d) }
            lines.append("    \(Self.escapeLatex(setting.name)) & \(cell) & \(setting.count) \\\\")
        }

        if options.includeBaselines, !data.baselines.isEmpty {
            lines.append("    \\midrule")
            for baseline in data.baselines {
                lines.append("    \(Self.escapeLatex(baseline.name)) (baseline) & \(Self.format(baseline.value, d)) & -- \\\\")
            }
        }

        lines.append("    \\bottomrule")
        lines.append("  \\end{tabular}")
        lines.append("\\end{table}")
        lines.append(Self.endMarker(.table, data))

        return ExperimentTexBlock(kind: .table, experimentID: experimentID, metric: data.metric.name,
                                  text: lines.joined(separator: "\n"), requiredPackages: ["booktabs"], figureFile: nil)
    }

    // MARK: Figure

    /// The `\begin{figure}` block and the PDF it points to. Write the PDF with `writeFigure`.
    func figure(experimentID: String, metric: String? = nil, style: ExperimentFigureStyle? = nil,
                options: ExperimentTexOptions = ExperimentTexOptions()) throws -> (block: ExperimentTexBlock, pdf: Data) {

        let data = try results(experimentID: experimentID, metric: metric)
        let chosen = style ?? (data.metric.hasCurve ? .curve : .bar)

        if chosen == .curve, !data.metric.hasCurve {
            throw ModelError.invalidValue("this metric has no steps, so a curve cannot be drawn")
        }

        let title = Self.metricTitle(data.metric)
        let file = "figures/\(Self.slug(data.experimentName))_\(Self.slug(data.metric.name))\(chosen == .curve ? "_curve" : "").pdf"

        let names = data.settings.map { Self.escapeLatex($0.name) }.joined(separator: ", ")
        let caption = options.caption ?? (chosen == .curve
            ? "\(Self.escapeLatex(title)) over training for \(names)."
            : "\(Self.escapeLatex(title)) for \(names).")

        var lines: [String] = []
        lines.append(Self.beginMarker(.figure, data, options, extra: "style=\(chosen.rawValue)"))
        lines.append("% Generated from experiment “\(Self.commentSafe(data.experimentName))” on \(Self.isoDate(now())). The plot is \(file), written together with this block.")
        lines.append("% Needs \\usepackage{graphicx}")
        lines.append("\\begin{figure}[\(options.placement)]")
        lines.append("  \\centering")
        lines.append("  \\includegraphics[width=0.8\\linewidth]{\(file)}")
        lines.append("  \\caption{\(caption)}")
        lines.append("  \\label{fig:\(Self.slug(data.experimentName))-\(Self.slug(data.metric.name))\(chosen == .curve ? "-curve" : "")}")
        lines.append("\\end{figure}")
        lines.append(Self.endMarker(.figure, data))

        let pdf = ExperimentChart.pdf(data, style: chosen, options: options)
        let block = ExperimentTexBlock(kind: .figure, experimentID: experimentID, metric: data.metric.name,
                                       text: lines.joined(separator: "\n"), requiredPackages: ["graphicx"], figureFile: file,
                                       style: chosen.rawValue)
        return (block, pdf)
    }

    /// Writes the figure PDF into the draft folder (figures/ is created when missing). Atomic.
    @discardableResult
    func writeFigure(_ pdf: Data, for block: ExperimentTexBlock, in draftFolder: URL) throws -> URL {

        guard let relative = block.figureFile, !relative.contains("..") else {
            throw ModelError.invalidValue("this block has no figure file")
        }
        let target = draftFolder.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pdf.write(to: target, options: .atomic)
        return target
    }

    // MARK: Putting blocks into LaTeX text

    /// Replaces the same block when it is already in `source`; otherwise inserts it at the
    /// character `offset` (the cursor), or before `\end{document}`, or at the end.
    static func insert(_ block: ExperimentTexBlock, into source: String, at offset: Int? = nil) -> (text: String, replaced: Bool) {

        let crlf = source.contains("\r\n")
        let blockLines = block.text.components(separatedBy: "\n").map { crlf ? $0 + "\r" : $0 }

        if let existing = existingBlocks(in: source).first(where: {
            $0.kind == block.kind && $0.experimentID == block.experimentID && $0.metric == block.metric
                && (block.kind == .table || $0.parameters["style"] == block.style)
        }) {
            var lines = source.components(separatedBy: "\n")
            lines.replaceSubrange(existing.beginLine...existing.endLine, with: blockLines)
            return (lines.joined(separator: "\n"), true)
        }

        let newline = crlf ? "\r\n" : "\n"
        let body = block.text.components(separatedBy: "\n").joined(separator: newline)

        var index: String.Index
        if let offset {
            index = source.index(source.startIndex, offsetBy: min(max(offset, 0), source.count))
        } else if let end = source.range(of: "\\end{document}", options: .backwards) {
            index = end.lowerBound
        } else {
            index = source.endIndex
        }

        var prefix = ""
        if index > source.startIndex, source[source.index(before: index)] != "\n" { prefix = newline }
        let suffix = newline + (index < source.endIndex && source[index] != "\n" && source[index] != "\r" ? newline : "")

        var text = source
        text.insert(contentsOf: prefix + body + suffix, at: index)
        return (text, false)
    }

    /// Generated blocks found in a draft file.
    static func existingBlocks(in source: String) -> [ExperimentBlockMarker] {

        let lines = source.components(separatedBy: "\n")
        var found: [ExperimentBlockMarker] = []

        for (number, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix(beginPrefix) else { continue }

            let words = line.dropFirst(beginPrefix.count).split(separator: " ").map(String.init)
            guard let kindName = words.first, let kind = ExperimentTexBlock.Kind(rawValue: kindName) else { continue }

            var parameters: [String: String] = [:]
            for word in words.dropFirst() {
                let pair = word.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 { parameters[pair[0]] = pair[1].removingPercentEncoding ?? pair[1] }
            }
            guard let id = parameters["id"], let metric = parameters["metric"] else { continue }

            let endPrefix = "% ResearchBase:end \(kind.rawValue) id=\(id) metric=\(encode(metric))"
            guard let endLine = lines.indices.first(where: { $0 > number && lines[$0].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(endPrefix) }) else { continue }

            found.append(ExperimentBlockMarker(kind: kind, experimentID: id, metric: metric,
                                               parameters: parameters, beginLine: number, endLine: endLine))
        }
        return found
    }

    /// Regenerates every generated block in `source` from the current runs. Figures are also
    /// re-written when `draftFolder` is given. A block that cannot be rebuilt stays as it is.
    func refreshBlocks(in source: String, draftFolder: URL? = nil) throws -> ExperimentRefreshResult {

        var text = source
        var refreshed = 0
        var warnings: [String] = []

        for marker in Self.existingBlocks(in: source) {

            var options = ExperimentTexOptions()
            if let value = marker.parameters["decimals"], let decimals = Int(value) { options.decimals = decimals }
            if let value = marker.parameters["baselines"] { options.includeBaselines = value != "0" }
            if let value = marker.parameters["zero"] { options.startAtZero = value != "0" }

            do {
                switch marker.kind {
                case .table:
                    let block = try resultsTable(experimentID: marker.experimentID, metric: marker.metric, options: options)
                    text = Self.insert(block, into: text).text

                case .figure:
                    let style = marker.parameters["style"].flatMap { ExperimentFigureStyle(rawValue: $0) }
                    let made = try figure(experimentID: marker.experimentID, metric: marker.metric, style: style, options: options)
                    text = Self.insert(made.block, into: text).text
                    if let draftFolder { try writeFigure(made.pdf, for: made.block, in: draftFolder) }
                }
                refreshed += 1
            } catch let error as ModelError {
                warnings.append("The \(marker.kind == .table ? "table" : "figure") for “\(marker.metric)” was left as it was: \(error.localizedDescription)")
            }
        }
        return ExperimentRefreshResult(text: text, refreshed: refreshed, warnings: warnings)
    }

    // MARK: General LaTeX table

    /// A booktabs table from any rows of text, for example the paper comparison matrix.
    /// Cells are escaped. `alignment` like "lcc" (default: first column left, others centered).
    static func latexTable(columns: [String], rows: [[String]], caption: String, label: String,
                           alignment: String? = nil, placement: String = "t") -> String {

        let width = max(columns.count, rows.map { $0.count }.max() ?? 0, 1)
        let spec = alignment ?? ("l" + String(repeating: "c", count: max(width - 1, 0)))

        func line(_ cells: [String]) -> String {
            var padded = cells.map { escapeLatex($0) }
            while padded.count < width { padded.append("") }
            return "    " + padded.joined(separator: " & ") + " \\\\"
        }

        var lines = [
            "\\begin{table}[\(placement)]",
            "  \\centering",
            "  \\caption{\(escapeLatex(caption))}",
            "  \\label{\(label)}",
            "  \\begin{tabular}{\(spec)}",
            "    \\toprule"
        ]
        if !columns.isEmpty {
            lines.append(line(columns))
            lines.append("    \\midrule")
        }
        for row in rows { lines.append(line(row)) }
        lines.append("    \\bottomrule")
        lines.append("  \\end{tabular}")
        lines.append("\\end{table}")
        return lines.joined(separator: "\n")
    }

    static func escapeLatex(_ text: String) -> String {
        var out = ""
        for ch in text {
            switch ch {
            case "\\": out += "\\textbackslash{}"
            case "&": out += "\\&"
            case "%": out += "\\%"
            case "$": out += "\\$"
            case "#": out += "\\#"
            case "_": out += "\\_"
            case "{": out += "\\{"
            case "}": out += "\\}"
            case "~": out += "\\textasciitilde{}"
            case "^": out += "\\textasciicircum{}"
            case "\n": out += " "
            default: out.append(ch)
            }
        }
        return out
    }

    // MARK: Private helpers

    private static let beginPrefix = "% ResearchBase:begin "

    private func experimentName(_ id: String) throws -> String? {
        try db.scalarText("SELECT name FROM experiments WHERE id = ? AND deleted_at IS NULL", [.text(id)])
    }

    private static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))) ?? text
    }

    private static func beginMarker(_ kind: ExperimentTexBlock.Kind, _ data: ExperimentResults,
                                    _ options: ExperimentTexOptions, extra: String? = nil) -> String {
        var line = "\(beginPrefix)\(kind.rawValue) id=\(data.experimentID) metric=\(encode(data.metric.name)) decimals=\(options.decimals) baselines=\(options.includeBaselines ? 1 : 0)"
        if kind == .figure { line += " zero=\(options.startAtZero ? 1 : 0)" }
        if let extra { line += " " + extra }
        return line
    }

    private static func endMarker(_ kind: ExperimentTexBlock.Kind, _ data: ExperimentResults) -> String {
        "% ResearchBase:end \(kind.rawValue) id=\(data.experimentID) metric=\(encode(data.metric.name))"
    }

    private static func commentSafe(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
    }

    private static func isoDate(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC") ?? .current, from: date)
        return String(format: "%04ld-%02ld-%02ld", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// "test_accuracy" with unit "%" -> "Test accuracy (%)"
    static func metricTitle(_ metric: ExperimentMetricInfo) -> String {
        var name = metric.name.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        if let first = name.first { name = first.uppercased() + name.dropFirst() }
        return metric.unit.isEmpty ? name : "\(name) (\(metric.unit))"
    }

    static func slug(_ text: String) -> String {
        var out = ""
        var lastDash = true
        for scalar in text.lowercased().unicodeScalars {
            if (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57) {
                out.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "experiment" : out
    }

    static func format(_ value: Double, _ decimals: Int) -> String {
        let text = String(format: "%.\(decimals)f", value)
        // no "-0.0"
        if text.hasPrefix("-"), Double(text) == 0 { return String(text.dropFirst()) }
        return text
    }

    static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    static func standardDeviation(_ values: [Double]) -> Double? {
        guard values.count > 1 else { return nil }
        let m = mean(values)
        let variance = values.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(values.count - 1)
        return variance.squareRoot()
    }

    private static func double(_ value: SQLValue) -> Double? {
        switch value {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }
}

// MARK: - Chart (vector PDF, written by hand)

fileprivate func pdfNumber(_ v: Double) -> String {
    var s = String(format: "%.2f", v)
    while s.contains("."), s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s == "-0" ? "0" : s
}

fileprivate enum ExperimentChart {

    private static let palette: [(Double, Double, Double)] = [
        (0.20, 0.41, 0.68), (0.88, 0.46, 0.12), (0.18, 0.60, 0.40), (0.62, 0.32, 0.62),
        (0.80, 0.24, 0.24), (0.42, 0.42, 0.42), (0.72, 0.62, 0.10), (0.25, 0.64, 0.74)
    ]

    // Helvetica widths (1/1000 em) for ASCII 32...126.
    private static let widths: [Int] = [
        278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278,
        556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556,
        1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,
        667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556,
        333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,
        556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584
    ]

    static func textWidth(_ text: String, size: Double, bold: Bool = false) -> Double {
        var total = 0
        for scalar in text.unicodeScalars {
            let v = Int(scalar.value)
            total += (v >= 32 && v <= 126) ? widths[v - 32] : 556
        }
        return Double(total) / 1000 * size * (bold ? 1.05 : 1)
    }

    static func fit(_ text: String, size: Double, width: Double) -> String {
        if textWidth(text, size: size) <= width { return text }
        var cut = text
        while cut.count > 1, textWidth(cut + "..", size: size) > width { cut.removeLast() }
        return cut + ".."
    }

    // MARK: Tick marks

    static func niceNumber(_ x: Double, round: Bool) -> Double {
        guard x > 0 else { return 1 }
        let exponent = floor(log10(x))
        let fraction = x / pow(10, exponent)
        let nice: Double
        if round {
            nice = fraction < 1.5 ? 1 : (fraction < 3 ? 2 : (fraction < 7 ? 5 : 10))
        } else {
            nice = fraction <= 1 ? 1 : (fraction <= 2 ? 2 : (fraction <= 5 ? 5 : 10))
        }
        return nice * pow(10, exponent)
    }

    static func niceTicks(_ low: Double, _ high: Double, count: Int = 5) -> (lo: Double, hi: Double, step: Double) {
        var lo = low, hi = high
        if hi - lo < 1e-12 { lo -= 0.5; hi += 0.5 }
        let range = niceNumber(hi - lo, round: false)
        let step = niceNumber(range / Double(max(count - 1, 1)), round: true)
        return (floor(lo / step) * step, ceil(hi / step) * step, step)
    }

    // MARK: Drawing

    private struct Canvas {
        var ops: [String] = []

        mutating func color(fill: (Double, Double, Double)) { ops.append("\(pdfNumber(fill.0)) \(pdfNumber(fill.1)) \(pdfNumber(fill.2)) rg") }
        mutating func color(stroke: (Double, Double, Double)) { ops.append("\(pdfNumber(stroke.0)) \(pdfNumber(stroke.1)) \(pdfNumber(stroke.2)) RG") }
        mutating func width(_ w: Double) { ops.append("\(pdfNumber(w)) w") }
        mutating func dash(_ on: Double, _ off: Double) { ops.append("[\(pdfNumber(on)) \(pdfNumber(off))] 0 d") }
        mutating func solid() { ops.append("[] 0 d") }

        mutating func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
            ops.append("\(pdfNumber(x)) \(pdfNumber(y)) \(pdfNumber(w)) \(pdfNumber(h)) re f")
        }

        mutating func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
            ops.append("\(pdfNumber(x1)) \(pdfNumber(y1)) m \(pdfNumber(x2)) \(pdfNumber(y2)) l S")
        }

        mutating func polyline(_ points: [(Double, Double)]) {
            guard let first = points.first else { return }
            var s = "\(pdfNumber(first.0)) \(pdfNumber(first.1)) m"
            for p in points.dropFirst() { s += " \(pdfNumber(p.0)) \(pdfNumber(p.1)) l" }
            ops.append(s + " S")
        }

        mutating func text(_ string: String, _ x: Double, _ y: Double, size: Double, bold: Bool = false,
                           align: Alignment = .left, rotated: Bool = false) {
            var px = x
            let w = ExperimentChart.textWidth(string, size: size, bold: bold)
            if align == .center { px -= w / 2 } else if align == .right { px -= w }
            let font = bold ? "F2" : "F1"
            let matrix = rotated ? "0 1 -1 0 \(pdfNumber(x)) \(pdfNumber(align == .center ? y - w / 2 : y)) Tm" : "1 0 0 1 \(pdfNumber(px)) \(pdfNumber(y)) Tm"
            ops.append("BT /\(font) \(pdfNumber(size)) Tf \(matrix) (\(ExperimentChart.escape(string))) Tj ET")
        }

        enum Alignment { case left, center, right }
    }

    /// PDF string body (without parentheses): ASCII with octal escapes for WinAnsi characters.
    static func escape(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x28: out += "\\("
            case 0x29: out += "\\)"
            case 0x5C: out += "\\\\"
            case 0x20...0x7E: out.unicodeScalars.append(scalar)
            case 0x2013: out += "\\226"
            case 0x2014: out += "\\227"
            case 0x2018: out += "\\221"
            case 0x2019: out += "\\222"
            case 0x201C: out += "\\223"
            case 0x201D: out += "\\224"
            case 0x2022: out += "\\225"
            case 0x2026: out += "\\205"
            case 0x2212: out += "-"
            case 0xA0...0xFF: out += "\\" + String(scalar.value, radix: 8)
            default: out += "?"
            }
        }
        return out
    }

    static func pdf(_ data: ExperimentResults, style: ExperimentFigureStyle, options: ExperimentTexOptions) -> Data {
        switch style {
        case .bar: return document(width: 460, height: 290, content: bars(data, options))
        case .curve: return document(width: 460, height: 290, content: curves(data, options))
        }
    }

    // MARK: Axes shared by both charts

    private static let left = 58.0, right = 16.0, top = 22.0, bottom = 56.0

    private static func axes(_ canvas: inout Canvas, width: Double, height: Double, lo: Double, hi: Double,
                             step: Double, decimals: Int, title: String) {
        let plotH = height - top - bottom
        canvas.color(stroke: (0.86, 0.86, 0.86))
        canvas.width(0.5)
        var tick = lo
        while tick <= hi + step * 0.001 {
            let y = bottom + (tick - lo) / (hi - lo) * plotH
            canvas.line(left, y, width - right, y)
            canvas.color(fill: (0.25, 0.25, 0.25))
            canvas.text(ExperimentFigureExporter.format(tick, decimals), left - 5, y - 3, size: 8, align: .right)
            canvas.color(stroke: (0.86, 0.86, 0.86))
            tick += step
        }
        canvas.color(stroke: (0.2, 0.2, 0.2))
        canvas.width(0.8)
        canvas.line(left, bottom, left, height - top)
        canvas.line(left, bottom, width - right, bottom)

        canvas.color(fill: (0.15, 0.15, 0.15))
        canvas.text(fit(title, size: 9, width: plotH), 13, bottom + plotH / 2, size: 9, align: .center, rotated: true)
    }

    private static func tickDecimals(_ step: Double) -> Int {
        step >= 1 ? 0 : min(max(Int(ceil(-log10(step))), 1), 4)
    }

    private static func valueRange(_ data: ExperimentResults, zero: Bool, includeSpread: Bool) -> (Double, Double) {
        var values: [Double] = []
        for s in data.settings {
            if includeSpread { values.append(s.mean - (s.standardDeviation ?? 0)); values.append(s.mean + (s.standardDeviation ?? 0)) } else { values.append(s.mean) }
            values.append(contentsOf: s.curve.map { $0.value })
        }
        values.append(contentsOf: data.baselines.map { $0.value })
        var lo = values.min() ?? 0
        var hi = values.max() ?? 1
        if zero, lo > 0 { lo = 0 }
        if zero, hi < 0 { hi = 0 }
        let pad = (hi - lo) * 0.06
        hi += pad
        if !zero || lo < 0 { lo -= pad }
        return (lo, hi)
    }

    // MARK: Bar chart

    private static func bars(_ data: ExperimentResults, _ options: ExperimentTexOptions) -> String {

        let width = 460.0, height = 290.0
        var canvas = Canvas()

        let range = valueRange(data, zero: options.startAtZero, includeSpread: true)
        let ticks = niceTicks(range.0, range.1)
        let plotW = width - left - right
        let plotH = height - top - bottom
        let decimals = min(max(options.decimals, 0), 4)

        func yFor(_ v: Double) -> Double { bottom + (v - ticks.lo) / (ticks.hi - ticks.lo) * plotH }

        axes(&canvas, width: width, height: height, lo: ticks.lo, hi: ticks.hi, step: ticks.step,
             decimals: max(tickDecimals(ticks.step), 0), title: ExperimentFigureExporter.metricTitle(data.metric))

        let count = max(data.settings.count, 1)
        let slot = plotW / Double(count)
        let barWidth = min(slot * 0.6, 70)
        let baseY = yFor(max(min(0, ticks.hi), ticks.lo))

        for (index, setting) in data.settings.enumerated() {
            let centre = left + slot * (Double(index) + 0.5)
            let colour = palette[index % palette.count]
            let y = yFor(setting.mean)

            canvas.color(fill: colour)
            canvas.rect(centre - barWidth / 2, min(y, baseY), barWidth, abs(y - baseY))

            var labelY = y
            if let sd = setting.standardDeviation, sd > 0 {
                let top = yFor(setting.mean + sd), low = yFor(setting.mean - sd)
                canvas.color(stroke: (0.1, 0.1, 0.1))
                canvas.width(1)
                canvas.line(centre, low, centre, top)
                canvas.line(centre - 4, top, centre + 4, top)
                canvas.line(centre - 4, low, centre + 4, low)
                labelY = max(top, y)
            }

            canvas.color(fill: (0.1, 0.1, 0.1))
            canvas.text(ExperimentFigureExporter.format(setting.mean, decimals), centre, labelY + 4, size: 8,
                        bold: setting.name == data.bestSetting && data.settings.count > 1, align: .center)
            canvas.color(fill: (0.2, 0.2, 0.2))
            canvas.text(fit(setting.name, size: 8, width: slot - 4), centre, bottom - 14, size: 8, align: .center)
            if setting.count > 1 {
                canvas.color(fill: (0.45, 0.45, 0.45))
                canvas.text("n = \(setting.count)", centre, bottom - 25, size: 7, align: .center)
            }
        }

        baselineLines(&canvas, data, yFor: yFor, width: width, decimals: decimals, lo: ticks.lo, hi: ticks.hi)
        return canvas.ops.joined(separator: "\n")
    }

    private static func baselineLines(_ canvas: inout Canvas, _ data: ExperimentResults, yFor: (Double) -> Double,
                                      width: Double, decimals: Int, lo: Double, hi: Double) {
        for baseline in data.baselines where baseline.value >= lo && baseline.value <= hi {
            let y = yFor(baseline.value)
            canvas.color(stroke: (0.55, 0.1, 0.1))
            canvas.width(1)
            canvas.dash(4, 3)
            canvas.line(left, y, width - right, y)
            canvas.solid()
            canvas.color(fill: (0.55, 0.1, 0.1))
            canvas.text(fit("\(baseline.name) \(ExperimentFigureExporter.format(baseline.value, decimals))", size: 7, width: 200),
                        width - right - 2, y + 3, size: 7, align: .right)
        }
    }

    // MARK: Learning curves

    private static func curves(_ data: ExperimentResults, _ options: ExperimentTexOptions) -> String {

        let width = 460.0, height = 290.0
        var canvas = Canvas()

        let steps = data.settings.flatMap { $0.curve.map { $0.step } }
        let minStep = steps.min() ?? 0
        let maxStep = steps.max() ?? 1
        let xTicks = niceTicks(minStep, maxStep)

        let range = valueRange(data, zero: false, includeSpread: false)
        let yTicks = niceTicks(range.0, range.1)
        let plotW = width - left - right
        let plotH = height - top - bottom

        func xFor(_ s: Double) -> Double { left + (s - xTicks.lo) / (xTicks.hi - xTicks.lo) * plotW }
        func yFor(_ v: Double) -> Double { bottom + (v - yTicks.lo) / (yTicks.hi - yTicks.lo) * plotH }

        axes(&canvas, width: width, height: height, lo: yTicks.lo, hi: yTicks.hi, step: yTicks.step,
             decimals: tickDecimals(yTicks.step), title: ExperimentFigureExporter.metricTitle(data.metric))

        var tick = xTicks.lo
        canvas.color(fill: (0.25, 0.25, 0.25))
        while tick <= xTicks.hi + xTicks.step * 0.001 {
            canvas.text(ExperimentFigureExporter.format(tick, tickDecimals(xTicks.step)), xFor(tick), bottom - 12, size: 8, align: .center)
            tick += xTicks.step
        }
        canvas.text("Step", left + plotW / 2, 10, size: 9, align: .center)

        for (index, setting) in data.settings.enumerated() where !setting.curve.isEmpty {
            let colour = palette[index % palette.count]
            canvas.color(stroke: colour)
            canvas.width(1.5)
            canvas.polyline(setting.curve.map { (xFor($0.step), yFor($0.value)) })
        }

        // Legend, top right inside the plot
        for (index, setting) in data.settings.enumerated() {
            let y = height - top - 12 - Double(index) * 12
            let x = width - right - 130
            let colour = palette[index % palette.count]
            canvas.color(stroke: colour)
            canvas.width(2)
            canvas.line(x, y + 3, x + 16, y + 3)
            canvas.color(fill: (0.15, 0.15, 0.15))
            canvas.text(fit(setting.name, size: 8, width: 108), x + 21, y, size: 8)
        }

        baselineLines(&canvas, data, yFor: yFor, width: width, decimals: min(max(options.decimals, 0), 4), lo: yTicks.lo, hi: yTicks.hi)
        return canvas.ops.joined(separator: "\n")
    }

    // MARK: PDF file

    private static func document(width: Int, height: Int, content: String) -> Data {

        let stream = Array(content.utf8)

        var out = [UInt8]()
        var offsets: [Int] = []

        func append(_ text: String) { out.append(contentsOf: Array(text.utf8)) }
        func object(_ number: Int, _ body: String) {
            offsets.append(out.count)
            append("\(number) 0 obj\n\(body)\nendobj\n")
        }

        append("%PDF-1.4\n")
        out.append(contentsOf: [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A])

        object(1, "<< /Type /Catalog /Pages 2 0 R >>")
        object(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        object(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(width) \(height)] /Contents 4 0 R /Resources << /Font << /F1 5 0 R /F2 6 0 R >> >> >>")

        offsets.append(out.count)
        append("4 0 obj\n<< /Length \(stream.count) >>\nstream\n")
        out.append(contentsOf: stream)
        append("\nendstream\nendobj\n")

        object(5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
        object(6, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>")

        let xref = out.count
        append("xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n")
        for offset in offsets { append(String(format: "%010ld 00000 n \n", offset)) }
        append("trailer\n<< /Size \(offsets.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n")

        return Data(out)
    }
}
