//
//  TasksView.swift
//  ResearchBase
//
//  Phase 13B — Tasks
//
//  The Tasks screen: a list (search, filters, sort, "+ New Task") on
//  the left and the selected task's details on the right, built on
//  the same RBMasterDetail layout and RB9 components the Projects
//  and Experiments screens use.
//
//  Data changes go through TaskStore. The list itself is a @Query, so
//  it updates automatically and everything persists across restarts.
//

import SwiftUI
import SwiftData

// MARK: - Shared helpers (also used by other Phase 13 screens)

func rbTaskPriorityColor(_ priority: ResearchTaskPriority) -> Color {
    switch priority {
    case .low: return RBColor.mutedText
    case .medium: return RBColor.warning
    case .high: return RBColor.error
    }
}

func rbTaskStatusColor(_ status: ResearchTaskStatus) -> Color {
    switch status {
    case .todo: return RBColor.secondaryText
    case .inProgress: return RBColor.accent
    case .completed: return RBColor.success
    }
}

/// Short due-date text such as "Due today" or "Overdue · 3 Oct 2026".
/// Nil when the task has no due date.
func rbTaskDueText(_ task: ResearchTask) -> String? {
    guard let due = task.dueDate else { return nil }

    if Calendar.current.isDateInToday(due) { return "Due today" }
    if Calendar.current.isDateInTomorrow(due) { return "Due tomorrow" }

    let text = due.formatted(date: .abbreviated, time: .omitted)
    return task.isOverdue ? "Overdue · \(text)" : "Due \(text)"
}


// MARK: - Tasks Screen

struct TasksView: View {

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var router: NavigationRouter

    @Query(sort: [SortDescriptor(\ResearchTask.createdAt, order: .reverse)])
    private var allTasks: [ResearchTask]

    @State private var searchText = ""
    @State private var filter: TaskFilter = .all
    @State private var sortOption: TaskSort = .dueDate

    @State private var selectedTaskID: UUID?

    // Phase 14 — stacked master/detail. Only controls which pane is
    // visible below RBMasterDetail's breakpoint; it is NOT the
    // selection. Back sets it to false without clearing the selection.
    @State private var showDetail = false

    @State private var showingNewSheet = false
    @State private var editingTask: ResearchTask?
    @State private var deletingTask: ResearchTask?
    @State private var errorMessage: String?

    private var store: TaskStore {
        TaskStore(modelContext: modelContext)
    }

    private var filteredTasks: [ResearchTask] {
        TaskStore.apply(
            filter: filter,
            sort: sortOption,
            searchText: searchText,
            to: allTasks
        )
    }

    private var selectedTask: ResearchTask? {
        guard let selectedTaskID else { return nil }
        return allTasks.first { $0.id == selectedTaskID }
    }

