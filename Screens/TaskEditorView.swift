//
//  TaskEditorView.swift
//  ResearchBase
//
//  Phase 13B — Tasks
//
//  The "New Task" / "Edit Task" sheet. It follows the same pattern as
//  ProjectFormSheet: the sheet edits local copies of the values and
//  hands a TaskFormResult back through `onSave`. The Tasks screen
//  then applies the result through TaskStore, so nothing is changed
//  until Save is pressed.
//
//  Research links reuse the existing ResearchLinkPickerView, and the
//  linked-item rows reuse RB9LinkSectionHeader and RB9LinkRow.
//

import SwiftUI
import SwiftData

// MARK: - Form Result

struct TaskFormResult {
    var title: String
    var descriptionText: String
    var status: ResearchTaskStatus
    var priority: ResearchTaskPriority
    var dueDate: Date?
    var project: ResearchProject?
    var papers: [PaperRecord]
    var problems: [ResearchProblem]
    var ideas: [ResearchIdea]
    var experiments: [Experiment]
    var writingDocuments: [WritingDocument]
}


// MARK: - Task Editor

struct TaskEditorView: View {

    let task: ResearchTask?
    let onSave: (TaskFormResult) -> Void

    @Environment(\.dismiss) private var dismiss

    @Query(sort: [SortDescriptor(\ResearchProject.name)])
    private var allProjects: [ResearchProject]

    @Query(sort: [SortDescriptor(\PaperRecord.addedAt, order: .reverse)])
    private var allPapers: [PaperRecord]

    @Query(sort: [SortDescriptor(\ResearchProblem.updatedAt, order: .reverse)])
    private var allProblems: [ResearchProblem]

    @Query(sort: [SortDescriptor(\ResearchIdea.updatedAt, order: .reverse)])
    private var allIdeas: [ResearchIdea]

    @Query(sort: [SortDescriptor(\Experiment.updatedAt, order: .reverse)])
    private var allExperiments: [Experiment]

    @Query(sort: [SortDescriptor(\WritingDocument.updatedAt, order: .reverse)])
    private var allWritingDocuments: [WritingDocument]

    // Form values
    @State private var title: String
    @State private var descriptionText: String
    @State private var status: ResearchTaskStatus
    @State private var priority: ResearchTaskPriority
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var projectID: ResearchProject.ID?

    @State private var paperIDs: Set<PaperRecord.ID>
    @State private var problemIDs: Set<ResearchProblem.ID>
    @State private var ideaIDs: Set<ResearchIdea.ID>
    @State private var experimentIDs: Set<Experiment.ID>
    @State private var writingIDs: Set<WritingDocument.ID>

    @State private var activePicker: LinkPicker?

    private enum LinkPicker: String, Identifiable {
        case papers, problems, ideas, experiments, writing
        var id: String { rawValue }
    }

