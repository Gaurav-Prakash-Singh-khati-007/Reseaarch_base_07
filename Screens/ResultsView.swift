//
//  ResultsView.swift
//  ResearchBase
//
//  Owner: Agent 74 · Features: F-42, F-35
//
//  PUBLIC API
//    ResultsView                              the Results screen (unchanged signature)
//    EnvironmentValues.rbA74Library: LibraryModel?
//        NEW. The open library. Batch 4 may set `.environment(\.rbA74Library, model)`.
//        The screen also accepts `rbA65Library` (set for WritingView), so one of the two is enough.
//        While both are nil the screen works exactly as before (no extra tabs).
//    RBA74Stats, RBA74Export, RBA74BlockKind  pure helpers behind the two new tabs (see the
//        "Phase 3 · Agent 74" section at the end of this file)
//
//  F-42  "Repeated runs" tab: per setting, runs, mean ± SD, range; every pair of settings with the
//        difference, p-value and a "Likely real / Unclear" chip (RunStatistics, Agent 26).
//  F-35  "Use in draft" tab: results table, bar chart or learning curve from the experiment's runs,
//        inserted into a LaTeX draft (ExperimentFigureExporter, Agent 38). Inserting again replaces
//        the block; "Update all blocks" refreshes every generated block after new runs.
//
//  Phase 9 — Experiments & Results
//
//  A dedicated Results workspace: pick any experiment on the left,
//  see its results (best run, baseline, comparison, interpretation)
//  on the right via ExperimentResultsSection — reused unmodified
//  from ExperimentDetailTab.swift so this screen never duplicates
//  that logic.
//
 
import SwiftUI
import SwiftData
 
struct ResultsView: View {
 
    @Environment(\.modelContext) private var modelContext
    @Environment(\.rbA74Library) private var rbA74Library
    @Environment(\.rbA65Library) private var rbA65Library
 
    @Query(sort: [SortDescriptor(\Experiment.updatedAt, order: .reverse)])
    private var allExperiments: [Experiment]
 
    @State private var selectedExperimentID: UUID?

    // Phase 14 — stacked master/detail. Only controls which pane is
    // visible below RBMasterDetail's breakpoint; it is NOT the
    // selection. Back sets it to false without clearing the selection.
    @State private var showDetail = false
 
    @State private var showingNewBaselineMetric = false
    @State private var editingBaselineMetric: BaselineMetric?
    @State private var deletingBaselineMetric: BaselineMetric?
    @State private var errorMessage: String?
    @State private var rbA74Tab: RBA74Tab = .results

    private var rbA74LibraryModel: LibraryModel? { rbA74Library ?? rbA65Library }
 
    private var store: ResearchDataStore {
        ResearchDataStore(modelContext: modelContext)
    }
 
    private var selectedExperiment: Experiment? {
        guard let selectedExperimentID else { return nil }
        return allExperiments.first { $0.id == selectedExperimentID }
    }
 
