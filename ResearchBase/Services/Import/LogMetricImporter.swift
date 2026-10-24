//
//  LogMetricImporter.swift
//  ResearchBase
//
//  Owner: Agent 27 · Features: F-43
//
//  Turns a training log (CSV or JSON, such as an MLflow or Weights & Biases
//  export) into runs and metrics for an experiment.
//
//  The flow matches the "Import logs" tab:
//    1. parse            read the file, detect the format ("Detected: MLflow CSV export")
//    2. suggestMapping   one row per column: "Column in file" -> "Becomes"
//                        (Setting, Seed, Round, Metric, ... or Ignore); the person can change it
//    3. makePlan         apply the mapping: how many runs and metrics WOULD be imported
//    4. commit           write them, in one transaction. Nothing is saved before this step.
//  The source file name is kept on every run (runs.source_file).
//
//  Steps 1-3 are pure (no database). Only `commit` writes, and only rows of the
//  existing `runs` and `metrics` tables. The schema is not touched.
//
//  How rows become runs:
//    - a run-id column, when mapped, groups rows into runs
//    - otherwise, with a step column, rows with the same setting and seed are one run's curve
//    - otherwise each row is one run
//  A run with one row stores final values (metrics.step = NULL). A run with several rows
//  stores every point (step set) AND a final value (step NULL, the last point), because the
//  Statistics tab (RunStatistics) compares final values only.
//
//  PUBLIC API
//    enum LogFormat                      .mlflowCSV / .mlflowJSON / .wandbRunsCSV / .wandbHistoryCSV /
//                                        .wandbHistoryJSON / .genericCSV / .genericJSON; displayName
//    enum LogCell                        .number / .text / .empty
//    struct LogTable                     headers, rows
//    struct ParsedLog                    fileName, format, table; rowCount, columnCount
//    enum ColumnRole                     .setting .runID .seed .step .status .codeCommit .parameter .metric .ignore
//    struct ColumnMapping                index, header, role, metricName, higherIsBetter, unit, example
//    struct ImportOptions                stripSeedSuffix, includeCurves
//    struct ImportedMetric / ImportedRun the planned rows
//    struct LogImportPlan                runs, runCount, metricRowCount, warnings, skippedRows, summaryLine
//    struct LogImportResult              runsAdded, metricsAdded, runIDs, summaryLine
//    enum LogImportError                 unreadable / empty / nothingToImport (LocalizedError)
//    enum LogMetricParser                pure steps
//      static func parse(data:fileName:) throws -> ParsedLog
//      static func parse(text:fileName:) throws -> ParsedLog
//      static func suggestMapping(for:) -> [ColumnMapping]
//      static func makePlan(from:mapping:options:) -> LogImportPlan
//      static func parseCSV(_:) -> [[String]]
//    final class LogMetricImporter       main actor, reads and writes through LibraryModel
//      init(model:)
//      func parse(fileAt:) throws -> ParsedLog
//      func alreadyImportedRunCount(sourceFile:experimentID:) throws -> Int
//      func commit(_ plan:toExperiment:) throws -> LogImportResult
//
//  Uses finished code: LibraryModel / LibraryDatabase (runs, metrics, experiments tables),
//  ModelError.notFound, Library.nowISO.
//

import Foundation

// MARK: - Vocabulary

nonisolated enum LogFormat: String, Equatable, Sendable {
    case mlflowCSV
    case mlflowJSON
    case wandbRunsCSV
    case wandbHistoryCSV
    case wandbHistoryJSON
    case genericCSV
    case genericJSON

    var displayName: String {
        switch self {
        case .mlflowCSV: return "MLflow CSV export"
        case .mlflowJSON: return "MLflow JSON export"
        case .wandbRunsCSV: return "Weights & Biases runs export (CSV)"
        case .wandbHistoryCSV: return "Weights & Biases history export (CSV)"
        case .wandbHistoryJSON: return "Weights & Biases history export (JSON)"
        case .genericCSV: return "CSV log"
        case .genericJSON: return "JSON log"
        }
    }

    /// False for the generic formats: the person should check the column mapping.
    var isRecognised: Bool {
        switch self {
        case .genericCSV, .genericJSON: return false
        default: return true
        }
    }
}

nonisolated enum LogCell: Equatable, Sendable {
    case number(Double)
    case text(String)
    case empty

    var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// Text as it would appear in a table cell. Empty for `.empty`.
    var text: String {
        switch self {
        case .number(let value):
            return value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        case .text(let value): return value
        case .empty: return ""
        }
    }

    var isEmpty: Bool {
        if case .empty = self { return true }
        return false
    }
}

