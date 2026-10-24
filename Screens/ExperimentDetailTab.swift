//
//  ExperimentDetailTab.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 27/09/26.
//


//
//  ExperimentDetailView.swift
//  ResearchBase
//
//  Phase 9 — Experiments & Results
//
//  The structured workspace shown when an experiment is selected in
//  ExperimentsView: Overview / Setup / Runs / Results / Notes tabs,
//  laid out with a manual tab bar (as established in Research Ideas)
//  rather than a nested NavigationSplitView.
//
//  ExperimentResultsSection below is also reused, unmodified, by
//  ResultsView.swift so the Results screen never duplicates the rest
//  of this workspace.
//

import SwiftUI
import SwiftData

// MARK: - Detail Tab

enum ExperimentDetailTab: String, CaseIterable {
    case overview = "Overview"
    case setup = "Setup"
    case runs = "Runs"
    case results = "Results"
    case notes = "Notes"

    var icon: String {
        switch self {
        case .overview: return "doc.text"
        case .setup: return "slider.horizontal.3"
        case .runs: return "arrow.triangle.2.circlepath"
        case .results: return "chart.bar"
        case .notes: return "note.text"
        }
    }
}


// MARK: - Root Detail View

struct ExperimentDetailView: View {

    let experiment: Experiment
    let allIdeas: [ResearchIdea]
    let allProblems: [ResearchProblem]
    let allGaps: [ResearchGap]
    let allPapers: [PaperRecord]
    let allNotes: [ResearchNote]
    let onEdit: () -> Void
    let onDelete: () -> Void

    @Environment(\.modelContext) private var modelContext

    @State private var selectedTab: ExperimentDetailTab = .overview

    @State private var showingIdeaPicker = false
    @State private var showingProblemPicker = false
    @State private var showingGapPicker = false
    @State private var showingPaperPicker = false
    @State private var showingNotePicker = false

    @State private var showingSetupEditor = false

    @State private var showingNewRunSheet = false
    @State private var editingRun: ExperimentRun?
    @State private var deletingRun: ExperimentRun?

    @State private var showingNewBaselineMetric = false
    @State private var editingBaselineMetric: BaselineMetric?
    @State private var deletingBaselineMetric: BaselineMetric?

    @State private var errorMessage: String?