    init(task: ResearchTask?, onSave: @escaping (TaskFormResult) -> Void) {
        self.task = task
        self.onSave = onSave

        _title = State(initialValue: task?.title ?? "")
        _descriptionText = State(initialValue: task?.descriptionText ?? "")
        _status = State(initialValue: task?.status ?? .todo)
        _priority = State(initialValue: task?.priority ?? .medium)
        _hasDueDate = State(initialValue: task?.dueDate != nil)
        _dueDate = State(initialValue: task?.dueDate ?? Date())
        _projectID = State(initialValue: task?.project?.id)

        _paperIDs = State(initialValue: Set((task?.papers ?? []).map { $0.id }))
        _problemIDs = State(initialValue: Set((task?.problems ?? []).map { $0.id }))
        _ideaIDs = State(initialValue: Set((task?.ideas ?? []).map { $0.id }))
        _experimentIDs = State(initialValue: Set((task?.experiments ?? []).map { $0.id }))
        _writingIDs = State(initialValue: Set((task?.writingDocuments ?? []).map { $0.id }))
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {

            header

            Divider().overlay(RBColor.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {

                    RB9TextField(
                        label: "Title",
                        text: $title,
                        placeholder: "e.g. Read three papers on federated intrusion detection"
                    )

                    HStack(alignment: .top, spacing: 16) {
                        pickerField(label: "Status") {
                            Picker("", selection: $status) {
                                ForEach(ResearchTaskStatus.allCases) { option in
                                    Text(option.rawValue).tag(option)
                                }
                            }
                        }

                        pickerField(label: "Priority") {
                            Picker("", selection: $priority) {
                                ForEach(ResearchTaskPriority.allCases) { option in
                                    Text(option.rawValue).tag(option)
                                }
                            }
                        }
                    }

                    dueDateField

                    pickerField(label: "Project") {
                        Picker("", selection: $projectID) {
                            Text("None").tag(ResearchProject.ID?.none)

                            ForEach(allProjects) { project in
                                Text(project.name)
                                    .tag(ResearchProject.ID?.some(project.id))
                            }
                        }
                    }

                    RB9TextEditor(
                        label: "Description",
                        text: $descriptionText,
                        minHeight: 90
                    )

                    Divider().overlay(RBColor.border)

                    linkBlock(
                        title: "Papers",
                        items: allPapers,
                        ids: paperIDs,
                        picker: .papers,
                        rowTitle: { $0.title },
                        rowSubtitle: { $0.authors },
                        remove: { paperIDs.remove($0) }
                    )

                    linkBlock(
                        title: "Research Problems",
                        items: allProblems,
                        ids: problemIDs,
                        picker: .problems,
                        rowTitle: { $0.title },
                        rowSubtitle: { _ in "" },
                        remove: { problemIDs.remove($0) }
                    )

                    linkBlock(
                        title: "Research Ideas",
                        items: allIdeas,
                        ids: ideaIDs,
                        picker: .ideas,
                        rowTitle: { $0.title },
                        rowSubtitle: { _ in "" },
                        remove: { ideaIDs.remove($0) }
                    )

                    linkBlock(
                        title: "Experiments",
                        items: allExperiments,
                        ids: experimentIDs,
                        picker: .experiments,
                        rowTitle: { $0.name },
                        rowSubtitle: { _ in "" },
                        remove: { experimentIDs.remove($0) }
                    )

                    linkBlock(
                        title: "Writing Documents",
                        items: allWritingDocuments,
                        ids: writingIDs,
                        picker: .writing,
                        rowTitle: { $0.title },
                        rowSubtitle: { _ in "" },
                        remove: { writingIDs.remove($0) }
                    )
                }
                .padding(24)
            }
        }
        .frame(
            minWidth: 520, idealWidth: 600,
            minHeight: 480, idealHeight: 660
        )
        .background(RBColor.elevatedSurface)
        .sheet(item: $activePicker) { picker in
            pickerSheet(for: picker)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text(task == nil ? "New Task" : "Edit Task")
                .font(RBFont.section(.semibold))
                .foregroundStyle(RBColor.primaryText)

            Spacer()

            Button("Cancel") { dismiss() }
                .buttonStyle(RBGhostButtonStyle())

            Button("Save") {
                onSave(makeResult())
                dismiss()
            }
            .buttonStyle(RBPrimaryButtonStyle())
            .disabled(!isValid)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    // MARK: Fields

    private func pickerField<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            RB9SectionLabel(text: label)

            content()
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dueDateField: some View {
        VStack(alignment: .leading, spacing: 8) {
            RB9SectionLabel(text: "Due Date")

            HStack(spacing: 12) {
                Toggle("Set a due date", isOn: $hasDueDate)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(RBColor.accent)
                    .font(RBFont.secondary())
                    .foregroundStyle(RBColor.secondaryText)

                if hasDueDate {
                    DatePicker(
                        "",
                        selection: $dueDate,
                        displayedComponents: .date
                    )
                    .labelsHidden()
                }

                Spacer()
            }
        }
    }

    // MARK: Link Blocks

    /// One "linked items" block: a header with a Link button, then a
    /// row per linked item (each with an unlink button).
    private func linkBlock<Item: Identifiable>(
        title: String,
        items: [Item],
        ids: Set<Item.ID>,
        picker: LinkPicker,
        rowTitle: @escaping (Item) -> String,
        rowSubtitle: @escaping (Item) -> String,
        remove: @escaping (Item.ID) -> Void
    ) -> some View {

        let linked = items.filter { ids.contains($0.id) }

        return VStack(alignment: .leading, spacing: 8) {

            RB9LinkSectionHeader(title: title) {
                activePicker = picker
            }

            if linked.isEmpty {
                Text("Nothing linked.")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)
            } else {
                ForEach(linked) { item in
                    RB9LinkRow(
                        title: rowTitle(item),
                        subtitle: rowSubtitle(item),
                        onUnlink: { remove(item.id) }
                    )
                }
            }
        }
    }

    // MARK: Picker Sheets

    @ViewBuilder
    private func pickerSheet(for picker: LinkPicker) -> some View {
        switch picker {

        case .papers:
            ResearchLinkPickerView(
                navTitle: "Link Papers",
                items: allPapers,
                linkedIDs: $paperIDs,
                emptyMessage: "Your library is empty. Add papers first.",
                title: { $0.title },
                subtitle: { $0.authors },
                matches: { paper, q in
                    paper.title.localizedCaseInsensitiveContains(q) ||
                    paper.authors.localizedCaseInsensitiveContains(q)
                }
            )

        case .problems:
            ResearchLinkPickerView(
                navTitle: "Link Research Problems",
                items: allProblems,
                linkedIDs: $problemIDs,
                emptyMessage: "No research problems yet.",
                title: { $0.title },
                matches: { problem, q in
                    problem.title.localizedCaseInsensitiveContains(q)
                }
            )

        case .ideas:
            ResearchLinkPickerView(
                navTitle: "Link Research Ideas",
                items: allIdeas,
                linkedIDs: $ideaIDs,
                emptyMessage: "No research ideas yet.",
                title: { $0.title },
                matches: { idea, q in
                    idea.title.localizedCaseInsensitiveContains(q)
                }
            )

        case .experiments:
            ResearchLinkPickerView(
                navTitle: "Link Experiments",
                items: allExperiments,
                linkedIDs: $experimentIDs,
                emptyMessage: "No experiments yet.",
                title: { $0.name },
                matches: { experiment, q in
                    experiment.name.localizedCaseInsensitiveContains(q)
                }
            )

        case .writing:
            ResearchLinkPickerView(
                navTitle: "Link Writing Documents",
                items: allWritingDocuments,
                linkedIDs: $writingIDs,
                emptyMessage: "No writing documents yet.",
                title: { $0.title },
                matches: { document, q in
                    document.title.localizedCaseInsensitiveContains(q)
                }
            )
        }
    }

    // MARK: Result

    private func makeResult() -> TaskFormResult {
        TaskFormResult(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            descriptionText: descriptionText,
            status: status,
            priority: priority,
            dueDate: hasDueDate
                ? Calendar.current.startOfDay(for: dueDate)
                : nil,
            project: allProjects.first { $0.id == projectID },
            papers: allPapers.filter { paperIDs.contains($0.id) },
            problems: allProblems.filter { problemIDs.contains($0.id) },
            ideas: allIdeas.filter { ideaIDs.contains($0.id) },
            experiments: allExperiments.filter { experimentIDs.contains($0.id) },
            writingDocuments: allWritingDocuments.filter { writingIDs.contains($0.id) }
        )
    }
}
