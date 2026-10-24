//
//  ExperimentsView.swift
//  ResearchBase
//
//  Phase 9 — Experiments & Results
//
//  The main Experiments workspace: a searchable, filterable,
//  sortable list of experiments on the left and a structured detail
//  workspace (ExperimentDetailView, with Overview / Setup / Runs /
//  Results / Notes tabs) on the right. Mirrors the manual-HStack
//  list/detail split established in Literature Review and Research
//  Ideas (Phase 7/8) rather than a nested NavigationSplitView.
//

import SwiftUI
import SwiftData

// MARK: - Sort Option

enum ExperimentSortOption: String, CaseIterable, Identifiable {
    case recentlyUpdated = "Recently Updated"
    case recentlyCreated = "Recently Created"
    case nameAZ = "Name A–Z"
    case status = "Status"

    var id: String { rawValue }
}

// MARK: - Status Colors

func rbExperimentStatusColor(_ status: ExperimentStatus) -> Color {
    switch status {
    case .draft: return RBColor.mutedText
    case .planned: return RBColor.warning
    case .running: return RBColor.warning
    case .completed: return RBColor.success
    case .analyzing: return RBColor.warning
    case .archived: return RBColor.mutedText
    }
}

func rbRunStatusColor(_ status: ExperimentRunStatus) -> Color {
    switch status {
    case .planned: return RBColor.mutedText
    case .running: return RBColor.warning
    case .completed: return RBColor.success
    case .failed: return RBColor.error
    }
}


// MARK: - Root View

struct ExperimentsView: View {

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var router: NavigationRouter

    @Query(sort: [SortDescriptor(\Experiment.updatedAt, order: .reverse)])
    private var allExperiments: [Experiment]

    @Query(sort: [SortDescriptor(\ResearchIdea.updatedAt, order: .reverse)])
    private var allIdeas: [ResearchIdea]

    @Query(sort: [SortDescriptor(\ResearchProblem.updatedAt, order: .reverse)])
    private var allProblems: [ResearchProblem]

    @Query(sort: [SortDescriptor(\ResearchGap.updatedAt, order: .reverse)])
    private var allGaps: [ResearchGap]

    @Query(sort: [SortDescriptor(\PaperRecord.addedAt, order: .reverse)])
    private var allPapers: [PaperRecord]

    @Query(sort: [SortDescriptor(\ResearchNote.updatedAt, order: .reverse)])
    private var allNotes: [ResearchNote]

    @State private var searchText = ""
    @State private var statusFilter: ExperimentStatus?
    @State private var sortOption: ExperimentSortOption = .recentlyUpdated

    @State private var selectedExperimentID: UUID?
    @State private var showingNewSheet = false
    @State private var editingExperiment: Experiment?
    @State private var deletingExperiment: Experiment?
    @State private var errorMessage: String?

    @State private var relatedGroups: [ResearchDataStore.RelatedGroup] = []

    private var store: ResearchDataStore {
        ResearchDataStore(modelContext: modelContext)
    }

    private var filteredExperiments: [Experiment] {
        var result = allExperiments

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter { experiment in
                experiment.name.localizedCaseInsensitiveContains(query) ||
                experiment.dataset.localizedCaseInsensitiveContains(query) ||
                experiment.model.localizedCaseInsensitiveContains(query) ||
                experiment.ideas.contains { $0.title.localizedCaseInsensitiveContains(query) }
            }
        }

        if let statusFilter {
            result = result.filter { $0.status == statusFilter }
        }

