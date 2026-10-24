//
//  ProjectsView.swift
//  ResearchBase
//
//  Phase 11 — Dashboard + Research Workflow / Projects
//
//  The main Projects workspace: a searchable, filterable, sortable
//  list of projects on the left and ProjectDetailView on the right.
//  Mirrors the manual-HStack list/detail split established in
//  Literature Review, Research Ideas and Experiments (Phase 7/8/9)
//  rather than a nested NavigationSplitView.
//
//  A Project is a pure organizational container — creating, editing
//  or deleting one never creates, modifies or deletes any linked
//  PaperRecord, ResearchNote, LiteratureFinding, ResearchGap,
//  ResearchProblem, ResearchIdea, Experiment or WritingDocument.
//
//  Phase 12 — adds deep-link support (NavigationRouter) so search
//  results and Related Research rows can open a specific project.
//

import SwiftUI
import SwiftData

// MARK: - Sort Option

enum ProjectSortOption: String, CaseIterable, Identifiable {
    case recentlyUpdated = "Recently Updated"
    case recentlyCreated = "Recently Created"
    case nameAZ = "Name A–Z"
    case status = "Status"

    var id: String { rawValue }
}


// MARK: - Root View

struct ProjectsView: View {

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var router: NavigationRouter

    @Query(sort: [SortDescriptor(\ResearchProject.updatedAt, order: .reverse)])
    private var allProjects: [ResearchProject]

    @Query(sort: [SortDescriptor(\PaperRecord.addedAt, order: .reverse)])
    private var allPapers: [PaperRecord]

    @Query(sort: [SortDescriptor(\ResearchNote.updatedAt, order: .reverse)])
    private var allNotes: [ResearchNote]

    @Query(sort: [SortDescriptor(\LiteratureFinding.updatedAt, order: .reverse)])
    private var allFindings: [LiteratureFinding]

    @Query(sort: [SortDescriptor(\ResearchGap.updatedAt, order: .reverse)])
    private var allGaps: [ResearchGap]

    @Query(sort: [SortDescriptor(\ResearchProblem.updatedAt, order: .reverse)])
    private var allProblems: [ResearchProblem]

    @Query(sort: [SortDescriptor(\ResearchIdea.updatedAt, order: .reverse)])
    private var allIdeas: [ResearchIdea]

    @Query(sort: [SortDescriptor(\Experiment.updatedAt, order: .reverse)])
    private var allExperiments: [Experiment]

    @Query(sort: [SortDescriptor(\WritingDocument.updatedAt, order: .reverse)])
    private var allWritingDocuments: [WritingDocument]

    @State private var searchText = ""
    @State private var statusFilter: ResearchProjectStatus?
    @State private var sortOption: ProjectSortOption = .recentlyUpdated

    @State private var selectedProjectID: UUID?
    @State private var showingNewSheet = false
    @State private var editingProject: ResearchProject?
    @State private var deletingProject: ResearchProject?
    @State private var errorMessage: String?

    private var store: ResearchDataStore {
        ResearchDataStore(modelContext: modelContext)
    }

