//
//  ExperimentRunEditorView.swift
//  ResearchBase
//
//  Phase 9 — Experiments & Results
//
//  The create/edit sheet for a single ExperimentRun, presented by
//  ExperimentDetailTab.swift's Runs tab. Lets the researcher record
//  the run's status, timing, seed, configuration/notes, and its own
//  set of metrics (added/edited via the existing MetricEditorView
//  sheet). Metrics are held in memory until Save, then reconciled
//  against the run's existing metrics by ExperimentDetailView.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Common Metric Suggestions

/// Convenience quick-fill suggestions shown in MetricEditorView.
/// Purely a UI shortcut — any custom metric name can still be typed.
enum CommonMetricName {
    static let all: [String] = [
        "Accuracy",
        "Precision",
        "Recall",
        "F1 Score",
        "ROC-AUC",
        "MAE",
        "MSE",
        "RMSE",
        "Training Loss",
        "Validation Loss",
        "Training Time",
        "Inference Time"
    ]
}


// MARK: - Result

struct ExperimentRunFormResult {
    var status: ExperimentRunStatus
    var startedAt: Date?
    var completedAt: Date?
    var seed: Int?
    var configuration: String
    var notes: String
    var metrics: [MetricEditorResult]

    // Agent 73 (F-41): recorded per run. Defaulted so existing callers still compile.
    var codeCommit: String = ""
    var codeHasUncommittedChanges: Bool = false
    var additionalSeeds: [Int] = []
}


// ═══════════════════════════════════════════════════════════════
//  Owner: Agent 73 · Features: F-41 (per-run reproducibility), F-43 (import button)
//
//  PUBLIC API
//    ExperimentRunEditorView(run:onSave:libraryTarget:)   libraryTarget is optional
//    ExperimentRunFormResult                              + codeCommit, codeHasUncommittedChanges,
//                                                           additionalSeeds (defaulted)
//    RBA73ImportLogic                                     log → draft → values for this run (tested)
//    RBA73LibraryTarget(model:experimentID:)              lets a caller enable "import all runs"
//
//  How it works
//    * "Choose log file…" reads a CSV/JSON log with LogMetricParser (no database needed),
//      lets the person pick ONE run from it, and fills this form (metrics, seed, config, commit).
//      Nothing is saved until the person presses Save, as for every other field.
//    * "Import all runs into the library" appears only when the caller passes `libraryTarget`;
//      it uses LogMetricImporter.commit (one transaction, all or nothing).
//    * An existing run's commit / uncommitted flag / extra seeds are written straight onto the
//      run when Save is pressed, because the screen that saves the form (ExperimentDetailTab)
//      does not know these fields yet.
// ═══════════════════════════════════════════════════════════════

struct RBA73LibraryTarget {
    let model: LibraryModel
    let experimentID: String
}

enum RBA73ImportLogic {

    struct Draft: Equatable {
        var fileName: String
        var parsed: ParsedLog
        var mapping: [ColumnMapping]
        var plan: LogImportPlan
    }

    static let roles: [ColumnRole] = [
        .setting, .runID, .seed, .step, .status, .codeCommit, .parameter, .metric, .ignore
    ]

    /// Steps 1 to 3 of the importer. Final values only, because one run form holds one value per metric.
    static func load(data: Data, fileName: String) throws -> Draft {
        let parsed = try LogMetricParser.parse(data: data, fileName: fileName)
        let mapping = LogMetricParser.suggestMapping(for: parsed)
        let plan = LogMetricParser.makePlan(from: parsed, mapping: mapping, options: ImportOptions(includeCurves: false))
        return Draft(fileName: fileName, parsed: parsed, mapping: mapping, plan: plan)
    }

    static func replan(_ draft: Draft) -> Draft {
        var next = draft
        next.plan = LogMetricParser.makePlan(from: draft.parsed, mapping: draft.mapping, options: ImportOptions(includeCurves: false))
        return next
    }

    /// The same plan with whole curves, for "import all runs into the library".
    static func fullPlan(_ draft: Draft) -> LogImportPlan {
        LogMetricParser.makePlan(from: draft.parsed, mapping: draft.mapping, options: ImportOptions())
    }