    private var store: ResearchDataStore {
        ResearchDataStore(modelContext: modelContext)
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar

            Divider().overlay(RBColor.border)

            Group {
                switch selectedTab {
                case .overview:
                    overviewTab
                case .setup:
                    setupTab
                case .runs:
                    runsTab
                case .results:
                    resultsTab
                case .notes:
                    notesTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RBColor.background)
        .sheet(isPresented: $showingIdeaPicker) {
            ResearchLinkPickerView(
                navTitle: "Link Research Ideas",
                items: allIdeas,
                linkedIDs: linkedIdeaIDsBinding,
                emptyMessage: "No research ideas yet. Add ideas from the Research Ideas workspace first.",
                title: { $0.title },
                subtitle: { $0.status.rawValue },
                matches: { idea, q in idea.title.localizedCaseInsensitiveContains(q) }
            )
        }
        .sheet(isPresented: $showingProblemPicker) {
            ResearchLinkPickerView(
                navTitle: "Link Research Problems",
                items: allProblems,
                linkedIDs: linkedProblemIDsBinding,
                emptyMessage: "No research problems yet.",
                title: { $0.title },
                subtitle: { $0.status.rawValue },
                matches: { problem, q in problem.title.localizedCaseInsensitiveContains(q) }
            )
        }
        .sheet(isPresented: $showingGapPicker) {
            ResearchLinkPickerView(
                navTitle: "Link Research Gaps",
                items: allGaps,
                linkedIDs: linkedGapIDsBinding,
                emptyMessage: "No research gaps yet.",
                title: { $0.title },
                subtitle: { $0.gapType.rawValue },
                matches: { gap, q in gap.title.localizedCaseInsensitiveContains(q) }
            )
        }
        .sheet(isPresented: $showingPaperPicker) {
            ResearchLinkPickerView(
                navTitle: "Link Papers",
                items: allPapers,
                linkedIDs: linkedPaperIDsBinding,
                emptyMessage: "Your library is empty. Add papers first.",
                title: { $0.title },
                subtitle: { $0.authors },
                matches: { paper, q in
                    paper.title.localizedCaseInsensitiveContains(q) ||
                    paper.authors.localizedCaseInsensitiveContains(q)
                }
            )
        }
        .sheet(isPresented: $showingNotePicker) {
            ResearchLinkPickerView(
                navTitle: "Link Research Notes",
                items: allNotes,
                linkedIDs: linkedNoteIDsBinding,
                emptyMessage: "No research notes yet.",
                title: { $0.title },
                subtitle: { $0.noteType.rawValue },
                matches: { note, q in
                    note.title.localizedCaseInsensitiveContains(q) ||
                    note.content.localizedCaseInsensitiveContains(q)
                }
            )
        }
        .sheet(isPresented: $showingSetupEditor) {
            ExperimentSetupFormSheet(experiment: experiment) { result in
                updateSetup(result)
            }
        }
        .sheet(isPresented: $showingNewRunSheet) {
            ExperimentRunEditorView(run: nil) { result in
                createRun(result)
            }
        }
        .sheet(item: $editingRun) { run in
            ExperimentRunEditorView(run: run) { result in
                updateRun(run, with: result)
            }
        }
        .confirmationDialog(
            "Delete Run?",
            isPresented: Binding(
                get: { deletingRun != nil },
                set: { if !$0 { deletingRun = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Run", role: .destructive) {
                if let deletingRun { delete(run: deletingRun) }
            }
            Button("Cancel", role: .cancel) { deletingRun = nil }
        } message: {
            Text("This run and its metrics will be removed. The experiment and its other runs are not affected.")
        }
        .sheet(isPresented: $showingNewBaselineMetric) {
            MetricEditorView(navTitle: "Add Baseline Metric", initial: nil) { result in
                createBaselineMetric(result)
            }
        }
        .sheet(item: $editingBaselineMetric) { metric in
            MetricEditorView(
                navTitle: "Edit Baseline Metric",
                initial: MetricEditorResult(
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

    // MARK: Tab Bar

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ExperimentDetailTab.allCases, id: \.self) { tab in
                    RBChip(text: tab.rawValue, isSelected: selectedTab == tab) {
                        selectedTab = tab
                    }
                }
            }
            .rbResponsiveContentPadding([.horizontal])
        }
        .padding(.top, 16)
        .padding(.bottom, 14)
    }
    // MARK: - Overview Tab

    private var overviewTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                RB9DetailHeader(
                    title: experiment.name,
                    statusText: experiment.status.rawValue,
                    statusColor: rbExperimentStatusColor(experiment.status),
                    onEdit: onEdit,
                    onDelete: onDelete
                )

                RB9DetailSection(title: "Objective", text: experiment.objective)
                RB9DetailSection(title: "Hypothesis", text: experiment.hypothesis)
                RB9DetailSection(title: "Description", text: experiment.descriptionText)

                linkSection(
                    title: "Research Idea",
                    items: experiment.ideas,
                    label: { $0.title },
                    sublabel: { $0.status.rawValue },
                    onLink: { showingIdeaPicker = true },
                    onUnlink: { unlink(idea: $0) }
                )

                linkSection(
                    title: "Research Problem",
                    items: experiment.problems,
                    label: { $0.title },
                    sublabel: { $0.status.rawValue },
                    onLink: { showingProblemPicker = true },
                    onUnlink: { unlink(problem: $0) }
                )

                linkSection(
                    title: "Research Gap",
                    items: experiment.gaps,
                    label: { $0.title },
                    sublabel: { $0.gapType.rawValue },
                    onLink: { showingGapPicker = true },
                    onUnlink: { unlink(gap: $0) }
                )

                linkSection(
                    title: "Supporting Papers",
                    items: experiment.papers,
                    label: { $0.title },
                    sublabel: { $0.authors },
                    onLink: { showingPaperPicker = true },
                    onUnlink: { unlink(paper: $0) }
                )
            }
            .rbResponsiveContentPadding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RBColor.background)
    }