    private var filteredProjects: [ResearchProject] {
        var result = allProjects

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter { project in
                project.name.localizedCaseInsensitiveContains(query) ||
                project.descriptionText.localizedCaseInsensitiveContains(query)
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

    private var selectedProject: ResearchProject? {
        guard let selectedProjectID else { return nil }
        return allProjects.first { $0.id == selectedProjectID }
    }

    var body: some View {
        RBMasterDetail(masterMin: 220, masterIdeal: 320) {
            listPane
        } detail: {
            Group {
                if let selectedProject {
                    ProjectDetailView(
                        project: selectedProject,
                        allPapers: allPapers,
                        allNotes: allNotes,
                        allFindings: allFindings,
                        allGaps: allGaps,
                        allProblems: allProblems,
                        allIdeas: allIdeas,
                        allExperiments: allExperiments,
                        allWritingDocuments: allWritingDocuments,
                        onEdit: { editingProject = selectedProject },
                        onDelete: { deletingProject = selectedProject }
                    )
                    // Forces SwiftUI to treat each project's detail
                    // pane as a distinct view identity, so its
                    // internal @State (open sheets, etc.) resets
                    // instead of leaking from the previously
                    // selected project.
                    .id(selectedProject.id)
                } else {
                    RB9DetailPlaceholder(
                        icon: "square.grid.2x2",
                        text: "Select a project to see its details."
                    )
                }
            }
            .frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RBColor.background)
        .onAppear {
            consumePendingTarget()
            selectFirstIfNeeded()
            consumeQuickAdd()
        }
        .onChange(of: allProjects.count) { selectFirstIfNeeded() }
        .onChange(of: router.pendingTarget) { consumePendingTarget() }
        .onChange(of: router.createRequestCount) { consumeQuickAdd() }
        .sheet(isPresented: $showingNewSheet) {
            ProjectFormSheet(project: nil) { result in
                createProject(result)
            }
        }
        .sheet(item: $editingProject) { project in
            ProjectFormSheet(project: project) { result in
                updateProject(project, with: result)
            }
        }
        .confirmationDialog(
            "Delete this Project?",
            isPresented: Binding(
                get: { deletingProject != nil },
                set: { if !$0 { deletingProject = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Project", role: .destructive) {
                if let deletingProject {
                    delete(deletingProject)
                }
            }
            Button("Cancel", role: .cancel) { deletingProject = nil }
        } message: {
            Text("“\(deletingProject?.name ?? "This project")” will be removed. Nothing inside the project is deleted — linked papers, notes, findings, gaps, problems, ideas, experiments and writing documents are never deleted.")
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
                title: "Projects",
                subtitle: RBListPaneMetrics.count(allProjects.count, "project")
            ) {
                Button {
                    showingNewSheet = true
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(RBPrimaryButtonStyle())
                .help("New Project")
            }

            RBSearchField(placeholder: "Search projects...", text: $searchText)
                .rbListPaneInset()

            HStack(spacing: 8) {
                rb9FilterMenu(
                    label: statusFilter?.rawValue ?? "Status",
                    selection: $statusFilter,
                    allCases: ResearchProjectStatus.allCases
                )
                Spacer()
                rb9SortMenu(selection: $sortOption, allCases: ProjectSortOption.allCases)
            }
            .rbListPaneInset(bottom: 12)

            Divider().overlay(RBColor.border)

            if allProjects.isEmpty {
                RB9EmptyState(
                    icon: "square.grid.2x2",
                    title: "No Projects Yet",
                    message: "Group papers, notes, findings, gaps, problems, ideas, experiments and writing into one organized research project.",
                    actionTitle: "Create Project",
                    action: { showingNewSheet = true }
                )
            } else if filteredProjects.isEmpty {
                noResultsState
            } else {
                RBListColumn {
                    ForEach(filteredProjects, id: \.id) { project in
                        RB9RowCard(
                            isSelected: selectedProjectID == project.id,
                            action: { selectedProjectID = project.id }
                        ) {
                            projectRowContent(project)
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
            Text("No projects match your search or filters.")
                .font(RBFont.secondary())
                .foregroundStyle(RBColor.mutedText)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func projectRowContent(_ project: ResearchProject) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text(project.name)
                    .font(RBFont.body(.medium))
                    .foregroundStyle(RBColor.primaryText)
                    .lineLimit(2)

                Spacer(minLength: 8)

                RB9StatusPill(text: project.status.rawValue, color: rbProjectStatusColor(project.status))
            }

            
            if !project.descriptionText.isEmpty {
                Text(project.descriptionText)
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)
                    .lineLimit(1)
            }

            Label(
                "\(project.totalLinkedCount) linked item\(project.totalLinkedCount == 1 ? "" : "s")",
                systemImage: "link"
            )
            .font(RBFont.label())
            .foregroundStyle(RBColor.mutedText)

            Text("Updated \(project.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                .font(RBFont.label())
                .foregroundStyle(RBColor.mutedText)
        }
    }

    // MARK: Actions

    private func selectFirstIfNeeded() {
        if selectedProjectID == nil {
            selectedProjectID = allProjects.first?.id
        }
    }

    /// Phase 12 — if search or a Related Research row asked to open a
    /// specific project, select it and clear the request so it is
    /// never re-applied. Called on appear as well as on change,
    /// because ContentView sets the target *before* this screen
    /// exists when navigating here from another screen.
    private func consumePendingTarget() {
        if case .project(let id) = router.pendingTarget {
            searchText = ""
            statusFilter = nil
            selectedProjectID = id
            router.pendingTarget = nil
        }
    }

    /// Phase 14 — Quick Add → Project. Opens the existing New Project
    /// sheet and clears the request so it is handled exactly once.
    private func consumeQuickAdd() {
        guard router.pendingCreate == .project else { return }
        router.pendingCreate = nil
        showingNewSheet = true
    }

    private func createProject(_ result: ProjectFormResult) {
        do {
            let project = try store.createProject(
                name: result.name,
                description: result.description,
                status: result.status
            )
            selectedProjectID = project.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateProject(_ project: ResearchProject, with result: ProjectFormResult) {
        do {
            try store.updateProject(
                project,
                name: result.name,
                description: result.description,
                status: result.status
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ project: ResearchProject) {
        do {
            if selectedProjectID == project.id {
                selectedProjectID = nil
            }
            try store.deleteProject(project)
            deletingProject = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}


// MARK: - Project Form (name, description, status)

struct ProjectFormResult {
    var name: String
    var description: String
    var status: ResearchProjectStatus
}

struct ProjectFormSheet: View {
    let project: ResearchProject?
    let onSave: (ProjectFormResult) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var description: String
    @State private var status: ResearchProjectStatus

    init(project: ResearchProject?, onSave: @escaping (ProjectFormResult) -> Void) {
        self.project = project
        self.onSave = onSave
        _name = State(initialValue: project?.name ?? "")
        _description = State(initialValue: project?.descriptionText ?? "")
        _status = State(initialValue: project?.status ?? .planning)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(project == nil ? "New Project" : "Edit Project")
                    .font(RBFont.detail(.semibold))
                    .foregroundStyle(RBColor.primaryText)

                Spacer()

                Button("Cancel") { dismiss() }
                    .buttonStyle(RBGhostButtonStyle())

                Button("Save") {
                    onSave(
                        ProjectFormResult(
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            description: description,
                            status: status
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
                    RB9TextField(label: "Project Name", text: $name, placeholder: "e.g. Lightweight Intrusion Detection Using Machine Learning")

                    VStack(alignment: .leading, spacing: 6) {
                        RB9SectionLabel(text: "Status")

                        Picker("", selection: $status) {
                            ForEach(ResearchProjectStatus.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }

                    RB9TextEditor(label: "Description", text: $description, minHeight: 100)
                }
                .padding(24)
            }
        }
        .frame(width: 560, height: 560)
        .background(RBColor.elevatedSurface)
    }
}