nonisolated struct LogTable: Equatable, Sendable {
    var headers: [String]
    /// Every row has exactly `headers.count` cells.
    var rows: [[LogCell]]
}

nonisolated struct ParsedLog: Equatable, Sendable {
    var fileName: String
    var format: LogFormat
    var table: LogTable

    var rowCount: Int { table.rows.count }
    var columnCount: Int { table.headers.count }
}

nonisolated enum ColumnRole: Equatable, Sendable {
    case setting        // "FedProx": runs with the same setting are repeats
    case runID          // groups rows into runs
    case seed
    case step           // round / epoch / step
    case status
    case codeCommit
    case parameter      // goes into the run's config
    case metric
    case ignore

    /// What the "Becomes" menu shows.
    var displayName: String {
        switch self {
        case .setting: return "Setting"
        case .runID: return "Run ID"
        case .seed: return "Seed"
        case .step: return "Round or step"
        case .status: return "Status"
        case .codeCommit: return "Code commit"
        case .parameter: return "Parameter"
        case .metric: return "Metric"
        case .ignore: return "Ignore"
        }
    }
}

nonisolated struct ColumnMapping: Equatable, Sendable {
    var index: Int
    var header: String
    var role: ColumnRole
    /// Used when `role == .metric`.
    var metricName: String
    var higherIsBetter: Bool
    var unit: String
    /// First non-empty value in the column.
    var example: String
}

nonisolated struct ImportOptions: Equatable, Sendable {
    /// "fedprox-seed22" and "fedprox-seed33" become one setting, "fedprox".
    var stripSeedSuffix = true
    /// Keep every point of a curve. False keeps final values only.
    var includeCurves = true

    init(stripSeedSuffix: Bool = true, includeCurves: Bool = true) {
        self.stripSeedSuffix = stripSeedSuffix
        self.includeCurves = includeCurves
    }
}

nonisolated struct ImportedMetric: Equatable, Sendable {
    var name: String
    var value: Double
    /// Nil for the final value.
    var step: Int?
    var higherIsBetter: Bool
    var unit: String
}

nonisolated struct ImportedRun: Equatable, Sendable {
    var setting: String
    var seed: Int?
    /// "planned", "running", "completed" or "failed" (the values the runs table allows).
    var status: String
    var codeCommit: String
    /// Parameters and other columns kept with the run, as text.
    var config: [String: String]
    var metrics: [ImportedMetric]
}

nonisolated struct LogImportPlan: Equatable, Sendable {
    var sourceFileName: String
    var format: LogFormat
    var rowCount: Int
    var columnCount: Int
    var runs: [ImportedRun]
    /// Rows with no usable metric value.
    var skippedRows: Int
    var warnings: [String]

    var runCount: Int { runs.count }
    var metricRowCount: Int { runs.reduce(0) { $0 + $1.metrics.count } }

    /// "Import 15 runs"
    var summaryLine: String {
        runCount == 1 ? "Import 1 run" : "Import \(runCount) runs"
    }
}

nonisolated struct LogImportResult: Equatable, Sendable {
    var runsAdded: Int
    var metricsAdded: Int
    var runIDs: [String]

    /// "Imported 15 runs and 30 metrics"
    var summaryLine: String {
        "Imported \(runsAdded) \(runsAdded == 1 ? "run" : "runs") and \(metricsAdded) \(metricsAdded == 1 ? "metric" : "metrics")"
    }
}

nonisolated enum LogImportError: LocalizedError, Equatable, Sendable {
    case unreadable(String)
    case empty
    case nothingToImport

    var errorDescription: String? {
        switch self {
        case .unreadable(let why): return "This file could not be read as a log. \(why)"
        case .empty: return "The file has no rows."
        case .nothingToImport: return "Nothing to import. Map at least one column as a metric."
        }
    }
}

// MARK: - Pure steps