    private func linkSection<T: Identifiable>(
        title: String,
        items: [T],
        label: @escaping (T) -> String,
        sublabel: @escaping (T) -> String,
        onLink: @escaping () -> Void,
        onUnlink: @escaping (T) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            RB9LinkSectionHeader(title: title, onLink: onLink)

            if items.isEmpty {
                Text("None linked yet.")
                    .font(RBFont.secondary())
                    .foregroundStyle(RBColor.mutedText)
            } else {
                ForEach(items) { item in
                    RB9LinkRow(
                        title: label(item),
                        subtitle: sublabel(item),
                        onUnlink: { onUnlink(item) }
                    )
                }
            }
        }
    }


    // MARK: - Setup Tab

    private var setupTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Setup")
                        .font(RBFont.section(.semibold))
                        .foregroundStyle(RBColor.primaryText)

                    Spacer()

                    Button("Edit Setup") { showingSetupEditor = true }
                        .buttonStyle(RBGhostButtonStyle())
                }

                if setupIsEmpty {
                    RB9InlineEmptyNote(
                        icon: "slider.horizontal.3",
                        title: "No Setup Recorded Yet",
                        message: "Capture the dataset, model, training configuration and environment so this experiment stays reproducible."
                    )
                } else {
                    setupGroup(title: "Dataset") {
                        RB9FieldRow(label: "Dataset", value: experiment.dataset)
                        RB9FieldRow(label: "Version", value: experiment.datasetVersion)
                        RB9FieldRow(label: "Train / Val / Test Split", value: experiment.trainValidationTestSplit)
                    }

                    setupGroup(title: "Model") {
                        RB9FieldRow(label: "Model / Algorithm", value: experiment.model)
                        RB9FieldRow(label: "Framework", value: experiment.framework)
                    }

                    setupGroup(title: "Training") {
                        RB9FieldRow(label: "Batch Size", value: experiment.batchSize.map(String.init) ?? "")
                        RB9FieldRow(label: "Learning Rate", value: experiment.learningRate)
                        RB9FieldRow(label: "Epochs", value: experiment.epochs.map(String.init) ?? "")
                        RB9FieldRow(label: "Optimizer", value: experiment.optimizer)
                        RB9FieldRow(label: "Seed", value: experiment.seed.map(String.init) ?? "")
                    }

                    setupGroup(title: "Environment") {
                        RB9FieldRow(label: "Hardware", value: experiment.hardware)
                        RB9FieldRow(label: "Operating Environment", value: experiment.operatingEnvironment)
                    }

                    setupGroup(title: "Code") {
                        RB9FieldRow(label: "Repository / Path", value: experiment.codeRepository)
                    }
                }
            }
            .rbResponsiveContentPadding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RBColor.background)
    }

    private var setupIsEmpty: Bool {
        let fields = [
            experiment.dataset, experiment.datasetVersion, experiment.trainValidationTestSplit,
            experiment.model, experiment.framework, experiment.learningRate,
            experiment.optimizer, experiment.hardware, experiment.operatingEnvironment,
            experiment.codeRepository
        ]
        let hasText = fields.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let hasNumbers = experiment.batchSize != nil || experiment.epochs != nil || experiment.seed != nil
        return !hasText && !hasNumbers
    }

    private func setupGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RB9SectionLabel(text: title)
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .padding(12)
            .background(RBColor.card, in: RoundedRectangle(cornerRadius: RBRadius.field))
            .overlay(RoundedRectangle(cornerRadius: RBRadius.field).stroke(RBColor.border))
        }
    }


    // MARK: - Runs Tab

    private var runsTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Runs")
                    .font(RBFont.section(.semibold))
                    .foregroundStyle(RBColor.primaryText)

                Spacer()

                Button {
                    showingNewRunSheet = true
                } label: {
                    Label("Add Run", systemImage: "plus")
                }
                .buttonStyle(RBPrimaryButtonStyle())
            }
            .rbResponsiveContentPadding([.horizontal])
            .padding(.top, 16)
            .padding(.bottom, 12)

            if experiment.runs.isEmpty {
                RB9EmptyState(
                    icon: "arrow.triangle.2.circlepath",
                    title: "No Runs Yet",
                    message: "Add the first execution of this experiment to start recording seeds, configuration and metrics.",
                    actionTitle: "Add Run",
                    action: { showingNewRunSheet = true }
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.fetchRuns(for: experiment), id: \.id) { run in
                            runRow(run)
                        }
                    }
                    .rbResponsiveContentPadding([.horizontal])
                    .padding(.bottom, 16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RBColor.background)
    }

    private func runRow(_ run: ExperimentRun) -> some View {
        RBRow(action: { editingRun = run }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Run #\(run.runNumber)")
                        .font(RBFont.body(.semibold))
                        .foregroundStyle(RBColor.primaryText)

                    RB9StatusPill(text: run.status.rawValue, color: rbRunStatusColor(run.status))

                    if experiment.bestRunID == run.id {
                        RB9StatusPill(text: "Best Run", color: RBColor.accent)
                    }

                    Spacer()

                    Menu {
                        Button(experiment.bestRunID == run.id ? "Unmark as Best" : "Mark as Best") {
                            markBest(run, isBest: experiment.bestRunID != run.id)
                        }
                        Button("Delete Run", role: .destructive) {
                            deletingRun = run
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(RBColor.mutedText)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                HStack(spacing: 14) {
                    if let seed = run.seed {
                        Label("Seed \(seed)", systemImage: "die.face.5")
                    }
                    if let started = run.startedAt {
                        Label("Started \(started.formatted(date: .abbreviated, time: .omitted))", systemImage: "play")
                    }
                    if let completed = run.completedAt {
                        Label("Completed \(completed.formatted(date: .abbreviated, time: .omitted))", systemImage: "checkmark")
                    }
                }
                .font(RBFont.caption())
                .foregroundStyle(RBColor.secondaryText)

                if !run.metrics.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(run.metrics.prefix(4), id: \.id) { metric in
                            RB9StatusPill(text: "\(metric.name) \(rb9FormatMetric(metric))", color: RBColor.mutedText)
                        }
                        if run.metrics.count > 4 {
                            Text("+\(run.metrics.count - 4) more")
                                .font(RBFont.label())
                                .foregroundStyle(RBColor.mutedText)
                        }
                    }
                }
            }
        }
    }


    // MARK: - Results Tab

    private var resultsTab: some View {
        ExperimentResultsSection(
            experiment: experiment,
            onAddBaselineMetric: { showingNewBaselineMetric = true },
            onEditBaselineMetric: { editingBaselineMetric = $0 },
            onDeleteBaselineMetric: { deletingBaselineMetric = $0 },
            onSelectBestRun: { run in markBest(run, isBest: true) },
            onClearBestRun: { clearBest() },
            onSaveInterpretation: { interpretation, conclusion in
                saveResults(interpretation: interpretation, conclusion: conclusion)
            }
        )
    }


    // MARK: - Notes Tab

    private var notesTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                RB9LinkSectionHeader(title: "Linked Research Notes", onLink: { showingNotePicker = true })

                if experiment.notes.isEmpty {
                    RB9InlineEmptyNote(
                        icon: "note.text",
                        title: "No Notes Linked Yet",
                        message: "Link existing research notes to keep observations about this experiment in one place."
                    )
                } else {
                    ForEach(experiment.notes, id: \.id) { note in
                        VStack(alignment: .leading, spacing: 4) {
                            RB9LinkRow(
                                title: note.title,
                                subtitle: note.noteType.rawValue,
                                onUnlink: { unlink(note: note) }
                            )
                        }
                    }
                }
            }
            .rbResponsiveContentPadding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RBColor.background)
    }


    // MARK: - Actions: Overview Links

    private func unlink(idea: ResearchIdea) {
        act { try store.unlinkIdeaFromExperiment(idea, from: experiment) }
    }

    private func unlink(problem: ResearchProblem) {
        act { try store.unlinkProblemFromExperiment(problem, from: experiment) }
    }

    private func unlink(gap: ResearchGap) {
        act { try store.unlinkGapFromExperiment(gap, from: experiment) }
    }

    private func unlink(paper: PaperRecord) {
        act { try store.unlinkPaperFromExperiment(paper, from: experiment) }
    }

    private func unlink(note: ResearchNote) {
        act { try store.unlinkNoteFromExperiment(note, from: experiment) }
    }

    private var linkedIdeaIDsBinding: Binding<Set<ResearchIdea.ID>> {
        Binding(
            get: { Set(experiment.ideas.map { $0.id }) },
            set: { newValue in
                rb9ApplyLinks(
                    newIDs: newValue,
                    current: experiment.ideas,
                    all: allIdeas,
                    link: { try store.linkIdeaToExperiment($0, to: experiment) },
                    unlink: { try store.unlinkIdeaFromExperiment($0, from: experiment) },
                    onError: { errorMessage = $0 }
                )
            }
        )
    }

    private var linkedProblemIDsBinding: Binding<Set<ResearchProblem.ID>> {
        Binding(
            get: { Set(experiment.problems.map { $0.id }) },
            set: { newValue in
                rb9ApplyLinks(
                    newIDs: newValue,
                    current: experiment.problems,
                    all: allProblems,
                    link: { try store.linkProblemToExperiment($0, to: experiment) },
                    unlink: { try store.unlinkProblemFromExperiment($0, from: experiment) },
                    onError: { errorMessage = $0 }
                )
            }
        )
    }

    private var linkedGapIDsBinding: Binding<Set<ResearchGap.ID>> {
        Binding(
            get: { Set(experiment.gaps.map { $0.id }) },
            set: { newValue in
                rb9ApplyLinks(
                    newIDs: newValue,
                    current: experiment.gaps,
                    all: allGaps,
                    link: { try store.linkGapToExperiment($0, to: experiment) },
                    unlink: { try store.unlinkGapFromExperiment($0, from: experiment) },
                    onError: { errorMessage = $0 }
                )
            }
        )
    }

    private var linkedPaperIDsBinding: Binding<Set<PaperRecord.ID>> {
        Binding(
            get: { Set(experiment.papers.map { $0.id }) },
            set: { newValue in
                rb9ApplyLinks(
                    newIDs: newValue,
                    current: experiment.papers,
                    all: allPapers,
                    link: { try store.linkPaperToExperiment($0, to: experiment) },
                    unlink: { try store.unlinkPaperFromExperiment($0, from: experiment) },
                    onError: { errorMessage = $0 }
                )
            }
        )
    }

    private var linkedNoteIDsBinding: Binding<Set<ResearchNote.ID>> {
        Binding(
            get: { Set(experiment.notes.map { $0.id }) },
            set: { newValue in
                rb9ApplyLinks(
                    newIDs: newValue,
                    current: experiment.notes,
                    all: allNotes,
                    link: { try store.linkNoteToExperiment($0, to: experiment) },
                    unlink: { try store.unlinkNoteFromExperiment($0, from: experiment) },
                    onError: { errorMessage = $0 }
                )
            }
        )
    }


    // MARK: - Actions: Setup

    private func updateSetup(_ result: ExperimentSetupFormResult) {
        act {
            try store.updateExperimentSetup(
                experiment,
                dataset: result.dataset,
                datasetVersion: result.datasetVersion,
                model: result.model,
                framework: result.framework,
                hardware: result.hardware,
                operatingEnvironment: result.operatingEnvironment,
                codeRepository: result.codeRepository,
                trainValidationTestSplit: result.trainValidationTestSplit,
                seed: result.seed,
                batchSize: result.batchSize,
                learningRate: result.learningRate,
                epochs: result.epochs,
                optimizer: result.optimizer
            )
        }
    }


    // MARK: - Actions: Runs

    private func createRun(_ result: ExperimentRunFormResult) {
        act {
            let run = try store.createExperimentRun(
                for: experiment,
                status: result.status,
                startedAt: result.startedAt,
                completedAt: result.completedAt,
                seed: result.seed,
                configuration: result.configuration,
                notes: result.notes
            )
            for metric in result.metrics {
                try store.createMetric(
                    name: metric.name,
                    value: metric.value,
                    unit: metric.unit,
                    higherIsBetter: metric.higherIsBetter,
                    for: run
                )
            }
        }
    }

    private func updateRun(_ run: ExperimentRun, with result: ExperimentRunFormResult) {
        act {
            try store.updateExperimentRun(
                run,
                status: result.status,
                startedAt: result.startedAt,
                completedAt: result.completedAt,
                seed: result.seed,
                configuration: result.configuration,
                notes: result.notes
            )

            let existingIDs = Set(result.metrics.compactMap { $0.existingID })
            for metric in run.metrics where !existingIDs.contains(metric.id) {
                try store.deleteMetric(metric)
            }

            for metricResult in result.metrics {
                if let existingID = metricResult.existingID,
                   let existing = run.metrics.first(where: { $0.id == existingID }) {
                    try store.updateMetric(
                        existing,
                        name: metricResult.name,
                        value: metricResult.value,
                        unit: metricResult.unit,
                        higherIsBetter: metricResult.higherIsBetter
                    )
                } else {
                    try store.createMetric(
                        name: metricResult.name,
                        value: metricResult.value,
                        unit: metricResult.unit,
                        higherIsBetter: metricResult.higherIsBetter,
                        for: run
                    )
                }
            }
        }
    }

    private func delete(run: ExperimentRun) {
        act {
            try store.deleteExperimentRun(run)
            deletingRun = nil
        }
    }

    private func markBest(_ run: ExperimentRun, isBest: Bool) {
        act {
            try store.setBestRun(isBest ? run : nil, for: experiment)
        }
    }

    private func clearBest() {
        act {
            try store.setBestRun(nil, for: experiment)
        }
    }


    // MARK: - Actions: Results

    private func createBaselineMetric(_ result: MetricEditorResult) {
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

    private func saveResults(interpretation: String, conclusion: String) {
        act {
            try store.updateExperimentResults(experiment, interpretation: interpretation, conclusion: conclusion)
        }
    }


    // MARK: - Helper

    private func act(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}


// MARK: - Experiment Setup Form

struct ExperimentSetupFormResult {
    var dataset: String
    var datasetVersion: String
    var model: String
    var framework: String
    var hardware: String
    var operatingEnvironment: String
    var codeRepository: String
    var trainValidationTestSplit: String
    var seed: Int?
    var batchSize: Int?
    var learningRate: String
    var epochs: Int?
    var optimizer: String
}

struct ExperimentSetupFormSheet: View {
    let experiment: Experiment
    let onSave: (ExperimentSetupFormResult) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var dataset: String
    @State private var datasetVersion: String
    @State private var model: String
    @State private var framework: String
    @State private var hardware: String
    @State private var operatingEnvironment: String
    @State private var codeRepository: String
    @State private var trainValidationTestSplit: String
    @State private var seedText: String
    @State private var batchSizeText: String
    @State private var learningRate: String
    @State private var epochsText: String
    @State private var optimizer: String

    init(experiment: Experiment, onSave: @escaping (ExperimentSetupFormResult) -> Void) {
        self.experiment = experiment
        self.onSave = onSave
        _dataset = State(initialValue: experiment.dataset)
        _datasetVersion = State(initialValue: experiment.datasetVersion)
        _model = State(initialValue: experiment.model)
        _framework = State(initialValue: experiment.framework)
        _hardware = State(initialValue: experiment.hardware)
        _operatingEnvironment = State(initialValue: experiment.operatingEnvironment)
        _codeRepository = State(initialValue: experiment.codeRepository)
        _trainValidationTestSplit = State(initialValue: experiment.trainValidationTestSplit)
        _seedText = State(initialValue: experiment.seed.map(String.init) ?? "")
        _batchSizeText = State(initialValue: experiment.batchSize.map(String.init) ?? "")
        _learningRate = State(initialValue: experiment.learningRate)
        _epochsText = State(initialValue: experiment.epochs.map(String.init) ?? "")
        _optimizer = State(initialValue: experiment.optimizer)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Experiment Setup")
                    .font(RBFont.detail(.semibold))
                    .foregroundStyle(RBColor.primaryText)

                Spacer()

                Button("Cancel") { dismiss() }
                    .buttonStyle(RBGhostButtonStyle())

                Button("Save") {
                    onSave(
                        ExperimentSetupFormResult(
                            dataset: dataset,
                            datasetVersion: datasetVersion,
                            model: model,
                            framework: framework,
                            hardware: hardware,
                            operatingEnvironment: operatingEnvironment,
                            codeRepository: codeRepository,
                            trainValidationTestSplit: trainValidationTestSplit,
                            seed: Int(seedText.trimmingCharacters(in: .whitespaces)),
                            batchSize: Int(batchSizeText.trimmingCharacters(in: .whitespaces)),
                            learningRate: learningRate,
                            epochs: Int(epochsText.trimmingCharacters(in: .whitespaces)),
                            optimizer: optimizer
                        )
                    )
                    dismiss()
                }
                .buttonStyle(RBPrimaryButtonStyle())
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Divider().overlay(RBColor.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    RB9SectionLabel(text: "Dataset")
                    RB9TextField(label: "Dataset", text: $dataset, placeholder: "e.g. CIFAR-100")
                    RB9TextField(label: "Dataset Version", text: $datasetVersion, placeholder: "e.g. v2, 2024-06 snapshot")
                    RB9TextField(label: "Train / Val / Test Split", text: $trainValidationTestSplit, placeholder: "e.g. 80 / 10 / 10")

                    Divider().overlay(RBColor.border)

                    RB9SectionLabel(text: "Model")
                    RB9TextField(label: "Model / Algorithm", text: $model, placeholder: "e.g. Vision Transformer")
                    RB9TextField(label: "Framework", text: $framework, placeholder: "e.g. PyTorch 2.3")

                    Divider().overlay(RBColor.border)

                    RB9SectionLabel(text: "Training")
                    RB9TextField(label: "Batch Size", text: $batchSizeText, placeholder: "e.g. 256")
                    RB9TextField(label: "Learning Rate", text: $learningRate, placeholder: "e.g. 1e-4")
                    RB9TextField(label: "Epochs", text: $epochsText, placeholder: "e.g. 100")
                    RB9TextField(label: "Optimizer", text: $optimizer, placeholder: "e.g. AdamW, cosine schedule")
                    RB9TextField(label: "Seed", text: $seedText, placeholder: "e.g. 42")

                    Divider().overlay(RBColor.border)

                    RB9SectionLabel(text: "Environment")
                    RB9TextField(label: "Hardware", text: $hardware, placeholder: "e.g. 4x A100 80GB")
                    RB9TextField(label: "Operating Environment", text: $operatingEnvironment, placeholder: "e.g. CUDA 12.4, Ubuntu 22.04")

                    Divider().overlay(RBColor.border)

                    RB9SectionLabel(text: "Code")
                    RB9TextField(label: "Repository / Path", text: $codeRepository, placeholder: "e.g. github.com/you/repo @ commit abc123")
                }
                .padding(24)
            }
        }
        .frame(width: 560, height: 700)
        .background(RBColor.elevatedSurface)
    }
}