    var body: some View {
        RBMasterDetail(
            masterMin: 240,
            masterIdeal: 320,
            showDetail: $showDetail,
            backTitle: "Results"
        ) {
            listPane
        } detail: {
            Group {
                if let selectedExperiment {
                    rbA74Detail(for: selectedExperiment)
                        .id(selectedExperiment.id)
                } else {
                    RB9DetailPlaceholder(
                        icon: "chart.bar",
                        text: allExperiments.isEmpty
                            ? "No experiments yet. Create one in the Experiments workspace first."
                            : "Select an experiment to see its results."
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RBColor.background)
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: allExperiments.count) {
            // Phase 14 — if the selected experiment no longer exists
            // (deleted elsewhere), leave the stacked detail so the
            // user isn't stranded on an empty placeholder.
            if selectedExperiment == nil { showDetail = false }
            selectFirstIfNeeded()
        }
        .sheet(isPresented: $showingNewBaselineMetric) {
            if let selectedExperiment {
                MetricEditorView(navTitle: "Add Baseline Metric", initial: nil) { result in
                    createBaselineMetric(result, for: selectedExperiment)
                }
            }
        }
        .sheet(item: $editingBaselineMetric) { metric in
            MetricEditorView(
                navTitle: "Edit Baseline Metric",
                initial: MetricEditorResult(
                    existingID: metric.id,
                    name: metric.name,
                    value: metric.value,
                    unit: metric.unit,
                    higherIsBetter: metric.higherIsBetter
                )
            ) { result in
                updateBaselineMetric(metric, with: result)
            }
        }
        .confirmationDialog(
            "Delete Baseline Metric?",
            isPresented: Binding(
                get: { deletingBaselineMetric != nil },
                set: { if !$0 { deletingBaselineMetric = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let deletingBaselineMetric { delete(baseline: deletingBaselineMetric) }
            }
            Button("Cancel", role: .cancel) { deletingBaselineMetric = nil }
        }
        .alert(
            "Something Went Wrong",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
 
    // MARK: Detail (tabs)

    @ViewBuilder
    private func rbA74Detail(for experiment: Experiment) -> some View {
        VStack(spacing: 0) {
            if rbA74LibraryModel != nil {
                Picker("", selection: $rbA74Tab) {
                    ForEach(RBA74Tab.allCases) { tab in Text(tab.title).tag(tab) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 460)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider().overlay(RBColor.border)
            }

            if let library = rbA74LibraryModel, rbA74Tab == .repeatedRuns {
                RBA74RepeatedRunsPanel(experimentID: experiment.id.uuidString, library: library)
            } else if let library = rbA74LibraryModel, rbA74Tab == .useInDraft {
                RBA74DraftExportPanel(experimentID: experiment.id.uuidString, library: library)
            } else {
                ExperimentResultsSection(
                    experiment: experiment,
                    onAddBaselineMetric: { showingNewBaselineMetric = true },
                    onEditBaselineMetric: { editingBaselineMetric = $0 },
                    onDeleteBaselineMetric: { deletingBaselineMetric = $0 },
                    onSelectBestRun: { run in markBest(run, in: experiment) },
                    onClearBestRun: { clearBest(experiment) },
                    onSaveInterpretation: { interpretation, conclusion in
                        saveResults(interpretation: interpretation, conclusion: conclusion, for: experiment)
                    }
                )
            }
        }
    }

    // MARK: List Pane
 
    private var listPane: some View {
        VStack(spacing: 0) {
            RBListPaneHeader(
                title: "Results",
                subtitle: RBListPaneMetrics.count(allExperiments.count, "experiment")
            )
 
            Divider().overlay(RBColor.border)
 
            if allExperiments.isEmpty {
                RB9EmptyState(
                    icon: "chart.bar",
                    title: "No Experiments Yet",
                    message: "Create an experiment first, then come back here to record and compare its results.",
                    actionTitle: "Go to Experiments",
                    action: {}
                )
            } else {
                RBListColumn {
                    ForEach(allExperiments, id: \.id) { experiment in
                        RB9RowCard(
                            isSelected: selectedExperimentID == experiment.id,
                            action: {
                                selectedExperimentID = experiment.id
                                // Phase 14 — an explicit pick opens the
                                // stacked detail (no-op when wide).
                                showDetail = true
                            }
                        ) {
                            rowContent(experiment)
                        }
                    }
                }
            }
        }
        .rbListPaneBackground()
    }
 
    private func rowContent(_ experiment: Experiment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(experiment.name)
                .font(RBFont.body(.medium))
                .foregroundStyle(RBColor.primaryText)
                .lineLimit(2)
 
            RB9StatusPill(text: experiment.status.rawValue, color: rbExperimentStatusColor(experiment.status))
 
            Label(
                "\(experiment.runs.count) run\(experiment.runs.count == 1 ? "" : "s")",
                systemImage: "arrow.triangle.2.circlepath"
            )
            .font(RBFont.label())
            .foregroundStyle(RBColor.mutedText)
        }
    }
 
    // MARK: Actions
 
    /// Selects the first experiment when nothing is selected. Phase 14:
    /// this deliberately does NOT set `showDetail`, so opening Results
    /// at a narrow width lands on the list, not inside the detail.
    private func selectFirstIfNeeded() {
        if selectedExperimentID == nil {
            selectedExperimentID = allExperiments.first?.id
        }
    }
 
    private func markBest(_ run: ExperimentRun, in experiment: Experiment) {
        act { try store.setBestRun(run, for: experiment) }
    }
 
    private func clearBest(_ experiment: Experiment) {
        act { try store.setBestRun(nil, for: experiment) }
    }
 
    private func saveResults(interpretation: String, conclusion: String, for experiment: Experiment) {
        act { try store.updateExperimentResults(experiment, interpretation: interpretation, conclusion: conclusion) }
    }
 
    private func createBaselineMetric(_ result: MetricEditorResult, for experiment: Experiment) {
        act {
            try store.createBaselineMetric(
                name: result.name,
                value: result.value,
                unit: result.unit,
                higherIsBetter: result.higherIsBetter,
                for: experiment
            )
        }
    }
 
    private func updateBaselineMetric(_ metric: BaselineMetric, with result: MetricEditorResult) {
        act {
            try store.updateBaselineMetric(
                metric,
                name: result.name,
                value: result.value,
                unit: result.unit,
                higherIsBetter: result.higherIsBetter
            )
        }
    }
 
    private func delete(baseline metric: BaselineMetric) {
        act {
            try store.deleteBaselineMetric(metric)
            deletingBaselineMetric = nil
        }
    }
 
    private func act(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}


// MARK: - Phase 3 · Agent 74 — repeated runs and export to drafts (F-42, F-35)
//
//  Owner: Agent 74 · Features: F-42, F-35
//
//  Everything below is private to this file in spirit: nothing outside it was edited.
//  It reads the SQLite library through `RunStatisticsLoader` (Agent 26) and
//  `ExperimentFigureExporter` (Agent 38), and writes drafts only through `DraftFolderStore`
//  and `DraftHistoryStore`. The experiment's SwiftData `id.uuidString` is the library's
//  experiment id (the migrator keeps ids), so an experiment that was not migrated yet simply
//  shows a short "not in the library yet" note.

// MARK: Environment

struct RBA74LibraryKey: EnvironmentKey {
    static var defaultValue: LibraryModel? { nil }
}

extension EnvironmentValues {
    var rbA74Library: LibraryModel? {
        get { self[RBA74LibraryKey.self] }
        set { self[RBA74LibraryKey.self] = newValue }
    }
}

// MARK: Tabs

enum RBA74Tab: String, CaseIterable, Identifiable {
    case results, repeatedRuns, useInDraft

    var id: String { rawValue }

    var title: String {
        switch self {
        case .results: return "Results"
        case .repeatedRuns: return "Repeated runs"
        case .useInDraft: return "Use in draft"
        }
    }
}

// MARK: Pure helpers — repeated runs (F-42)

nonisolated struct RBA74SettingRow: Equatable, Identifiable {
    var id: String { name }
    var name: String
    var runs: Int
    /// "86.50 ± 0.32", or "86.50 (1 run)".
    var meanSD: String
    /// "84.10–84.90".
    var range: String
    var isBest: Bool
}

nonisolated struct RBA74ComparisonRow: Equatable, Identifiable {
    var id: String
    /// "B vs A": the difference is mean(B) − mean(A).
    var label: String
    /// Signed, "+2.00", or "n/a".
    var difference: String
    /// "95% CI [1.52, 2.48]", or "".
    var interval: String
    var pValue: String
    var verdict: SignificanceVerdict
    var smallSample: Bool
}

nonisolated enum RBA74Stats {

    static func settingRows(_ analysis: RunAnalysis, decimals: Int = 2) -> [RBA74SettingRow] {
        analysis.settings.enumerated().map { index, setting in
            let summary = index < analysis.summaries.count ? analysis.summaries[index] : nil
            return RBA74SettingRow(
                name: setting.name,
                runs: setting.values.count,
                meanSD: summary.map { RunStatistics.formatMeanSD($0, decimals: decimals) } ?? "n/a",
                range: summary.map { RunStatistics.formatRange($0, decimals: decimals) } ?? "n/a",
                isBest: analysis.bestSetting == setting.name
            )
        }
    }

    static func comparisonRows(_ analysis: RunAnalysis, decimals: Int = 2) -> [RBA74ComparisonRow] {
        analysis.comparisons.enumerated().map { index, comparison in
            let r = comparison.result
            let interval: String
            if let ci = r.confidenceInterval95 {
                interval = "95% CI [" + String(format: "%.\(decimals)f", ci.lowerBound) + ", "
                    + String(format: "%.\(decimals)f", ci.upperBound) + "]"
            } else {
                interval = ""
            }
            return RBA74ComparisonRow(
                id: "\(index)·\(comparison.label)",
                label: comparison.label,
                difference: r.meanDifference.map { String(format: "%+.\(decimals)f", $0) } ?? "n/a",
                interval: interval,
                pValue: RunStatistics.formatP(r.p),
                verdict: r.verdict,
                smallSample: r.smallSample
            )
        }
    }

    /// True when at least one real test ran on few seeds, so the note about it should show.
    static func needsSmallSampleNote(_ analysis: RunAnalysis) -> Bool {
        analysis.comparisons.contains {
            $0.result.smallSample && ($0.result.verdict == .likelyReal || $0.result.verdict == .unclear)
        }
    }
}

// MARK: Pure helpers — LaTeX text (F-35)

nonisolated enum RBA74Latex {

    /// Package names loaded by `\usepackage` lines that are not commented out.
    static func loadedPackages(in source: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"\\usepackage(?:\[[^\]]*\])?\{([^}]*)\}"#) else { return [] }
        var found = Set<String>()
        for line in source.components(separatedBy: "\n") {
            let code = codePart(of: line)
            let range = NSRange(code.startIndex..., in: code)
            for match in regex.matches(in: code, range: range) {
                guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: code) else { continue }
                for name in code[r].split(separator: ",") {
                    found.insert(name.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return found
    }

    static func missingPackages(_ needed: [String], in source: String) -> [String] {
        let have = loadedPackages(in: source)
        var seen = Set<String>()
        return needed.filter { !have.contains($0) && seen.insert($0).inserted }
    }

    /// Adds `\usepackage{…}` lines right after the `\documentclass` line.
    /// Returns nil when the file has no usable `\documentclass` line (a chapter file, for example).
    static func addingPackages(_ names: [String], to source: String) -> String? {
        guard !names.isEmpty else { return source }
        let crlf = source.contains("\r\n")
        var lines = source.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: {
            let code = codePart(of: $0)
            return code.contains("\\documentclass") && code.contains("}")
        }) else { return nil }
        let added = names.map { "\\usepackage{\($0)}" + (crlf ? "\r" : "") }
        lines.insert(contentsOf: added, at: index + 1)
        return lines.joined(separator: "\n")
    }

    /// The line without a trailing `% comment` (a `\%` is not a comment).
    private static func codePart(of line: String) -> String {
        var result = ""
        var previous: Character?
        for ch in line {
            if ch == "%", previous != "\\" { break }
            result.append(ch)
            previous = ch
        }
        return result
    }
}

// MARK: Export to a draft (F-35)

enum RBA74BlockKind: String, CaseIterable, Identifiable {
    case table, bar, curve

    var id: String { rawValue }

    var title: String {
        switch self {
        case .table: return "Table"
        case .bar: return "Bar chart"
        case .curve: return "Learning curve"
        }
    }
}

struct RBA74InsertOutcome: Equatable {
    /// An earlier generated block for the same metric was replaced instead of adding a copy.
    var replaced: Bool
    var packagesAdded: [String]
    /// Packages the block needs that could not be added (the file has no `\documentclass`).
    var packagesToAddByHand: [String]
    /// "figures/<name>.pdf" when a figure file was written.
    var figureFile: String?
}

enum RBA74Export {

    static func build(
        exporter: ExperimentFigureExporter,
        experimentID: String,
        metric: String,
        kind: RBA74BlockKind,
        options: ExperimentTexOptions
    ) throws -> (block: ExperimentTexBlock, pdf: Data?) {
        switch kind {
        case .table:
            return (try exporter.resultsTable(experimentID: experimentID, metric: metric, options: options), nil)
        case .bar:
            let made = try exporter.figure(experimentID: experimentID, metric: metric, style: .bar, options: options)
            return (made.block, made.pdf)
        case .curve:
            let made = try exporter.figure(experimentID: experimentID, metric: metric, style: .curve, options: options)
            return (made.block, made.pdf)
        }
    }

    /// Puts one block into the draft's main file. A history snapshot is taken first, so
    /// "Restore" in the history sheet undoes it. Nothing is written if the snapshot fails.
    static func insert(
        _ block: ExperimentTexBlock,
        pdf: Data?,
        intoDraft draftID: String,
        model: LibraryModel
    ) throws -> RBA74InsertOutcome {

        let drafts = DraftFolderStore(model: model)
        guard let draft = try drafts.draft(id: draftID) else {
            throw ModelError.notFound(kind: "draft", id: draftID)
        }

        let source = try drafts.readText(draftID: draft.id, path: draft.mainFile)
        let inserted = ExperimentFigureExporter.insert(block, into: source)
        var text = inserted.text

        let missing = RBA74Latex.missingPackages(block.requiredPackages, in: text)
        var added: [String] = []
        var byHand: [String] = []
        if !missing.isEmpty {
            if let withPackages = RBA74Latex.addingPackages(missing, to: text) {
                text = withPackages
                added = missing
            } else {
                byHand = missing
            }
        }

        try DraftHistoryStore(model: model).takeSnapshot(
            draftID: draft.id,
            label: "Before adding results: \(block.metric)",
            auto: true
        )

        var figureFile: String?
        if let pdf, block.figureFile != nil {
            try ExperimentFigureExporter(model: model).writeFigure(pdf, for: block, in: drafts.folderURL(for: draft))
            figureFile = block.figureFile
        }
        try drafts.writeText(draftID: draft.id, path: draft.mainFile, text: text)

        return RBA74InsertOutcome(replaced: inserted.replaced, packagesAdded: added, packagesToAddByHand: byHand, figureFile: figureFile)
    }

    /// Rebuilds every generated block in the draft's main file from the current runs.
    static func refreshAll(inDraft draftID: String, model: LibraryModel) throws -> ExperimentRefreshResult {

        let drafts = DraftFolderStore(model: model)
        guard let draft = try drafts.draft(id: draftID) else {
            throw ModelError.notFound(kind: "draft", id: draftID)
        }

        let source = try drafts.readText(draftID: draft.id, path: draft.mainFile)
        guard !ExperimentFigureExporter.existingBlocks(in: source).isEmpty else {
            return ExperimentRefreshResult(text: source, refreshed: 0, warnings: [])
        }

        try DraftHistoryStore(model: model).takeSnapshot(
            draftID: draft.id, label: "Before updating results blocks", auto: true
        )

        let result = try ExperimentFigureExporter(model: model)
            .refreshBlocks(in: source, draftFolder: drafts.folderURL(for: draft))
        if result.refreshed > 0, result.text != source {
            try drafts.writeText(draftID: draft.id, path: draft.mainFile, text: result.text)
        }
        return result
    }
}

// MARK: - Repeated runs tab (F-42)

private struct RBA74RepeatedRunsPanel: View {

    let experimentID: String
    let library: LibraryModel

    @State private var metrics: [MetricInfo] = []
    @State private var selectedMetric = ""
    @State private var analysis: RunAnalysis?
    @State private var message: String?
    @State private var loaded = false

    private let decimals = 2

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if let message {
                    RB9InlineEmptyNote(icon: "chart.bar.doc.horizontal", title: "No Repeated-Run Data", message: message)
                } else if loaded && metrics.isEmpty {
                    RB9InlineEmptyNote(
                        icon: "chart.bar.doc.horizontal",
                        title: "No Completed Runs With Metrics",
                        message: "Record the same setting with different seeds. Only completed runs with a final metric value count."
                    )
                } else if let analysis {
                    settingsSection(analysis)
                    comparisonsSection(analysis)
                }
            }
            .rbResponsiveContentPadding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RBColor.background)
        .task(id: experimentID) { reload() }
        .onChange(of: selectedMetric) {
            if analysis?.metric != selectedMetric { loadAnalysis() }
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                RB9SectionLabel(text: "Repeated runs")
                Text("Runs with the same setting are repeats (different seeds).")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)
            }
            Spacer()
            if metrics.count > 1 {
                Picker("Metric", selection: $selectedMetric) {
                    ForEach(metrics, id: \.name) { Text($0.name).tag($0.name) }
                }
                .frame(maxWidth: 220)
            }
            Button {
                reload()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(RBGhostButtonStyle())
        }
    }

    private func settingsSection(_ analysis: RunAnalysis) -> some View {
        let rows = RBA74Stats.settingRows(analysis, decimals: decimals)
        return VStack(alignment: .leading, spacing: 10) {
            RB9SectionLabel(text: "\(analysis.metric) per setting" + (analysis.higherIsBetter ? " (higher is better)" : " (lower is better)"))

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    columnTitle("Setting")
                    columnTitle("Runs")
                    columnTitle("Mean ± SD")
                    columnTitle("Min–max")
                    columnTitle("")
                }
                Divider().overlay(RBColor.border).gridCellColumns(5)
                ForEach(rows) { row in
                    GridRow {
                        Text(row.name)
                            .font(RBFont.body(.medium))
                            .foregroundStyle(RBColor.primaryText)
                        Text("\(row.runs)")
                            .font(RBFont.body())
                            .foregroundStyle(RBColor.secondaryText)
                        Text(row.meanSD)
                            .font(RBFont.body())
                            .foregroundStyle(RBColor.primaryText)
                            .monospacedDigit()
                        Text(row.range)
                            .font(RBFont.body())
                            .foregroundStyle(RBColor.secondaryText)
                            .monospacedDigit()
                        if row.isBest {
                            RB9StatusPill(text: "Best mean", color: RBColor.success)
                        } else {
                            Color.clear.frame(width: 1, height: 1)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RBColor.card)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(RBColor.border))
        }
    }

    private func comparisonsSection(_ analysis: RunAnalysis) -> some View {
        let rows = RBA74Stats.comparisonRows(analysis, decimals: decimals)
        return VStack(alignment: .leading, spacing: 10) {
            RB9SectionLabel(text: "Settings compared")

            if rows.isEmpty {
                Text("Add a second setting to compare.")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)
            } else {
                VStack(spacing: 8) {
                    ForEach(rows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.label)
                                    .font(RBFont.body(.medium))
                                    .foregroundStyle(RBColor.primaryText)
                                Text(["difference \(row.difference)", row.interval, "p = \(row.pValue)"]
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(RBFont.caption())
                                    .foregroundStyle(RBColor.mutedText)
                                    .monospacedDigit()
                            }
                            Spacer()
                            RB9StatusPill(text: row.verdict.chipText, color: color(for: row.verdict))
                        }
                        .padding(12)
                        .background(RBColor.card)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(RBColor.border))
                    }
                }

                if RBA74Stats.needsSmallSampleNote(analysis) {
                    Text(RunStatistics.smallSampleNote)
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func columnTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(RBFont.label(.semibold))
            .tracking(0.6)
            .foregroundStyle(RBColor.mutedText)
    }

    private func color(for verdict: SignificanceVerdict) -> Color {
        switch verdict {
        case .likelyReal: return RBColor.success
        case .unclear: return RBColor.warning
        case .notEnoughData, .noVariation: return RBColor.mutedText
        }
    }

    // MARK: Loading

    private func reload() {
        let loader = RunStatisticsLoader(model: library)
        do {
            let found = try loader.metrics(experimentID: experimentID)
            metrics = found
            message = nil
            if !found.contains(where: { $0.name == selectedMetric }) {
                selectedMetric = found.first?.name ?? ""
            }
            loadAnalysis()
        } catch {
            metrics = []
            analysis = nil
            message = "This experiment is not in the library yet, or could not be read (\(error.localizedDescription))."
        }
        loaded = true
    }

    private func loadAnalysis() {
        guard !selectedMetric.isEmpty else { analysis = nil; return }
        do {
            analysis = try RunStatisticsLoader(model: library).analysis(experimentID: experimentID, metric: selectedMetric)
            message = nil
        } catch {
            analysis = nil
            message = error.localizedDescription
        }
    }
}

// MARK: - Use in draft tab (F-35)

private struct RBA74DraftExportPanel: View {

    let experimentID: String
    let library: LibraryModel

    private struct Status {
        var text: String
        var isError: Bool
    }

    @State private var drafts: [StoredDraft] = []
    @State private var draftID = ""
    @State private var metrics: [ExperimentMetricInfo] = []
    @State private var metric = ""
    @State private var kind: RBA74BlockKind = .table
    @State private var decimals = 1
    @State private var includeBaselines = true
    @State private var caption = ""
    @State private var preview = ""
    @State private var problem: String?
    @State private var status: Status?
    @State private var loaded = false

    private var currentInfo: ExperimentMetricInfo? { metrics.first { $0.name == metric } }

    private var options: ExperimentTexOptions {
        var o = ExperimentTexOptions()
        o.decimals = decimals
        o.includeBaselines = includeBaselines
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        o.caption = trimmed.isEmpty ? nil : trimmed
        return o
    }

    /// The learning curve is offered only when runs report the metric at several steps.
    private var availableKinds: [RBA74BlockKind] {
        RBA74BlockKind.allCases.filter { $0 != .curve || currentInfo?.hasCurve == true }
    }

    private var canInsert: Bool { !draftID.isEmpty && !preview.isEmpty && problem == nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    RB9SectionLabel(text: "Use in draft")
                    Text("Insert a results table or figure straight from the runs. Inserting again replaces it, so numbers are never retyped.")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.mutedText)
                }

                if let problem, metrics.isEmpty {
                    RB9InlineEmptyNote(icon: "square.and.arrow.up", title: "Nothing To Insert Yet", message: problem)
                } else if loaded && drafts.isEmpty {
                    RB9InlineEmptyNote(
                        icon: "doc.text",
                        title: "No LaTeX Drafts",
                        message: "Create a LaTeX project in Writing first, then come back to insert results into it."
                    )
                } else {
                    controls
                    previewBox
                    actions
                    if let status {
                        Text(status.text)
                            .font(RBFont.caption())
                            .foregroundStyle(status.isError ? RBColor.error : RBColor.success)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .rbResponsiveContentPadding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RBColor.background)
        .task(id: experimentID) { reload() }
        .onChange(of: metric) { refreshPreview() }
        .onChange(of: kind) { refreshPreview() }
        .onChange(of: decimals) { refreshPreview() }
        .onChange(of: includeBaselines) { refreshPreview() }
        .onChange(of: caption) { refreshPreview() }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Draft", selection: $draftID) {
                ForEach(drafts) { Text($0.title).tag($0.id) }
            }

            if !metrics.isEmpty {
                Picker("Metric", selection: $metric) {
                    ForEach(metrics, id: \.name) { info in
                        Text(info.unit.isEmpty ? info.name : "\(info.name) (\(info.unit))").tag(info.name)
                    }
                }
            }

            Picker("Insert as", selection: $kind) {
                ForEach(availableKinds) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 20) {
                Stepper("Decimals: \(decimals)", value: $decimals, in: 0...4)
                Toggle("Show baselines", isOn: $includeBaselines)
            }

            RB9TextField(label: "Caption (LaTeX, optional)", text: $caption)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RBColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(RBColor.border))
    }

    private var previewBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            RB9SectionLabel(text: "LaTeX that will be inserted")
            if let problem, !metrics.isEmpty {
                Text(problem)
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.warning)
            }
            ScrollView([.horizontal, .vertical]) {
                Text(preview.isEmpty ? "—" : preview)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(RBColor.secondaryText)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 240)
            .background(RBColor.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                insert()
            } label: {
                Label("Insert into draft", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(RBPrimaryButtonStyle())
            .disabled(!canInsert)

            Button {
                refreshAll()
            } label: {
                Label("Update all results blocks", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(RBGhostButtonStyle())
            .disabled(draftID.isEmpty)
        }
    }

    // MARK: Work

    private func reload() {
        do {
            drafts = try DraftFolderStore(model: library).all()
            if !drafts.contains(where: { $0.id == draftID }) { draftID = drafts.first?.id ?? "" }
        } catch {
            drafts = []
            status = Status(text: error.localizedDescription, isError: true)
        }

        do {
            metrics = try ExperimentFigureExporter(model: library).availableMetrics(experimentID: experimentID)
            if metrics.isEmpty {
                problem = "This experiment has no completed runs with a metric yet."
            } else {
                problem = nil
                if !metrics.contains(where: { $0.name == metric }) { metric = metrics.first?.name ?? "" }
            }
        } catch {
            metrics = []
            problem = "This experiment is not in the library yet, or could not be read (\(error.localizedDescription))."
        }
        loaded = true
        refreshPreview()
    }

    private func refreshPreview() {
        status = nil
        if kind == .curve, currentInfo?.hasCurve != true { kind = .table }
        guard !metric.isEmpty else { preview = ""; return }
        do {
            let made = try RBA74Export.build(
                exporter: ExperimentFigureExporter(model: library),
                experimentID: experimentID, metric: metric, kind: kind, options: options
            )
            preview = made.block.text
            problem = nil
        } catch {
            preview = ""
            problem = error.localizedDescription
        }
    }

    private func insert() {
        do {
            let made = try RBA74Export.build(
                exporter: ExperimentFigureExporter(model: library),
                experimentID: experimentID, metric: metric, kind: kind, options: options
            )
            let outcome = try RBA74Export.insert(made.block, pdf: made.pdf, intoDraft: draftID, model: library)

            var parts = [outcome.replaced ? "Updated the existing block in the draft." : "Inserted into the draft."]
            if let figure = outcome.figureFile { parts.append("Figure saved as \(figure).") }
            if !outcome.packagesAdded.isEmpty {
                parts.append("Added \\usepackage for " + outcome.packagesAdded.joined(separator: ", ") + ".")
            }
            if !outcome.packagesToAddByHand.isEmpty {
                parts.append("Add \\usepackage{" + outcome.packagesToAddByHand.joined(separator: "}, \\usepackage{") + "} to your main file’s preamble.")
            }
            parts.append("A history snapshot was taken first.")
            status = Status(text: parts.joined(separator: " "), isError: false)
        } catch {
            status = Status(text: "Nothing was changed: \(error.localizedDescription)", isError: true)
        }
    }

    private func refreshAll() {
        do {
            let result = try RBA74Export.refreshAll(inDraft: draftID, model: library)
            if result.refreshed == 0 && result.warnings.isEmpty {
                status = Status(text: "This draft has no generated results blocks yet.", isError: false)
            } else {
                var text = "Updated \(result.refreshed) block\(result.refreshed == 1 ? "" : "s") from the current runs."
                if !result.warnings.isEmpty { text += " " + result.warnings.joined(separator: " ") }
                status = Status(text: text, isError: false)
            }
        } catch {
            status = Status(text: "Nothing was changed: \(error.localizedDescription)", isError: true)
        }
    }
}