    static func runLabel(_ run: ImportedRun, index: Int) -> String {
        var parts = ["Run \(index + 1)"]
        if !run.setting.isEmpty { parts.append(run.setting) }
        if let seed = run.seed { parts.append("seed \(seed)") }
        return parts.joined(separator: " · ")
    }

    static func finalMetrics(of run: ImportedRun) -> [MetricEditorResult] {
        run.metrics.filter { $0.step == nil }.map {
            MetricEditorResult(name: $0.name, value: $0.value, unit: $0.unit, higherIsBetter: $0.higherIsBetter)
        }
    }

    /// Same name (any capitals) replaces the value and keeps the old row's identity; new names are added.
    static func merge(_ incoming: [MetricEditorResult], into current: [MetricEditorResult]) -> [MetricEditorResult] {
        var result = current
        for metric in incoming {
            if let index = result.firstIndex(where: { $0.name.lowercased() == metric.name.lowercased() }) {
                result[index].value = metric.value
                result[index].unit = metric.unit
                result[index].higherIsBetter = metric.higherIsBetter
            } else {
                result.append(metric)
            }
        }
        return result
    }

    static func configurationText(_ config: [String: String]) -> String {
        config.keys.sorted().map { "\($0): \(config[$0] ?? "")" }.joined(separator: "\n")
    }

    /// "11, 22 33" → [11, 22, 33]. Empty → []. Anything that is not a whole number → nil.
    static func parseSeeds(_ text: String) -> [Int]? {
        let pieces = text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }).map(String.init)
        var seeds: [Int] = []
        for piece in pieces {
            guard let value = Int(piece) else { return nil }
            seeds.append(value)
        }
        return seeds
    }

    static func seedsText(_ seeds: [Int]) -> String {
        seeds.map(String.init).joined(separator: ", ")
    }

    /// Empty is fine (not recorded). Otherwise 7 to 40 hex characters.
    static func commitIsAcceptable(_ text: String) -> Bool {
        let value = Experiment.normalisedHash(text)
        return value.isEmpty || Experiment.isValidCommit(value)
    }

    @MainActor
    static func commitAll(_ draft: Draft, to target: RBA73LibraryTarget) throws -> (result: LogImportResult, alreadyThere: Int) {
        let importer = LogMetricImporter(model: target.model)
        let already = (try? importer.alreadyImportedRunCount(sourceFile: draft.fileName, experimentID: target.experimentID)) ?? 0
        let result = try importer.commit(fullPlan(draft), toExperiment: target.experimentID)
        return (result, already)
    }
}

// MARK: - Editor

struct ExperimentRunEditorView: View {

    let run: ExperimentRun?
    let onSave: (ExperimentRunFormResult) -> Void
    /// Optional. When given, the log import can also write every run into the SQLite library.
    let libraryTarget: RBA73LibraryTarget?

    @Environment(\.dismiss) private var dismiss

    @State private var status: ExperimentRunStatus
    @State private var hasStartedAt: Bool
    @State private var startedAt: Date
    @State private var hasCompletedAt: Bool
    @State private var completedAt: Date
    @State private var seedText: String
    @State private var configuration: String
    @State private var notes: String
    @State private var metrics: [MetricEditorResult]

    @State private var codeCommit: String
    @State private var uncommitted: Bool
    @State private var additionalSeedsText: String

    @State private var showingLogPicker = false
    @State private var logDraft: RBA73ImportLogic.Draft?
    @State private var chosenRunIndex = 0
    @State private var importMessage: String?
    @State private var importError: String?

    @State private var showingNewMetric = false
    @State private var editingMetricIndex: Int?