// MARK: - Results Section (shared with ResultsView)

struct ExperimentResultsSection: View {

    let experiment: Experiment
    let onAddBaselineMetric: () -> Void
    let onEditBaselineMetric: (BaselineMetric) -> Void
    let onDeleteBaselineMetric: (BaselineMetric) -> Void
    let onSelectBestRun: (ExperimentRun) -> Void
    let onClearBestRun: () -> Void
    let onSaveInterpretation: (String, String) -> Void

    @State private var interpretation: String = ""
    @State private var conclusion: String = ""
    @State private var showingBestRunPicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if experiment.runs.isEmpty {
                    RB9InlineEmptyNote(
                        icon: "chart.bar",
                        title: "No Results Recorded Yet",
                        message: "Complete a run and record its metrics to begin analysis."
                    )
                } else {
                    bestRunSection
                    baselineSection
                    comparisonSection
                    interpretationSection
                }
            }
            .rbResponsiveContentPadding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RBColor.background)
        .onAppear {
            interpretation = experiment.resultsInterpretation
            conclusion = experiment.resultsConclusion
        }
        .sheet(isPresented: $showingBestRunPicker) {
            bestRunPickerSheet
        }
    }

    // MARK: Best Run

    private var bestRunSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                RB9SectionLabel(text: "Best Run")
                Spacer()
                Button(experiment.bestRun == nil ? "Choose Best Run" : "Change") {
                    showingBestRunPicker = true
                }
                .buttonStyle(.plain)
                .rbHover(cornerRadius: RBRadius.field)
                .foregroundStyle(RBColor.accent)
                .font(RBFont.caption(.medium))
            }

            if let best = experiment.bestRun {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Run #\(best.runNumber)")
                            .font(RBFont.body(.semibold))
                            .foregroundStyle(RBColor.primaryText)

                        Spacer()

                        Button("Clear") { onClearBestRun() }
                            .buttonStyle(.plain)
                            .rbHover(cornerRadius: RBRadius.field)
                            .font(RBFont.caption())
                            .foregroundStyle(RBColor.mutedText)
                    }

                    if best.metrics.isEmpty {
                        Text("No metrics recorded on this run yet.")
                            .font(RBFont.secondary())
                            .foregroundStyle(RBColor.mutedText)
                    } else {
                        HStack(spacing: 6) {
                            ForEach(best.metrics, id: \.id) { metric in
                                RB9StatusPill(text: "\(metric.name) \(rb9FormatMetric(metric))", color: RBColor.mutedText)
                            }
                        }
                    }
                }
                .padding(12)
                .background(RBColor.card, in: RoundedRectangle(cornerRadius: RBRadius.field))
                .overlay(RoundedRectangle(cornerRadius: RBRadius.field).stroke(RBColor.border))
            } else {
                Text("The researcher chooses which run counts as best — ResearchBase never picks this automatically.")
                    .font(RBFont.secondary())
                    .foregroundStyle(RBColor.mutedText)
            }
        }
    }

    private var bestRunPickerSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose Best Run")
                    .font(RBFont.section(.semibold))
                    .foregroundStyle(RBColor.primaryText)
                Spacer()
                Button("Done") { showingBestRunPicker = false }
                    .buttonStyle(RBPrimaryButtonStyle())
            }
            .padding(20)

            Divider().overlay(RBColor.border)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(experiment.runs.sorted { $0.runNumber < $1.runNumber }, id: \.id) { run in
                        Button {
                            onSelectBestRun(run)
                            showingBestRunPicker = false
                        } label: {
                            HStack {
                                Text("Run #\(run.runNumber)")
                                    .font(RBFont.body(.medium))
                                    .foregroundStyle(RBColor.primaryText)
                                Spacer()
                                if experiment.bestRunID == run.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(RBColor.accent)
                                }
                            }
                            .padding(12)
                            .background(RBColor.card, in: RoundedRectangle(cornerRadius: RBRadius.field))
                            .overlay(RoundedRectangle(cornerRadius: RBRadius.field).stroke(RBColor.border))
                        }
                        .buttonStyle(.plain)
                        .rbHover(cornerRadius: RBRadius.field)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 420, height: 480)
        .background(RBColor.elevatedSurface)
    }

    // MARK: Baseline

    private var baselineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            RB9LinkSectionHeader(title: "Baseline", onLink: onAddBaselineMetric)

            if experiment.baselineMetrics.isEmpty {
                Text("No baseline recorded yet. Add a baseline value per metric to enable the comparison table below.")
                    .font(RBFont.secondary())
                    .foregroundStyle(RBColor.mutedText)
            } else {
                ForEach(experiment.baselineMetrics, id: \.id) { metric in
                    HStack {
                        Text(metric.name)
                            .font(RBFont.secondary(.medium))
                            .foregroundStyle(RBColor.primaryText)
                        Spacer()
                        Text(rb9FormatBaseline(metric))
                            .font(RBFont.secondary())
                            .foregroundStyle(RBColor.secondaryText)
                        Button {
                            onEditBaselineMetric(metric)
                        } label: {
                            Image(systemName: "pencil")
                                .foregroundStyle(RBColor.mutedText)
                        }
                        .buttonStyle(.plain)
                        .rbHover(cornerRadius: RBRadius.field)
                        Button {
                            onDeleteBaselineMetric(metric)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(RBColor.mutedText)
                        }
                        .buttonStyle(.plain)
                        .rbHover(cornerRadius: RBRadius.field)
                    }
                    .padding(10)
                    .background(RBColor.card, in: RoundedRectangle(cornerRadius: RBRadius.field))
                    .overlay(RoundedRectangle(cornerRadius: RBRadius.field).stroke(RBColor.border))
                }
            }
        }
    }

    // MARK: Comparison

    private var comparisonSection: some View {
        Group {
            if !experiment.baselineMetrics.isEmpty, let best = experiment.bestRun {
                VStack(alignment: .leading, spacing: 10) {
                    RB9SectionLabel(text: "Comparison")

                    VStack(spacing: 0) {
                        comparisonHeaderRow

                        ForEach(experiment.baselineMetrics, id: \.id) { baseline in
                            if let current = best.metrics.first(where: {
                                $0.name.localizedCaseInsensitiveCompare(baseline.name) == .orderedSame
                            }) {
                                comparisonRow(baseline: baseline, current: current)
                            }
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: RBRadius.field).stroke(RBColor.border))

                    Text("Differences are shown as recorded — the researcher decides what they mean.")
                        .font(RBFont.label())
                        .foregroundStyle(RBColor.mutedText)
                }
            }
        }
    }

    private var comparisonHeaderRow: some View {
        HStack {
            Text("Metric").frame(width: 120, alignment: .leading)
            Text("Baseline").frame(maxWidth: .infinity, alignment: .leading)
            Text("Best Run").frame(maxWidth: .infinity, alignment: .leading)
            Text("Difference").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(RBFont.label(.semibold))
        .foregroundStyle(RBColor.mutedText)
        .padding(10)
        .background(RBColor.surface)
    }

    private func comparisonRow(baseline: BaselineMetric, current: RunMetric) -> some View {
        HStack {
            Text(baseline.name)
                .frame(width: 120, alignment: .leading)
                .font(RBFont.secondary(.medium))
                .foregroundStyle(RBColor.primaryText)

            Text(rb9FormatBaseline(baseline))
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(RBFont.secondary())
                .foregroundStyle(RBColor.secondaryText)

            Text(rb9FormatMetric(current))
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(RBFont.secondary())
                .foregroundStyle(RBColor.secondaryText)

            Text(rb9FormatDifference(baseline: baseline.value, current: current.value, unit: baseline.unit))
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(RBFont.secondary(.medium))
                .foregroundStyle(RBColor.primaryText)
        }
        .padding(10)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(RBColor.border), alignment: .top)
    }

    // MARK: Interpretation & Conclusion

    private var interpretationSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            RB9TextEditor(
                label: "Interpretation — what do these results suggest?",
                text: $interpretation,
                minHeight: 90
            )

            RB9TextEditor(
                label: "Conclusion",
                text: $conclusion,
                minHeight: 90
            )

            HStack {
                Spacer()
                Button("Save") {
                    onSaveInterpretation(interpretation, conclusion)
                }
                .buttonStyle(RBPrimaryButtonStyle())
                .disabled(
                    interpretation == experiment.resultsInterpretation &&
                    conclusion == experiment.resultsConclusion
                )
            }
        }
    }
}