    var body: some View {
        RBMasterDetail(
            masterMin: 240,
            masterIdeal: 340,
            showDetail: $showDetail,
            backTitle: "Tasks"
        ) {
            listPane
        } detail: {            Group {
                if let selectedTask {
                    TaskDetailView(
                        task: selectedTask,
                        onEdit: { editingTask = selectedTask },
                        onDelete: { deletingTask = selectedTask },
                        onToggle: { toggle(selectedTask) }
                    )
                    // Each task gets its own view identity so the
                    // detail pane never leaks state between tasks.
                    .id(selectedTask.id)
                } else {
                    RB9DetailPlaceholder(
                        icon: "checkmark.square",
                        text: "Select a task to see its details."
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RBColor.background)
        .onAppear {
            consumePendingTarget()
            selectFirstIfNeeded()
            consumeQuickAdd()
        }
        .onChange(of: allTasks.count) { selectFirstIfNeeded() }
        .onChange(of: router.pendingTarget) { consumePendingTarget() }
        .onChange(of: router.createRequestCount) { consumeQuickAdd() }
        .sheet(isPresented: $showingNewSheet) {
            TaskEditorView(task: nil) { result in
                createTask(result)
            }
        }
        .sheet(item: $editingTask) { task in
            TaskEditorView(task: task) { result in
                updateTask(task, with: result)
            }
        }
        .confirmationDialog(
            "Delete this Task?",
            isPresented: Binding(
                get: { deletingTask != nil },
                set: { if !$0 { deletingTask = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Task", role: .destructive) {
                if let deletingTask {
                    delete(deletingTask)
                }
            }
            Button("Cancel", role: .cancel) { deletingTask = nil }
        } message: {
            Text("“\(deletingTask?.title ?? "This task")” will be removed. Linked research is not deleted — linked projects, papers, problems, ideas, experiments and writing documents are never deleted.")
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

            HStack {
                Text("Tasks")
                    .font(RBFont.section(.semibold))
                    .foregroundStyle(RBColor.primaryText)

                Spacer()

                Button {
                    showingNewSheet = true
                } label: {
                    Label("New Task", systemImage: "plus")
                }
                .buttonStyle(RBPrimaryButtonStyle())
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if allTasks.isEmpty {
                RB9EmptyState(
                    icon: "checkmark.square",
                    title: "No Tasks Yet",
                    message: "Keep track of the next steps in your research — reading, experiments, writing and more.",
                    actionTitle: "New Task",
                    action: { showingNewSheet = true }
                )
            } else {
                controls

                Divider().overlay(RBColor.border)

                taskList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controls: some View {
        VStack(spacing: 10) {

            HStack(spacing: 8) {

                RBSearchField(placeholder: "Search tasks", text: $searchText)

                rb9SortMenu(
                    selection: $sortOption,
                    allCases: TaskSort.allCases
                )
            }

            filterBar
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var filterBar: some View {

        let counts = TaskStore.counts(for: allTasks)

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(TaskFilter.allCases) { option in
                    let isOn = filter == option

                    Button {
                        filter = option
                    } label: {
                        HStack(spacing: 4) {
                            Text(option.rawValue)

                            Text("\(counts[option] ?? 0)")
                                .foregroundStyle(
                                    isOn
                                    ? RBColor.onAccent.opacity(0.8)
                                    : RBColor.mutedText
                                )
                        }
                        .font(RBFont.caption(.medium))
                        .foregroundStyle(
                            isOn ? RBColor.onAccent : RBColor.secondaryText
                        )
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(isOn ? RBColor.accent : RBColor.card)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(RBColor.border))
                    }
                    .buttonStyle(.plain)
                    .rbHover(cornerRadius: 999)
                }
            }
        }
    }

    @ViewBuilder
    private var taskList: some View {
        let tasks = filteredTasks

        if tasks.isEmpty {
            RB9InlineEmptyNote(
                icon: "checkmark.circle",
                title: "No Matching Tasks",
                message: "Nothing matches this filter or search."
            )
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(tasks) { task in
                        TaskRowView(
                            task: task,
                            isSelected: task.id == selectedTaskID,
                            onSelect: {
                                selectedTaskID = task.id
                                // Phase 14 — an explicit pick opens the
                                // stacked detail (no-op when wide).
                                showDetail = true
                            },
                            onToggle: { toggle(task) }
                        )
                    }
                }
                .padding(14)
            }
        }
    }

    // MARK: Actions

    /// Phase 14: deliberately does NOT set `showDetail`, so opening
    /// Tasks at a narrow width lands on the list, not inside a detail.
    private func selectFirstIfNeeded() {
        if selectedTaskID == nil {            selectedTaskID = filteredTasks.first?.id
        }
    }

    /// If search or a Related Research row asked to open a specific
    /// task, select it and clear the request so it is never
    /// re-applied. Also called on appear, because ContentView sets the
    /// target before this screen exists when navigating here from
    /// another screen.
    private func consumePendingTarget() {
        if case .task(let id) = router.pendingTarget {
            searchText = ""
            filter = .all
            selectedTaskID = id
            // Phase 14 — a deep-linked task opens straight into the
            // detail when stacked (no-op when wide).
            showDetail = true
            router.pendingTarget = nil
        }
    }

    /// Phase 14 — Quick Add → Task. Opens the existing New Task sheet
    /// and clears the request so it is handled exactly once. Selection
    /// and `showDetail` are untouched; `createTask` still owns those.
    private func consumeQuickAdd() {
        guard router.pendingCreate == .task else { return }
        router.pendingCreate = nil
        showingNewSheet = true
    }

    private func toggle(_ task: ResearchTask) {
        do {
            try store.toggleCompletion(task)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createTask(_ result: TaskFormResult) {
        do {
            guard let task = try store.createTask(
                title: result.title,
                descriptionText: result.descriptionText,
                priority: result.priority,
                dueDate: result.dueDate,
                project: result.project,
                papers: result.papers,
                problems: result.problems,
                ideas: result.ideas,
                experiments: result.experiments,
                writingDocuments: result.writingDocuments
            ) else {
                return
            }

            applyStatus(result.status, to: task)
            try store.saveChanges(to: task)

            // Make sure the new task is visible.
            searchText = ""
            if !TaskStore.matches(filter: filter, task: task) {
                filter = .all
            }
            selectedTaskID = task.id
            // Phase 14 — show the task just created (no-op when wide).
            showDetail = true        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateTask(_ task: ResearchTask, with result: TaskFormResult) {
        do {
            task.title = result.title
            task.descriptionText = result.descriptionText
            task.priority = result.priority
            task.dueDate = result.dueDate
            task.project = result.project
            task.papers = result.papers
            task.problems = result.problems
            task.ideas = result.ideas
            task.experiments = result.experiments
            task.writingDocuments = result.writingDocuments

            applyStatus(result.status, to: task)
            try store.saveChanges(to: task)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Keeps `completedDate` correct when the status changes through
    /// the editor: completing records the date, leaving Completed
    /// clears it.
    private func applyStatus(_ status: ResearchTaskStatus, to task: ResearchTask) {
        if status == .completed {
            if !task.isCompleted {
                task.markCompleted()
            }
        } else {
            if task.isCompleted {
                task.reopen()
            }
            task.status = status
        }
    }

    private func delete(_ task: ResearchTask) {
        do {
            if selectedTaskID == task.id {
                selectedTaskID = nil
                // Phase 14 — the shown task is gone; return to the list.
                showDetail = false
            }
            try store.delete(task)
            deletingTask = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}


// MARK: - Task Row

/// List row: checkbox on the left, tappable summary on the right.
/// Built separately from RB9RowCard because RB9RowCard is a single
/// button, and the checkbox needs to be its own button inside the row.
private struct TaskRowView: View {

    let task: ResearchTask
    let isSelected: Bool
    let onSelect: () -> Void
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {

            Button(action: onToggle) {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(
                        task.isCompleted ? RBColor.success : RBColor.mutedText
                    )
            }
            .buttonStyle(.plain)
            .help(task.isCompleted ? "Reopen task" : "Mark complete")

            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 6) {

                    Text(task.title)
                        .font(RBFont.body(.medium))
                        .foregroundStyle(
                            task.isCompleted
                            ? RBColor.mutedText
                            : RBColor.primaryText
                        )
                        .strikethrough(task.isCompleted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        RB9StatusPill(
                            text: task.priority.rawValue,
                            color: rbTaskPriorityColor(task.priority)
                        )

                        if let due = rbTaskDueText(task) {
                            Text(due)
                                .font(RBFont.label(.medium))
                                .foregroundStyle(
                                    task.isOverdue
                                    ? RBColor.error
                                    : RBColor.mutedText
                                )
                                .lineLimit(1)
                        }
                    }

                    if let project = task.project {
                        Label(project.name, systemImage: "square.grid.2x2")
                            .font(RBFont.label())
                            .foregroundStyle(RBColor.mutedText)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor)
        .overlay(
            RoundedRectangle(cornerRadius: RBRadius.field)
                .stroke(isSelected ? RBColor.accent.opacity(0.6) : RBColor.border)
        )
        .clipShape(RoundedRectangle(cornerRadius: RBRadius.field))
        .rbHover(cornerRadius: RBRadius.field)
    }

    private var backgroundColor: Color {
        if isSelected {
            return RBColor.selectedTint
        } else {
            return RBColor.card
        }
    }
}


// MARK: - Task Detail

private struct TaskDetailView: View {

    let task: ResearchTask
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggle: () -> Void

    @EnvironmentObject private var router: NavigationRouter

    /// One linked research item. Only real stored links are listed.
    private struct LinkedItem: Identifiable {
        let target: NavigationTarget
        let title: String
        var id: String { target.id }
    }

    private var linkedItems: [LinkedItem] {
        var items: [LinkedItem] = []

        if let project = task.project {
            items.append(LinkedItem(target: .project(project.id), title: project.name))
        }
        for paper in task.papers {
            items.append(LinkedItem(target: .paper(paper.id), title: paper.title))
        }
        for problem in task.problems {
            items.append(LinkedItem(target: .researchProblem(problem.id), title: problem.title))
        }
        for idea in task.ideas {
            items.append(LinkedItem(target: .researchIdea(idea.id), title: idea.title))
        }
        for experiment in task.experiments {
            items.append(LinkedItem(target: .experiment(experiment.id), title: experiment.name))
        }
        for document in task.writingDocuments {
            items.append(LinkedItem(target: .writingDocument(document.id), title: document.title))
        }

        return items
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                RB9DetailHeader(
                    title: task.title,
                    statusText: task.status.rawValue,
                    statusColor: rbTaskStatusColor(task.status),
                    onEdit: onEdit,
                    onDelete: onDelete
                )

                completionButton

                VStack(alignment: .leading, spacing: 8) {
                    RB9FieldRow(label: "Priority", value: task.priority.rawValue)
                    RB9FieldRow(label: "Due", value: rbTaskDueText(task) ?? "")
                    RB9FieldRow(label: "Project", value: task.project?.name ?? "")
                    RB9FieldRow(
                        label: "Created",
                        value: task.createdAt.formatted(date: .abbreviated, time: .omitted)
                    )
                    RB9FieldRow(
                        label: "Completed",
                        value: task.completedDate?
                            .formatted(date: .abbreviated, time: .shortened) ?? ""
                    )
                }

                RB9DetailSection(title: "Description", text: task.descriptionText)

                linkedSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .rbResponsiveContentPadding()
        }
        .background(RBColor.background)
    }

    private var completionButton: some View {
        Group {
            if task.isCompleted {
                Button(action: onToggle) {
                    Label("Reopen Task", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(RBGhostButtonStyle())
            } else {
                Button(action: onToggle) {
                    Label("Mark Complete", systemImage: "checkmark")
                }
                .buttonStyle(RBPrimaryButtonStyle())
            }
        }
    }

    private var linkedSection: some View {
        VStack(alignment: .leading, spacing: 8) {

            RB9SectionLabel(text: "Linked Research")

            let items = linkedItems

            if items.isEmpty {
                RB9InlineEmptyNote(
                    icon: "link",
                    title: "No Linked Research",
                    message: "Edit this task to link a project, papers, problems, ideas, experiments or writing."
                )
            } else {
                ForEach(items) { item in
                    TaskLinkRow(target: item.target, title: item.title) {
                        router.open(item.target)
                    }
                }
            }
        }
    }
}


// MARK: - Linked Item Row (navigates to the linked record)

private struct TaskLinkRow: View {

    let target: NavigationTarget
    let title: String
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {

                Image(systemName: target.iconName)
                    .font(.system(size: 12))
                    .foregroundStyle(RBColor.accent)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(RBFont.secondary(.medium))
                        .foregroundStyle(RBColor.primaryText)
                        .lineLimit(1)

                    Text(target.kindLabel)
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.mutedText)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundStyle(RBColor.mutedText)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RBColor.card)
            .clipShape(RoundedRectangle(cornerRadius: RBRadius.field))
            .overlay(
                RoundedRectangle(cornerRadius: RBRadius.field)
                    .stroke(RBColor.border)
            )
            .contentShape(RoundedRectangle(cornerRadius: RBRadius.field))
        }
        .buttonStyle(.plain)
        .rbHover(cornerRadius: RBRadius.field)
    }
}