    init(
        run: ExperimentRun?,
        libraryTarget: RBA73LibraryTarget? = nil,
        onSave: @escaping (ExperimentRunFormResult) -> Void
    ) {
        self.run = run
        self.onSave = onSave
        self.libraryTarget = libraryTarget

        _codeCommit = State(initialValue: run?.codeCommit ?? "")
        _uncommitted = State(initialValue: run?.codeHasUncommittedChanges ?? false)
        _additionalSeedsText = State(initialValue: RBA73ImportLogic.seedsText(run?.additionalSeeds ?? []))

        _status = State(initialValue: run?.status ?? .planned)
        _hasStartedAt = State(initialValue: run?.startedAt != nil)
        _startedAt = State(initialValue: run?.startedAt ?? Date())
        _hasCompletedAt = State(initialValue: run?.completedAt != nil)
        _completedAt = State(initialValue: run?.completedAt ?? Date())
        _seedText = State(initialValue: run?.seed.map(String.init) ?? "")
        _configuration = State(initialValue: run?.configuration ?? "")
        _notes = State(initialValue: run?.notes ?? "")

        _metrics = State(initialValue: (run?.metrics ?? []).map { metric in
            MetricEditorResult(
                existingID: metric.id,
                name: metric.name,
                value: metric.value,
                unit: metric.unit,
                higherIsBetter: metric.higherIsBetter
            )
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(RBColor.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    statusSection
                    timingSection
                    seedSection
                    reproducibilitySection
                    importSection
                    RB9TextEditor(label: "Configuration", text: $configuration, minHeight: 70)
                    RB9TextEditor(label: "Notes", text: $notes, minHeight: 70)
                    metricsSection
                }
                .padding(24)
            }
        }
        .frame(width: 560, height: 680)
        .background(RBColor.elevatedSurface)
        .fileImporter(
            isPresented: $showingLogPicker,
            allowedContentTypes: [.commaSeparatedText, .json, .plainText]
        ) { result in
            handleLogPick(result)
        }
        .sheet(isPresented: $showingNewMetric) {
            MetricEditorView(navTitle: "Add Metric", initial: nil) { result in
                metrics.append(result)
            }
        }
        .sheet(isPresented: editingMetricPresented) {
            if let index = editingMetricIndex, metrics.indices.contains(index) {
                MetricEditorView(navTitle: "Edit Metric", initial: metrics[index]) { updated in
                    metrics[index] = updated
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text(run == nil ? "New Run" : "Edit Run")
                .font(RBFont.section(.semibold))
                .foregroundStyle(RBColor.primaryText)

            Spacer()

            Button("Cancel") { dismiss() }
                .buttonStyle(RBGhostButtonStyle())

            Button("Save") { save() }
            .disabled(!formIsValid)
            .buttonStyle(RBPrimaryButtonStyle())
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    // MARK: Reproducibility (F-41)

    private var reproducibilitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            RB9SectionLabel(text: "Reproducibility")

            if run == nil {
                Text("Save the run first, then edit it to record the code commit and extra seeds.")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)
            } else {
                RB9TextField(label: "Code commit", text: $codeCommit, placeholder: "git commit hash (optional)")

                if !RBA73ImportLogic.commitIsAcceptable(codeCommit) {
                    Text("A commit is 7 to 40 letters and digits from 0 to 9 and a to f.")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.warning)
                }

                Toggle("The code had uncommitted changes", isOn: $uncommitted)
                    .toggleStyle(.checkbox)
                    .font(RBFont.secondary())
                    .foregroundStyle(RBColor.primaryText)

                RB9TextField(label: "Other seeds", text: $additionalSeedsText,
                             placeholder: "e.g. 11, 22 (data split, weight init)")

                if RBA73ImportLogic.parseSeeds(additionalSeedsText) == nil {
                    Text("Seeds must be whole numbers separated by commas.")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.warning)
                }
            }
        }
    }

    private var formIsValid: Bool {
        guard run != nil else { return true }
        return RBA73ImportLogic.commitIsAcceptable(codeCommit)
            && RBA73ImportLogic.parseSeeds(additionalSeedsText) != nil
    }

    // MARK: Import from log (F-43)

    private var importSection: some View {
        VStack(alignment: .leading, spacing: 10) {

            HStack {
                RB9SectionLabel(text: "Import from log")
                Spacer()
                Button {
                    showingLogPicker = true
                } label: {
                    Label("Choose log file…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(RBGhostButtonStyle())
            }

            Text("CSV or JSON exports from MLflow or Weights & Biases. Pick one run from the file to fill this form.")
                .font(RBFont.caption())
                .foregroundStyle(RBColor.mutedText)

            if let importError {
                Text(importError)
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.warning)
            }

            if let draft = logDraft {
                reviewPanel(draft)
            }

            if let importMessage {
                Text(importMessage)
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)
            }
        }
    }

    private func reviewPanel(_ draft: RBA73ImportLogic.Draft) -> some View {
        VStack(alignment: .leading, spacing: 10) {

            Text("Detected: \(draft.parsed.format.displayName) · \(draft.parsed.rowCount) rows")
                .font(RBFont.secondary(.medium))
                .foregroundStyle(RBColor.primaryText)

            Text("\(draft.plan.runCount) run(s), \(draft.plan.metricRowCount) metric value(s)")
                .font(RBFont.caption())
                .foregroundStyle(RBColor.secondaryText)

            ForEach(draft.plan.warnings, id: \.self) { warning in
                Text(warning)
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.warning)
            }

            if draft.plan.runs.isEmpty {
                Text("Nothing to import. Try changing what a column becomes below.")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.warning)
            } else {
                if draft.plan.runs.count > 1 {
                    Picker("Run to use", selection: $chosenRunIndex) {
                        ForEach(draft.plan.runs.indices, id: \.self) { index in
                            Text(RBA73ImportLogic.runLabel(draft.plan.runs[index], index: index)).tag(index)
                        }
                    }
                    .pickerStyle(.menu)
                }

                HStack(spacing: 10) {
                    Button("Use this run's values") { applyChosenRun() }
                        .buttonStyle(RBPrimaryButtonStyle())

                    if libraryTarget != nil {
                        Button("Import all \(draft.plan.runCount) runs into the library") {
                            importAllRuns(draft)
                        }
                        .buttonStyle(RBGhostButtonStyle())
                    }
                }
            }

            DisclosureGroup("Columns in the file") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(draft.mapping.indices, id: \.self) { index in
                        HStack {
                            Text(draft.mapping[index].header)
                                .font(RBFont.caption())
                                .foregroundStyle(RBColor.primaryText)
                                .lineLimit(1)
                            Spacer()
                            Menu(draft.mapping[index].role.displayName) {
                                ForEach(RBA73ImportLogic.roles, id: \.displayName) { role in
                                    Button(role.displayName) { setRole(index, role) }
                                }
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }
                }
                .padding(.top, 6)
            }
            .font(RBFont.caption())
        }
        .padding(12)
        .background(RBColor.card)
        .clipShape(RoundedRectangle(cornerRadius: RBRadius.field))
        .overlay(RoundedRectangle(cornerRadius: RBRadius.field).stroke(RBColor.border))
    }

    private func handleLogPick(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                logDraft = try RBA73ImportLogic.load(data: data, fileName: url.lastPathComponent)
                chosenRunIndex = 0
                importError = nil
                importMessage = nil
            } catch {
                logDraft = nil
                importError = error.localizedDescription
            }
        }
    }

    private func setRole(_ index: Int, _ role: ColumnRole) {
        guard var draft = logDraft, draft.mapping.indices.contains(index) else { return }
        draft.mapping[index].role = role
        if role == .metric, draft.mapping[index].metricName.isEmpty {
            draft.mapping[index].metricName = draft.mapping[index].header
        }
        logDraft = RBA73ImportLogic.replan(draft)
        chosenRunIndex = 0
    }

    private func applyChosenRun() {
        guard let draft = logDraft, draft.plan.runs.indices.contains(chosenRunIndex) else { return }
        let imported = draft.plan.runs[chosenRunIndex]
        let incoming = RBA73ImportLogic.finalMetrics(of: imported)

        metrics = RBA73ImportLogic.merge(incoming, into: metrics)

        if seedText.trimmingCharacters(in: .whitespaces).isEmpty, let seed = imported.seed {
            seedText = String(seed)
        }
        if configuration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            configuration = RBA73ImportLogic.configurationText(imported.config)
        }
        if run != nil, codeCommit.isEmpty, Experiment.isValidCommit(imported.codeCommit) {
            codeCommit = Experiment.normalisedHash(imported.codeCommit)
        }

        importMessage = "Added \(incoming.count) metric(s) from \(draft.fileName). Press Save to keep them."
    }

    private func importAllRuns(_ draft: RBA73ImportLogic.Draft) {
        guard let target = libraryTarget else { return }
        do {
            let outcome = try RBA73ImportLogic.commitAll(draft, to: target)
            importMessage = outcome.result.summaryLine
                + (outcome.alreadyThere > 0 ? " (this file name had already been imported \(outcome.alreadyThere) run(s) before)" : "")
            importError = nil
        } catch {
            importError = error.localizedDescription
        }
    }

    private func save() {
        let seeds = RBA73ImportLogic.parseSeeds(additionalSeedsText) ?? []
        let commit = Experiment.normalisedHash(codeCommit)

        if let run {
            run.codeCommit = commit
            run.codeHasUncommittedChanges = uncommitted
            run.additionalSeeds = seeds
        }

        onSave(
            ExperimentRunFormResult(
                status: status,
                startedAt: hasStartedAt ? startedAt : nil,
                completedAt: hasCompletedAt ? completedAt : nil,
                seed: Int(seedText.trimmingCharacters(in: .whitespaces)),
                configuration: configuration,
                notes: notes,
                metrics: metrics,
                codeCommit: commit,
                codeHasUncommittedChanges: uncommitted,
                additionalSeeds: seeds
            )
        )
        dismiss()
    }

    // MARK: Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            RB9SectionLabel(text: "Status")

            Picker("", selection: $status) {
                ForEach(ExperimentRunStatus.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    // MARK: Timing

    private var timingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            RB9SectionLabel(text: "Timing")

            Toggle("Started", isOn: $hasStartedAt)
                .toggleStyle(.checkbox)
                .font(RBFont.secondary())
                .foregroundStyle(RBColor.primaryText)

            if hasStartedAt {
                DatePicker("", selection: $startedAt, displayedComponents: [.date])
                    .labelsHidden()
            }

            Toggle("Completed", isOn: $hasCompletedAt)
                .toggleStyle(.checkbox)
                .font(RBFont.secondary())
                .foregroundStyle(RBColor.primaryText)

            if hasCompletedAt {
                DatePicker("", selection: $completedAt, displayedComponents: [.date])
                    .labelsHidden()
            }
        }
    }

    // MARK: Seed

    private var seedSection: some View {
        RB9TextField(label: "Seed", text: $seedText, placeholder: "e.g. 42 (optional)")
    }

    // MARK: Metrics

    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                RB9SectionLabel(text: "Metrics")
                Spacer()
                Button {
                    showingNewMetric = true
                } label: {
                    Label("Add Metric", systemImage: "plus")
                }
                .buttonStyle(RBGhostButtonStyle())
            }

            if metrics.isEmpty {
                Text("No metrics recorded yet.")
                    .font(RBFont.secondary())
                    .foregroundStyle(RBColor.mutedText)
            } else {
                ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                    HStack {
                        Text(metric.name)
                            .font(RBFont.secondary(.medium))
                            .foregroundStyle(RBColor.primaryText)

                        Spacer()

                        Text(rb9FormatMetricValue(metric.value) + (metric.unit.isEmpty ? "" : " \(metric.unit)"))
                            .font(RBFont.secondary())
                            .foregroundStyle(RBColor.secondaryText)

                        Button {
                            editingMetricIndex = index
                        } label: {
                            Image(systemName: "pencil")
                                .foregroundStyle(RBColor.mutedText)
                        }
                        .buttonStyle(.plain)
                        .rbHover(cornerRadius: RBRadius.field)

                        Button {
                            metrics.remove(at: index)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(RBColor.mutedText)
                        }
                        .buttonStyle(.plain)
                        .rbHover(cornerRadius: RBRadius.field)
                    }
                    .padding(10)
                    .background(RBColor.card)
                    .clipShape(RoundedRectangle(cornerRadius: RBRadius.field))
                    .overlay(
                        RoundedRectangle(cornerRadius: RBRadius.field)
                            .stroke(RBColor.border)
                    )
                }
            }
        }
    }

    private var editingMetricPresented: Binding<Bool> {
        Binding(
            get: { editingMetricIndex != nil },
            set: { if !$0 { editingMetricIndex = nil } }
        )
    }
}