        switch sortOption {
        case .recentlyUpdated:
            return result.sorted { $0.updatedAt > $1.updatedAt }
        case .recentlyCreated:
            return result.sorted { $0.createdAt > $1.createdAt }
        case .nameAZ:
            return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .status:
            return result.sorted { $0.status.rawValue < $1.status.rawValue }
        }
    }

    private var selectedExperiment: Experiment? {
        guard let selectedExperimentID else { return nil }
        return allExperiments.first { $0.id == selectedExperimentID }
    }

    var body: some View {
        RBMasterDetail(masterMin: 240, masterIdeal: 340) {
            listPane
        } detail: {
            Group {
                if let selectedExperiment {
                    VStack(spacing: 0) {
                        ExperimentDetailView(
                            experiment: selectedExperiment,
                            allIdeas: allIdeas,
                            allProblems: allProblems,
                            allGaps: allGaps,
                            allPapers: allPapers,
                            allNotes: allNotes,
                            onEdit: { editingExperiment = selectedExperiment },
                            onDelete: { deletingExperiment = selectedExperiment }
                        )

                        RelatedResearchDrawer(
                            groups: relatedGroups,
                            onNavigate: { router.open($0) }
                        )
                    }
                    // Forces SwiftUI to treat each experiment's detail
                    // pane as a distinct view identity, so its internal
                    // @State (selected tab, open sheets) resets instead
                    // of leaking from the previously selected experiment.
                    .id(selectedExperiment.id)
                } else {
                    RB9DetailPlaceholder(
                        icon: "flask",
                        text: "Select an experiment to see its details."
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RBColor.background)
        .onAppear {
            selectFirstIfNeeded()
            consumeQuickAdd()
        }
        .onChange(of: router.createRequestCount) { consumeQuickAdd() }
        .onChange(of: allExperiments.count) { selectFirstIfNeeded() }
        .task(id: selectedExperiment?.id) {
            guard let experiment = selectedExperiment else {
                relatedGroups = []
                return
            }
            loadRelated(experiment)
        }
        .onChange(of: router.pendingTarget) { _, target in
            if case .experiment(let id) = target {
                selectedExperimentID = id
                router.pendingTarget = nil
            }
        }
        .sheet(isPresented: $showingNewSheet) {
            ExperimentFormSheet(experiment: nil) { result in
                createExperiment(result)
            }
        }
        .sheet(item: $editingExperiment) { experiment in
            ExperimentFormSheet(experiment: experiment) { result in
                updateExperiment(experiment, with: result)
            }
        }
        .confirmationDialog(
            "Delete Experiment?",
            isPresented: Binding(
                get: { deletingExperiment != nil },
                set: { if !$0 { deletingExperiment = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Experiment", role: .destructive) {
                if let deletingExperiment {
                    delete(deletingExperiment)
                }
            }
            Button("Cancel", role: .cancel) { deletingExperiment = nil }
        } message: {
            Text("Its runs and metrics will be removed. Linked research ideas, problems, gaps, papers and notes will not be deleted — only this experiment is removed.")
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

    // MARK: List Pane

    private var listPane: some View {
        VStack(spacing: 0) {
            RBListPaneHeader(
                title: "Experiments",
                subtitle: RBListPaneMetrics.count(allExperiments.count, "experiment")
            ) {
                Button {
                    showingNewSheet = true
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(RBPrimaryButtonStyle())
                .help("New Experiment")
            }

            RBSearchField(placeholder: "Search experiments...", text: $searchText)
                .rbListPaneInset()

            HStack(spacing: 8) {
                rb9FilterMenu(
                    label: statusFilter?.rawValue ?? "Status",
                    selection: $statusFilter,
                    allCases: ExperimentStatus.allCases
                )
                Spacer()
                rb9SortMenu(selection: $sortOption, allCases: ExperimentSortOption.allCases)
            }
            .rbListPaneInset(bottom: 12)

            Divider().overlay(RBColor.border)

            if allExperiments.isEmpty {
                RB9EmptyState(
                    icon: "flask",
                    title: "No Experiments Yet",
                    message: "Turn a research idea into a reproducible experiment — dataset, model, runs and results, all in one place.",
                    actionTitle: "Create Experiment",
                    action: { showingNewSheet = true }
                )
            } else if filteredExperiments.isEmpty {
                noResultsState
            } else {
                RBListColumn {
                    ForEach(filteredExperiments, id: \.id) { experiment in
                        RB9RowCard(
                            isSelected: selectedExperimentID == experiment.id,
                            action: { selectedExperimentID = experiment.id }
                        ) {
                            experimentRowContent(experiment)
                        }
                    }
                }
            }
        }
        .rbListPaneBackground()
    }

    private var noResultsState: some View {
        VStack {
            Spacer()
            Text("No experiments match your search or filters.")
                .font(RBFont.secondary())
                .foregroundStyle(RBColor.mutedText)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func experimentRowContent(_ experiment: Experiment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text(experiment.name)
                    .font(RBFont.body(.medium))
                    .foregroundStyle(RBColor.primaryText)
                    .lineLimit(2)

                Spacer(minLength: 8)

                RB9StatusPill(text: experiment.status.rawValue, color: rbExperimentStatusColor(experiment.status))
            }

            if !experiment.dataset.isEmpty {
                RB9StatusPill(text: experiment.dataset, color: RBColor.mutedText)
            }

            if let idea = experiment.ideas.first {
                Text("Idea: \(idea.title)")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)
                    .lineLimit(1)
            } else if !experiment.model.isEmpty {
                Text("Model: \(experiment.model)")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)
                    .lineLimit(1)
            }

            HStack(spacing: 12) {
                Label(
                    "\(experiment.runs.count) run\(experiment.runs.count == 1 ? "" : "s")",
                    systemImage: "arrow.triangle.2.circlepath"
                )

                if let metricName = experiment.allMetricNames.first,
                   let best = experiment.bestValue(forMetricNamed: metricName) {
                    Label("Best \(best.name) \(rb9FormatMetric(best))", systemImage: "star")
                        .lineLimit(1)
                }
            }
            .font(RBFont.label())
            .foregroundStyle(RBColor.mutedText)

            Text("Updated \(experiment.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                .font(RBFont.label())
                .foregroundStyle(RBColor.mutedText)
        }
    }

    // MARK: Actions

    /// Phase 14 — Quick Add → Experiment. Consumes ONLY .experiment,
    /// opens the existing New Experiment sheet, then clears the request.
    private func consumeQuickAdd() {
        guard router.pendingCreate == .experiment else { return }
        router.pendingCreate = nil
        showingNewSheet = true
    }

    private func selectFirstIfNeeded() {
        if selectedExperimentID == nil {
            selectedExperimentID = allExperiments.first?.id
        }
    }

    private func loadRelated(_ experiment: Experiment) {
        do {
            relatedGroups = try store.relatedResearch(for: experiment)
        } catch {
            relatedGroups = []
        }
    }

    private func createExperiment(_ result: ExperimentFormResult) {
        do {
            let experiment = try store.createExperiment(
                name: result.name,
                status: result.status,
                objective: result.objective,
                hypothesis: result.hypothesis,
                description: result.description
            )
            selectedExperimentID = experiment.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateExperiment(_ experiment: Experiment, with result: ExperimentFormResult) {
        do {
            try store.updateExperiment(
                experiment,
                name: result.name,
                status: result.status,
                objective: result.objective,
                hypothesis: result.hypothesis,
                description: result.description
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ experiment: Experiment) {
        do {
            if selectedExperimentID == experiment.id {
                selectedExperimentID = nil
            }
            try store.deleteExperiment(experiment)
            deletingExperiment = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}


// MARK: - Experiment Form (Overview fields)

struct ExperimentFormResult {
    var name: String
    var status: ExperimentStatus
    var objective: String
    var hypothesis: String
    var description: String
}

struct ExperimentFormSheet: View {
    let experiment: Experiment?
    let onSave: (ExperimentFormResult) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var status: ExperimentStatus
    @State private var objective: String
    @State private var hypothesis: String
    @State private var description: String

    init(experiment: Experiment?, onSave: @escaping (ExperimentFormResult) -> Void) {
        self.experiment = experiment
        self.onSave = onSave
        _name = State(initialValue: experiment?.name ?? "")
        _status = State(initialValue: experiment?.status ?? .draft)
        _objective = State(initialValue: experiment?.objective ?? "")
        _hypothesis = State(initialValue: experiment?.hypothesis ?? "")
        _description = State(initialValue: experiment?.descriptionText ?? "")
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(experiment == nil ? "New Experiment" : "Edit Experiment")
                    .font(RBFont.detail(.semibold))
                    .foregroundStyle(RBColor.primaryText)

                Spacer()

                Button("Cancel") { dismiss() }
                    .buttonStyle(RBGhostButtonStyle())

                Button("Save") {
                    onSave(
                        ExperimentFormResult(
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            status: status,
                            objective: objective,
                            hypothesis: hypothesis,
                            description: description
                        )
                    )
                    dismiss()
                }
                .buttonStyle(RBPrimaryButtonStyle())
                .disabled(!isValid)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Divider().overlay(RBColor.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    RB9TextField(label: "Name", text: $name, placeholder: "e.g. Transformer Ablation Study")

                    VStack(alignment: .leading, spacing: 6) {
                        RB9SectionLabel(text: "Status")

                        Picker("", selection: $status) {
                            ForEach(ExperimentStatus.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }

                    RB9TextEditor(label: "Objective — what problem or question?", text: $objective, minHeight: 70)
                    RB9TextEditor(label: "Hypothesis — what idea is being tested?", text: $hypothesis, minHeight: 70)
                    RB9TextEditor(label: "Description", text: $description, minHeight: 90)
                }
                .padding(24)
            }
        }
        .frame(width: 560, height: 640)
        .background(RBColor.elevatedSurface)
    }
}