nonisolated enum LogMetricParser {

    // MARK: 1. Parse

    static func parse(data: Data, fileName: String) throws -> ParsedLog {
        guard !data.isEmpty else { throw LogImportError.empty }
        return try parse(text: decode(data), fileName: fileName)
    }

    static func parse(text: String, fileName: String) throws -> ParsedLog {
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LogImportError.empty }

        let isJSON = trimmed.first == "{" || trimmed.first == "["
        let table: LogTable
        let format: LogFormat

        if isJSON {
            let result = try tableFromJSON(trimmed)
            table = result.table
            format = result.format
        } else {
            let result = try tableFromCSV(body)
            table = result
            format = detectCSVFormat(headers: result.headers)
        }

        guard !table.headers.isEmpty, !table.rows.isEmpty else { throw LogImportError.empty }
        return ParsedLog(fileName: fileName, format: format, table: table)
    }

    private static func decode(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            if let text = String(data: data, encoding: .utf16) { return text }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: CSV

    /// Reads RFC 4180 CSV: quoted fields, doubled quotes, line breaks inside quotes.
    /// The delimiter (comma, semicolon or tab) is guessed from the first line.
    static func parseCSV(_ text: String) -> [[String]] {
        let delimiter = guessDelimiter(text)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = Array(text)
        var i = 0

        func endField() { row.append(field); field = "" }
        func endRow() {
            endField()
            if !(row.count == 1 && row[0].trimmingCharacters(in: .whitespaces).isEmpty) { rows.append(row) }
            row = []
        }

        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" && field.isEmpty {
                inQuotes = true
            } else if c == delimiter {
                endField()
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                endRow()
            } else {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    private static func guessDelimiter(_ text: String) -> Character {
        var counts: [Character: Int] = [",": 0, ";": 0, "\t": 0]
        var inQuotes = false
        for c in text {
            if c == "\"" { inQuotes.toggle() }
            if !inQuotes {
                if c == "\n" || c == "\r\n" || c == "\r" { break }
                if counts[c] != nil { counts[c]! += 1 }
            }
        }
        let best = counts.max { $0.value < $1.value }
        return (best?.value ?? 0) > 0 ? best!.key : ","
    }

    private static func tableFromCSV(_ text: String) throws -> LogTable {
        let raw = parseCSV(text)
        guard let headerRow = raw.first, raw.count >= 2 else { throw LogImportError.empty }

        let decimalComma = guessDelimiter(text) == ";"
        var headers: [String] = []
        var seen: [String: Int] = [:]
        for (i, h) in headerRow.enumerated() {
            var name = h.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { name = "column \(i + 1)" }
            if let n = seen[name] { seen[name] = n + 1; name += " (\(n + 1))" } else { seen[name] = 1 }
            headers.append(name)
        }

        let rows: [[LogCell]] = raw.dropFirst().map { fields in
            (0..<headers.count).map { i in
                i < fields.count ? cell(fields[i], decimalComma: decimalComma) : .empty
            }
        }
        return LogTable(headers: headers, rows: rows)
    }

    /// Text -> number when it is one. "nan", "inf", "null", "None", "N/A" and blanks are empty.
    static func cell(_ raw: String, decimalComma: Bool = false) -> LogCell {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return .empty }
        switch s.lowercased() {
        case "nan", "null", "none", "na", "n/a", "inf", "-inf", "+inf", "infinity", "-infinity", "-": return .empty
        default: break
        }

        var candidate = s
        if candidate.hasSuffix("%") { candidate.removeLast() }
        if decimalComma, candidate.contains(",") { candidate = candidate.replacingOccurrences(of: ",", with: ".") }
        if let value = Double(candidate), value.isFinite { return .number(value) }
        return .text(s)
    }

    private static func detectCSVFormat(headers: [String]) -> LogFormat {
        let lower = headers.map { $0.lowercased() }
        let set = Set(lower)

        let mlflowMarkers: Set<String> = [
            "run name", "source type", "source name", "user", "start time", "duration", "status",
            "experiment_id", "artifact_uri", "tags.mlflow.runname", "end_time", "start_time"
        ]
        let hasRunID = set.contains("run id") || set.contains("run_id")
        let hasPrefixed = lower.contains { $0.hasPrefix("metrics.") || $0.hasPrefix("params.") }
        if hasRunID && (set.intersection(mlflowMarkers).count >= 2 || hasPrefixed) { return .mlflowCSV }

        let wandbRunMarkers: Set<String> = ["state", "runtime", "created", "sweep", "tags", "notes", "user"]
        if set.contains("name") && set.contains("state") && set.intersection(wandbRunMarkers).count >= 2 {
            return .wandbRunsCSV
        }

        let hasStep = set.contains("step") || set.contains("_step")
        let wandbHistoryMarkers = lower.contains { $0.hasSuffix("__min") || $0.hasSuffix("__max") }
            || set.contains("_runtime") || set.contains("_timestamp")
        if hasStep && wandbHistoryMarkers { return .wandbHistoryCSV }

        return .genericCSV
    }

    // MARK: JSON

    private static func tableFromJSON(_ text: String) throws -> (table: LogTable, format: LogFormat) {
        let data = Data(text.utf8)

        var root: Any?
        if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            root = object
        } else {
            // JSON lines: one object per line
            var objects: [Any] = []
            for line in text.split(whereSeparator: { $0.isNewline }) {
                let piece = line.trimmingCharacters(in: .whitespaces)
                if piece.isEmpty { continue }
                guard let object = try? JSONSerialization.jsonObject(with: Data(piece.utf8)) else {
                    throw LogImportError.unreadable("It is not valid JSON.")
                }
                objects.append(object)
            }
            root = objects
        }

        var records: [[String: Any]] = []
        var format = LogFormat.genericJSON

        if let array = root as? [Any] {
            records = array.compactMap { $0 as? [String: Any] }
        } else if let dict = root as? [String: Any] {
            if let runs = dict["runs"] as? [[String: Any]],
               runs.first.map({ $0["info"] != nil || $0["data"] != nil }) == true {
                records = runs.map(flattenMLflowRun)
                format = .mlflowJSON
            } else if let metrics = dict["metrics"] as? [[String: Any]],
                      metrics.first.map({ $0["key"] != nil && $0["value"] != nil }) == true {
                records = pivotMLflowHistory(metrics)
                format = .mlflowJSON
            } else if let inner = ["runs", "history", "rows", "data", "records", "results"]
                .compactMap({ dict[$0] as? [[String: Any]] }).first {
                records = inner
            } else if let columns = columnOriented(dict) {
                records = columns
            } else {
                records = [dict]       // a single summary object, such as wandb-summary.json
            }
        } else {
            throw LogImportError.unreadable("Expected a list of runs or rows.")
        }

        guard !records.isEmpty else { throw LogImportError.empty }

        var flattened: [[String: LogCell]] = []
        var headerSet = Set<String>()
        for record in records {
            var row: [String: LogCell] = [:]
            flatten(record, prefix: "", into: &row)
            headerSet.formUnion(row.keys)
            flattened.append(row)
        }
        let headers = headerSet.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let rows = flattened.map { row in headers.map { row[$0] ?? .empty } }

        if format == .genericJSON {
            let lower = Set(headers.map { $0.lowercased() })
            if lower.contains("_step") || lower.contains("_runtime") || lower.contains("_timestamp") {
                format = .wandbHistoryJSON
            }
        }
        return (LogTable(headers: headers, rows: rows), format)
    }

    private static func flatten(_ value: Any, prefix: String, into row: inout [String: LogCell]) {
        if let dict = value as? [String: Any] {
            for (key, inner) in dict {
                flatten(inner, prefix: prefix.isEmpty ? key : prefix + "." + key, into: &row)
            }
        } else if value is [Any] {
            return                                   // arrays inside a row (histograms, tags) are skipped
        } else if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                row[prefix] = .text(number.boolValue ? "true" : "false")
            } else if number.doubleValue.isFinite {
                row[prefix] = .number(number.doubleValue)
            }
        } else if let text = value as? String {
            row[prefix] = cell(text)
        }
    }

    private static func flattenMLflowRun(_ run: [String: Any]) -> [String: Any] {
        var row: [String: Any] = [:]
        let info = run["info"] as? [String: Any] ?? [:]
        let data = run["data"] as? [String: Any] ?? [:]

        row["run_id"] = info["run_id"] ?? info["run_uuid"]
        row["status"] = info["status"]
        row["start_time"] = info["start_time"]
        row["end_time"] = info["end_time"]

        var name = info["run_name"] as? String
        for tag in data["tags"] as? [[String: Any]] ?? [] {
            guard let key = tag["key"] as? String else { continue }
            if key == "mlflow.runName", name == nil { name = tag["value"] as? String }
            if key == "mlflow.source.git.commit" { row["tags.mlflow.source.git.commit"] = tag["value"] }
        }
        row["run_name"] = name

        for param in data["params"] as? [[String: Any]] ?? [] {
            if let key = param["key"] as? String { row["params." + key] = param["value"] }
        }
        // several entries for one key: keep the highest step
        var latest: [String: (step: Double, value: Any)] = [:]
        for metric in data["metrics"] as? [[String: Any]] ?? [] {
            guard let key = metric["key"] as? String, let value = metric["value"] else { continue }
            let step = (metric["step"] as? NSNumber)?.doubleValue ?? 0
            if let current = latest[key], current.step > step { continue }
            latest[key] = (step, value)
        }
        for (key, entry) in latest { row[key] = entry.value }
        return row
    }

    private static func pivotMLflowHistory(_ entries: [[String: Any]]) -> [[String: Any]] {
        var byStep: [Double: [String: Any]] = [:]
        for entry in entries {
            guard let key = entry["key"] as? String, let value = entry["value"] else { continue }
            let step = (entry["step"] as? NSNumber)?.doubleValue ?? 0
            byStep[step, default: ["step": step]][key] = value
        }
        return byStep.keys.sorted().compactMap { byStep[$0] }
    }

    /// {"step": [0, 1, 2], "loss": [0.9, 0.5, 0.3]} -> three rows.
    private static func columnOriented(_ dict: [String: Any]) -> [[String: Any]]? {
        let columns = dict.compactMapValues { $0 as? [Any] }
        guard !columns.isEmpty, columns.count == dict.count,
              let length = columns.values.first?.count, length > 0,
              columns.values.allSatisfy({ $0.count == length }) else { return nil }
        return (0..<length).map { i in columns.mapValues { $0[i] } }
    }

    // MARK: 2. Suggest a mapping

    private static let stepNames = ["step", "globalstep", "round", "epoch", "iteration", "iter", "timestep"]
    private static let settingNames = ["setting", "runname", "mlflowrunname", "name", "group", "method", "variant", "algorithm"]
    private static let ignoredNames: Set<String> = [
        "starttime", "endtime", "duration", "runtime", "timestamp", "user", "sourcetype", "sourcename",
        "source", "entrypoint", "notes", "tags", "artifacturi", "experimentid", "created", "createdat",
        "sweep", "lifecyclestage", "parentrunid", "runstatus", "id"
    ]
    private static let parameterNames: Set<String> = [
        "learningrate", "lr", "batchsize", "bs", "epochs", "numepochs", "momentum", "weightdecay", "wd",
        "dropout", "optimizer", "hiddensize", "hidden", "layers", "numlayers", "nlayers", "clients",
        "numclients", "localepochs", "mu", "beta1", "beta2", "warmup", "scheduler", "model", "dataset",
        "split", "alpha", "temperature"
    ]
    private static let lowerIsBetterWords = [
        "loss", "error", "err", "mse", "mae", "rmse", "perplexity", "ppl", "wer", "cer",
        "time", "latency", "runtime", "duration", "distance", "drift", "cost", "regret"
    ]

    /// A guess for every column, in file order. The person can change any of them.
    static func suggestMapping(for log: ParsedLog) -> [ColumnMapping] {
        let headers = log.table.headers

        // Statistics per column
        struct Stats { var nonEmpty = 0; var numeric = 0; var distinctText = Set<String>(); var example = "" }
        var stats = [Stats](repeating: Stats(), count: headers.count)
        for row in log.table.rows {
            for (i, cell) in row.enumerated() where !cell.isEmpty {
                stats[i].nonEmpty += 1
                if cell.number != nil { stats[i].numeric += 1 }
                if stats[i].distinctText.count < 1000 { stats[i].distinctText.insert(cell.text) }
                if stats[i].example.isEmpty { stats[i].example = cell.text }
            }
        }

        struct Parsed { var prefix: String; var name: String; var compact: String }
        let parsed: [Parsed] = headers.map { header in
            var prefix = ""
            var name = header
            for p in ["metrics.", "params.", "config.", "summary.", "tags."] where header.lowercased().hasPrefix(p) {
                prefix = String(p.dropLast())
                name = String(header.dropFirst(p.count))
                break
            }
            return Parsed(prefix: prefix, name: name, compact: compact(name))
        }

        var roles = [ColumnRole](repeating: .ignore, count: headers.count)
        func isNumeric(_ i: Int) -> Bool { stats[i].nonEmpty > 0 && Double(stats[i].numeric) / Double(stats[i].nonEmpty) >= 0.5 }
        func isText(_ i: Int) -> Bool { stats[i].nonEmpty > 0 && !isNumeric(i) }

        // Single-purpose columns: pick the best candidate for each.
        func best(_ names: [String], where ok: (Int) -> Bool) -> Int? {
            for name in names {
                if let i = parsed.indices.first(where: { parsed[$0].compact == name && ok($0) }) { return i }
            }
            return nil
        }
        let stepIdx = best(stepNames) { parsed[$0].prefix != "tags" && isNumeric($0) }
        let runIDIdx = best(["runid", "id"]) { i in
            guard isText(i) || parsed[i].compact == "runid" else { return false }
            return parsed[i].compact == "runid" || stats[i].distinctText.count == log.rowCount
        }
        let seedIdx = parsed.indices.first {
            parsed[$0].compact == "seed" || parsed[$0].compact == "randomseed"
                || (["params", "config"].contains(parsed[$0].prefix) && parsed[$0].compact.hasSuffix("seed"))
        }
        let statusIdx = best(["status", "state"]) { _ in true }
        let commitIdx = parsed.indices.first {
            let lower = headers[$0].lowercased()
            return lower.contains("git.commit") || ["gitcommit", "codecommit", "commithash", "commit"].contains(parsed[$0].compact)
        }
        let settingIdx = best(settingNames) { isText($0) && $0 != runIDIdx }

        if let i = stepIdx { roles[i] = .step }
        if let i = runIDIdx { roles[i] = .runID }
        if let i = seedIdx { roles[i] = .seed }
        if let i = statusIdx { roles[i] = .status }
        if let i = commitIdx { roles[i] = .codeCommit }
        if let i = settingIdx { roles[i] = .setting }

        // Everything else
        for i in headers.indices where roles[i] == .ignore {
            let lowerHeader = headers[i].lowercased()
            let p = parsed[i]

            if lowerHeader.hasSuffix("__min") || lowerHeader.hasSuffix("__max") { continue }
            if p.prefix == "tags" { continue }
            if p.prefix == "params" || p.prefix == "config" { roles[i] = .parameter; continue }
            if ignoredNames.contains(p.compact) { continue }
            if stats[i].nonEmpty == 0 { continue }
            if parameterNames.contains(p.compact) { roles[i] = .parameter; continue }
            if p.prefix == "metrics" || isNumeric(i) { roles[i] = .metric }
        }

        return headers.indices.map { i in
            let name = parsed[i].name.trimmingCharacters(in: .whitespaces)
            let lower = name.lowercased()
            let isRate = lower.contains("acc") || lower.contains("accuracy")
            return ColumnMapping(
                index: i,
                header: headers[i],
                role: roles[i],
                metricName: name,
                higherIsBetter: !lowerIsBetterWords.contains { lower.contains($0) },
                unit: isRate && maxNumeric(log, column: i) > 1 ? "%" : "",
                example: stats[i].example
            )
        }
    }

    private static func maxNumeric(_ log: ParsedLog, column: Int) -> Double {
        log.table.rows.compactMap { $0[column].number }.max() ?? 0
    }

    private static func compact(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    // MARK: 3. Plan

    static func makePlan(
        from log: ParsedLog,
        mapping: [ColumnMapping],
        options: ImportOptions = ImportOptions()
    ) -> LogImportPlan {

        var warnings: [String] = []
        func column(_ role: ColumnRole) -> Int? { mapping.first { $0.role == role }?.index }
        let settingCol = column(.setting), runIDCol = column(.runID), seedCol = column(.seed)
        let stepCol = column(.step), statusCol = column(.status), commitCol = column(.codeCommit)
        let metricCols = mapping.filter { $0.role == .metric }
        let parameterCols = mapping.filter { $0.role == .parameter }

        let rows = log.table.rows

        // Rows that carry at least one metric value
        let usable: [Int] = rows.indices.filter { r in
            metricCols.contains { rows[r][$0.index].number != nil }
        }
        let skipped = rows.count - usable.count

        // Settings per row
        var settings: [Int: String] = [:]
        for r in usable {
            let text = settingCol.map { rows[r][$0].text.trimmingCharacters(in: .whitespaces) } ?? ""
            settings[r] = text.isEmpty ? "default" : text
        }
        if options.stripSeedSuffix, settingCol != nil {
            var seeds: [Int: Double] = [:]
            if let seedCol {
                for r in usable { if let value = rows[r][seedCol].number { seeds[r] = value } }
            }
            if let stripped = strippedSettings(settings, seeds: seeds) {
                settings = stripped.settings
                warnings.append("Removed the seed from setting names, for example “\(stripped.example.0)” became “\(stripped.example.1)”.")
            }
        }

        // Group rows into runs
        func seedText(_ r: Int) -> String { seedCol.map { rows[r][$0].text } ?? "" }
        var groupOrder: [String] = []
        var groups: [String: [Int]] = [:]
        for r in usable {
            let key: String
            if let id = runIDCol, !rows[r][id].isEmpty {
                key = "id:" + rows[r][id].text
            } else if stepCol != nil, settingCol != nil || seedCol != nil {
                key = "ss:\(settings[r] ?? "")|\(seedText(r))"
            } else if stepCol != nil {
                key = "all"
            } else {
                key = "row:\(r)"
            }
            if groups[key] == nil { groupOrder.append(key) }
            groups[key, default: []].append(r)
        }

        // A repeated step inside a group means these are separate runs, not one curve.
        var splitWarningShown = false
        var finalGroups: [[Int]] = []
        for key in groupOrder {
            let members = groups[key] ?? []
            if let step = stepCol, members.count > 1 {
                let steps = members.compactMap { rows[$0][step].number }
                if Set(steps).count != steps.count {
                    finalGroups.append(contentsOf: members.map { [$0] })
                    if !splitWarningShown {
                        warnings.append("Rows with the same setting, seed and step were imported as separate runs.")
                        splitWarningShown = true
                    }
                    continue
                }
            }
            finalGroups.append(members)
        }

        // Build runs
        var runs: [ImportedRun] = []
        var orderWarningShown = false
        for members in finalGroups {
            guard let first = members.first else { continue }

            var config: [String: String] = [:]
            for p in parameterCols {
                let value = rows[first][p.index].text
                if !value.isEmpty { config[p.metricName] = value }
            }
            if members.count == 1, let step = stepCol, !rows[first][step].isEmpty {
                config[mapping.first { $0.index == step }?.metricName ?? "step"] = rows[first][step].text
            }

            var metrics: [ImportedMetric] = []
            let isSeries = members.count > 1

            if isSeries, stepCol == nil, !orderWarningShown {
                warnings.append("Some runs have several rows but no step column, so the row order was used as the step.")
                orderWarningShown = true
            }

            for m in metricCols {
                var points: [(step: Double, order: Int, value: Double)] = []
                for (order, r) in members.enumerated() {
                    guard let value = rows[r][m.index].number else { continue }
                    let step = stepCol.flatMap { rows[r][$0].number } ?? Double(order)
                    points.append((step, order, value))
                }
                guard !points.isEmpty else { continue }
                points.sort { $0.step != $1.step ? $0.step < $1.step : $0.order < $1.order }

                let name = m.metricName.isEmpty ? m.header : m.metricName
                if isSeries && options.includeCurves {
                    for point in points {
                        metrics.append(ImportedMetric(
                            name: name, value: point.value, step: Int(point.step.rounded()),
                            higherIsBetter: m.higherIsBetter, unit: m.unit
                        ))
                    }
                }
                if let last = points.last {
                    metrics.append(ImportedMetric(
                        name: name, value: last.value, step: nil, higherIsBetter: m.higherIsBetter, unit: m.unit
                    ))
                }
            }
            guard !metrics.isEmpty else { continue }

            runs.append(ImportedRun(
                setting: settings[first] ?? "default",
                seed: seedCol.flatMap { rows[first][$0].number }.map { Int($0.rounded()) },
                status: statusCol.map { runStatus(rows[first][$0].text) } ?? "completed",
                codeCommit: commitCol.map { rows[first][$0].text } ?? "",
                config: config,
                metrics: metrics
            ))
        }

        if metricCols.isEmpty { warnings.append("No column is mapped as a metric.") }
        if skipped > 0 { warnings.append("\(skipped) \(skipped == 1 ? "row has" : "rows have") no metric value and will be skipped.") }

        return LogImportPlan(
            sourceFileName: log.fileName,
            format: log.format,
            rowCount: rows.count,
            columnCount: log.table.headers.count,
            runs: runs,
            skippedRows: skipped,
            warnings: warnings
        )
    }

    /// "fedprox-seed22" -> "fedprox". Only when the suffix is clearly a seed: the word "seed" in
    /// most names, or a trailing number that equals the seed column. "resnet-50" is left alone.
    private static func strippedSettings(
        _ settings: [Int: String], seeds: [Int: Double]
    ) -> (settings: [Int: String], example: (String, String))? {

        let explicit = try! NSRegularExpression(pattern: #"[\s_\-]*seed[\s_\-]*(\d+)$"#, options: [.caseInsensitive])
        let plain = try! NSRegularExpression(pattern: #"[\s_\-]+(\d+)$"#)

        var result: [Int: String] = [:]
        var changed = 0
        var example: (String, String)?

        for row in settings.keys.sorted() {
            guard let name = settings[row] else { continue }
            let ns = name as NSString
            let full = NSRange(location: 0, length: ns.length)
            var stripped = name

            if let m = explicit.firstMatch(in: name, range: full) {
                stripped = ns.substring(to: m.range.location)
            } else if let m = plain.firstMatch(in: name, range: full),
                      let seed = seeds[row], Double(ns.substring(with: m.range(at: 1))) == seed {
                stripped = ns.substring(to: m.range.location)
            }
            stripped = stripped.trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty || stripped == name {
                result[row] = name
            } else {
                result[row] = stripped
                changed += 1
                if example == nil { example = (name, stripped) }
            }
        }

        // Worth doing only if it merges runs, and covers most names.
        let before = Set(settings.values).count
        let after = Set(result.values).count
        guard let example, after < before, changed * 5 >= settings.count * 4 else { return nil }
        return (result, example)
    }

    private static func runStatus(_ text: String) -> String {
        switch text.lowercased() {
        case "running", "active": return "running"
        case "failed", "crashed", "killed", "error": return "failed"
        case "scheduled", "planned", "queued", "pending": return "planned"
        default: return "completed"      // finished, FINISHED, success, or no status
        }
    }
}

// MARK: - Reading and writing the library

final class LogMetricImporter {

    unowned let model: LibraryModel

    init(model: LibraryModel) {
        self.model = model
    }

    /// Reads a dropped file. Nothing is saved.
    func parse(fileAt url: URL) throws -> ParsedLog {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw LogImportError.unreadable("The file could not be opened.")
        }
        return try LogMetricParser.parse(data: data, fileName: url.lastPathComponent)
    }

    /// How many runs of this experiment already came from a file with this name.
    /// Use it to warn before importing the same log twice.
    func alreadyImportedRunCount(sourceFile: String, experimentID: String) throws -> Int {
        let rows = try model.database.rows(
            "SELECT COUNT(*) AS n FROM runs WHERE experiment_id = ? AND source_file = ?",
            [.text(experimentID), .text(sourceFile)]
        )
        return Int(rows.first?.int("n") ?? 0)
    }

    /// Writes the planned runs and metrics in one transaction: all of them, or none.
    func commit(_ plan: LogImportPlan, toExperiment experimentID: String) throws -> LogImportResult {
        guard !plan.runs.isEmpty else { throw LogImportError.nothingToImport }

        let exists = try model.database.rows(
            "SELECT id FROM experiments WHERE id = ? AND deleted_at IS NULL", [.text(experimentID)]
        )
        guard !exists.isEmpty else { throw ModelError.notFound(kind: "experiment", id: experimentID) }

        return try model.database.transaction {
            let last = try model.database.rows(
                "SELECT COALESCE(MAX(run_number), 0) AS n FROM runs WHERE experiment_id = ?", [.text(experimentID)]
            ).first?.int("n") ?? 0

            var runIDs: [String] = []
            var metricsAdded = 0

            for (offset, run) in plan.runs.enumerated() {
                let runID = UUID().uuidString
                try model.database.run(
                    """
                    INSERT INTO runs (id, experiment_id, setting, run_number, seed, status,
                                      config_json, notes, source_file, code_commit)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(runID), .text(experimentID), .text(run.setting),
                        .int(last + Int64(offset) + 1),
                        run.seed.map { SQLValue.int(Int64($0)) } ?? SQLValue.null,
                        .text(run.status),
                        .text(Self.json(run.config)),
                        .text("Imported from \(plan.sourceFileName)"),
                        .text(plan.sourceFileName),
                        .text(run.codeCommit)
                    ]
                )

                for metric in run.metrics {
                    try model.database.run(
                        """
                        INSERT INTO metrics (id, run_id, name, value, unit, higher_is_better, step)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                        [
                            .text(UUID().uuidString), .text(runID), .text(metric.name), .double(metric.value),
                            .text(metric.unit), .int(metric.higherIsBetter ? 1 : 0),
                            metric.step.map { SQLValue.int(Int64($0)) } ?? SQLValue.null
                        ]
                    )
                    metricsAdded += 1
                }
                runIDs.append(runID)
            }

            try model.database.run(
                "UPDATE experiments SET updated_at = ? WHERE id = ?", [.text(Library.nowISO()), .text(experimentID)]
            )
            return LogImportResult(runsAdded: runIDs.count, metricsAdded: metricsAdded, runIDs: runIDs)
        }
    }

    private static func json(_ config: [String: String]) -> String {
        guard !config.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
