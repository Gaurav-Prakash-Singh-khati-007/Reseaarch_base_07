//
//  ProjectResearchLinkView.swift
//  ResearchBase
//
//  Phase 11 — Dashboard + Research Workflow / Projects
//
//  A sheet opened from ProjectDetailView that lets the researcher
//  browse everything currently linked to a project (Papers, Notes,
//  Findings, Gaps, Problems, Ideas, Experiments, Writing) and link
//  more existing objects of each type, or unlink one.
//
//  Structurally this mirrors WritingResearchContextView.swift, minus
//  its "Insert into section" feature — a project has no document
//  body to insert text into, so every row here only ever offers
//  Unlink. Linking uses the same generic ResearchLinkPickerView and
//  rb9ApplyLinks diffing helper used everywhere else in the app.
//
//  Nothing here duplicates data, and nothing here deletes a linked
//  object — Unlink only ever removes the object from the project's
//  own reference array (see ResearchDataStore's Project link/unlink
//  methods).
//

import SwiftUI
import SwiftData

// MARK: - Link Tab

enum ProjectLinkTab: String, CaseIterable, Identifiable {
    case papers = "Papers"
    case notes = "Notes"
    case findings = "Findings"
    case gaps = "Gaps"
    case problems = "Problems"
    case ideas = "Ideas"
    case experiments = "Experiments"
    case writing = "Writing"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .papers: return "doc.text"
        case .notes: return "note.text"
        case .findings: return "text.magnifyingglass"
        case .gaps: return "puzzlepiece"
        case .problems: return "questionmark.circle"
        case .ideas: return "lightbulb"
        case .experiments: return "flask"
        case .writing: return "pencil"
        }
    }
}

// MARK: - Root View

struct ProjectResearchLinkView: View {

    let project: ResearchProject

    let allPapers: [PaperRecord]
    let allNotes: [ResearchNote]
    let allFindings: [LiteratureFinding]
    let allGaps: [ResearchGap]
    let allProblems: [ResearchProblem]
    let allIdeas: [ResearchIdea]
    let allExperiments: [Experiment]
    let allWritingDocuments: [WritingDocument]

    let store: ResearchDataStore

    let onError: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: ProjectLinkTab = .papers

    // One flag per type; only one sheet is ever presented at a time.
    @State private var showingPaperPicker = false
    @State private var showingNotePicker = false
    @State private var showingFindingPicker = false
    @State private var showingGapPicker = false
    @State private var showingProblemPicker = false
    @State private var showingIdeaPicker = false
    @State private var showingExperimentPicker = false
    @State private var showingWritingPicker = false

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().overlay(RBColor.border)

            tabBar

            Divider().overlay(RBColor.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    content
                }
                .padding(16)
            }
        }
        .frame(width: 480, height: 620)
        .background(RBColor.background)
        .sheet(isPresented: $showingPaperPicker) { paperPickerSheet }
        .sheet(isPresented: $showingNotePicker) { notePickerSheet }
        .sheet(isPresented: $showingFindingPicker) { findingPickerSheet }
        .sheet(isPresented: $showingGapPicker) { gapPickerSheet }
        .sheet(isPresented: $showingProblemPicker) { problemPickerSheet }
        .sheet(isPresented: $showingIdeaPicker) { ideaPickerSheet }
        .sheet(isPresented: $showingExperimentPicker) { experimentPickerSheet }
        .sheet(isPresented: $showingWritingPicker) { writingPickerSheet }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Linked Research")
                    .font(RBFont.section(.semibold))
                    .foregroundStyle(RBColor.primaryText)

                Text("Link existing items to this project. Nothing is copied or duplicated.")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)
            }

            Spacer()

            Button("Done") { dismiss() }
                .buttonStyle(RBPrimaryButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Tab Bar

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ProjectLinkTab.allCases) { tab in
                    RBChip(
                        text: "\(tab.rawValue) \(linkedCount(for: tab))",
                        isSelected: selectedTab == tab
                    ) {
                        selectedTab = tab
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(RBColor.surface)
    }

    // MARK: Tab Content

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .papers: papersTab
        case .notes: notesTab
        case .findings: findingsTab
        case .gaps: gapsTab
        case .problems: problemsTab
        case .ideas: ideasTab
        case .experiments: experimentsTab
        case .writing: writingTab
        }
    }

    // MARK: - Papers

    private var papersTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            linkMoreHeader(title: "Linked Papers") { showingPaperPicker = true }

            if project.papers.isEmpty {
                emptyNote("No papers linked yet.")
            } else {
                ForEach(project.papers, id: \.id) { paper in
                    projectLinkRow(
                        title: paper.title,
                        subtitle: paper.authors.isEmpty ? "Unknown authors" : paper.authors,
                        onUnlink: { unlinkPaper(paper) }
                    )
                }
            }
        }
    }

    private var paperPickerSheet: some View {
        ResearchLinkPickerView(
            navTitle: "Link Papers",
            items: allPapers,
            linkedIDs: linkedIDsBinding(
                current: { project.papers.map(\.id) }
            ) { newIDs in
                rb9ApplyLinks(
                    newIDs: newIDs,
                    current: project.papers,
                    all: allPapers,
                    link: { try store.linkPaperToProject($0, to: project) },
                    unlink: { try store.unlinkPaperFromProject($0, from: project) },
                    onError: onError
                )
            },
            emptyMessage: "Your library is empty. Add papers first.",
            title: { $0.title },
            subtitle: { $0.authors.isEmpty ? "Unknown authors" : $0.authors },
            matches: {
                $0.title.localizedCaseInsensitiveContains($1) ||
                $0.authors.localizedCaseInsensitiveContains($1)
            }
        )
    }

    private func unlinkPaper(_ paper: PaperRecord) {
        do {
            try store.unlinkPaperFromProject(paper, from: project)
        } catch {
            onError(error.localizedDescription)
        }
    }

    // MARK: - Notes

    private var notesTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            linkMoreHeader(title: "Linked Notes") { showingNotePicker = true }

            if project.notes.isEmpty {
                emptyNote("No research notes linked yet.")
            } else {
                ForEach(project.notes, id: \.id) { note in
                    projectLinkRow(
                        title: note.title,
                        subtitle: "",
                        onUnlink: { unlinkNote(note) }
                    )
                }
            }
        }
    }

    private var notePickerSheet: some View {
        ResearchLinkPickerView(
            navTitle: "Link Notes",
            items: allNotes,
            linkedIDs: linkedIDsBinding(
                current: { project.notes.map(\.id) }
            ) { newIDs in
                rb9ApplyLinks(
                    newIDs: newIDs,
                    current: project.notes,
                    all: allNotes,
                    link: { try store.linkNoteToProject($0, to: project) },
                    unlink: { try store.unlinkNoteFromProject($0, from: project) },
                    onError: onError
                )
            },
            emptyMessage: "No research notes exist yet.",
            title: { $0.title },
            matches: { $0.title.localizedCaseInsensitiveContains($1) }
        )
    }

    private func unlinkNote(_ note: ResearchNote) {
        do {
            try store.unlinkNoteFromProject(note, from: project)
        } catch {
            onError(error.localizedDescription)
        }
    }

    // MARK: - Findings

    private var findingsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            linkMoreHeader(title: "Linked Findings") { showingFindingPicker = true }

            if project.findings.isEmpty {
                emptyNote("No literature findings linked yet.")
            } else {
                ForEach(project.findings, id: \.id) { finding in
                    projectLinkRow(
                        title: finding.title,
                        subtitle: "",
                        onUnlink: { unlinkFinding(finding) }
                    )
                }
            }
        }
    }

    private var findingPickerSheet: some View {
        ResearchLinkPickerView(
            navTitle: "Link Findings",
            items: allFindings,
            linkedIDs: linkedIDsBinding(
                current: { project.findings.map(\.id) }
            ) { newIDs in
                rb9ApplyLinks(
                    newIDs: newIDs,
                    current: project.findings,
                    all: allFindings,
                    link: { try store.linkFindingToProject($0, to: project) },
                    unlink: { try store.unlinkFindingFromProject($0, from: project) },
                    onError: onError
                )
            },
            emptyMessage: "No literature findings exist yet.",
            title: { $0.title },
            matches: { $0.title.localizedCaseInsensitiveContains($1) }
        )
    }

    private func unlinkFinding(_ finding: LiteratureFinding) {
        do {
            try store.unlinkFindingFromProject(finding, from: project)
        } catch {
            onError(error.localizedDescription)
        }
    }

    // MARK: - Gaps

    private var gapsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            linkMoreHeader(title: "Linked Gaps") { showingGapPicker = true }

            if project.gaps.isEmpty {
                emptyNote("No research gaps linked yet.")
            } else {
                ForEach(project.gaps, id: \.id) { gap in
                    projectLinkRow(
                        title: gap.title,
                        subtitle: gap.gapType.rawValue,
                        onUnlink: { unlinkGap(gap) }
                    )
                }
            }
        }
    }

    private var gapPickerSheet: some View {
        ResearchLinkPickerView(
            navTitle: "Link Gaps",
            items: allGaps,
            linkedIDs: linkedIDsBinding(
                current: { project.gaps.map(\.id) }
            ) { newIDs in
                rb9ApplyLinks(
                    newIDs: newIDs,
                    current: project.gaps,
                    all: allGaps,
                    link: { try store.linkGapToProject($0, to: project) },
                    unlink: { try store.unlinkGapFromProject($0, from: project) },
                    onError: onError
                )
            },
            emptyMessage: "No research gaps exist yet.",
            title: { $0.title },
            subtitle: { $0.gapType.rawValue },
            matches: { $0.title.localizedCaseInsensitiveContains($1) }
        )
    }

    private func unlinkGap(_ gap: ResearchGap) {
        do {
            try store.unlinkGapFromProject(gap, from: project)
        } catch {
            onError(error.localizedDescription)
        }
    }

    // MARK: - Problems

    private var problemsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            linkMoreHeader(title: "Linked Problems") { showingProblemPicker = true }

            if project.problems.isEmpty {
                emptyNote("No research problems linked yet.")
            } else {
                ForEach(project.problems, id: \.id) { problem in
                    projectLinkRow(
                        title: problem.title,
                        subtitle: "",
                        onUnlink: { unlinkProblem(problem) }
                    )
                }
            }
        }
    }

    private var problemPickerSheet: some View {
        ResearchLinkPickerView(
            navTitle: "Link Problems",
            items: allProblems,
            linkedIDs: linkedIDsBinding(
                current: { project.problems.map(\.id) }
            ) { newIDs in
                rb9ApplyLinks(
                    newIDs: newIDs,
                    current: project.problems,
                    all: allProblems,
                    link: { try store.linkProblemToProject($0, to: project) },
                    unlink: { try store.unlinkProblemFromProject($0, from: project) },
                    onError: onError
                )
            },
            emptyMessage: "No research problems exist yet.",
            title: { $0.title },
            matches: { $0.title.localizedCaseInsensitiveContains($1) }
        )
    }

    private func unlinkProblem(_ problem: ResearchProblem) {
        do {
            try store.unlinkProblemFromProject(problem, from: project)
        } catch {
            onError(error.localizedDescription)
        }
    }

    // MARK: - Ideas

    private var ideasTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            linkMoreHeader(title: "Linked Ideas") { showingIdeaPicker = true }

            if project.ideas.isEmpty {
                emptyNote("No research ideas linked yet.")
            } else {
                ForEach(project.ideas, id: \.id) { idea in
                    projectLinkRow(
                        title: idea.title,
                        subtitle: "",
                        onUnlink: { unlinkIdea(idea) }
                    )
                }
            }
        }
    }

    private var ideaPickerSheet: some View {
        ResearchLinkPickerView(
            navTitle: "Link Ideas",
            items: allIdeas,
            linkedIDs: linkedIDsBinding(
                current: { project.ideas.map(\.id) }
            ) { newIDs in
                rb9ApplyLinks(
                    newIDs: newIDs,
                    current: project.ideas,
                    all: allIdeas,
                    link: { try store.linkIdeaToProject($0, to: project) },
                    unlink: { try store.unlinkIdeaFromProject($0, from: project) },
                    onError: onError
                )
            },
            emptyMessage: "No research ideas exist yet.",
            title: { $0.title },
            matches: { $0.title.localizedCaseInsensitiveContains($1) }
        )
    }

    private func unlinkIdea(_ idea: ResearchIdea) {
        do {
            try store.unlinkIdeaFromProject(idea, from: project)
        } catch {
            onError(error.localizedDescription)
        }
    }

    // MARK: - Experiments

    private var experimentsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            linkMoreHeader(title: "Linked Experiments") { showingExperimentPicker = true }

            if project.experiments.isEmpty {
                emptyNote("No experiments linked yet.")
            } else {
                ForEach(project.experiments, id: \.id) { experiment in
                    projectLinkRow(
                        title: experiment.name,
                        subtitle: experiment.status.rawValue,
                        onUnlink: { unlinkExperiment(experiment) }
                    )
                }
            }
        }
    }

    private var experimentPickerSheet: some View {
        ResearchLinkPickerView(
            navTitle: "Link Experiments",
            items: allExperiments,
            linkedIDs: linkedIDsBinding(
                current: { project.experiments.map(\.id) }
            ) { newIDs in
                rb9ApplyLinks(
                    newIDs: newIDs,
                    current: project.experiments,
                    all: allExperiments,
                    link: { try store.linkExperimentToProject($0, to: project) },
                    unlink: { try store.unlinkExperimentFromProject($0, from: project) },
                    onError: onError
                )
            },
            emptyMessage: "No experiments exist yet.",
            title: { $0.name },
            subtitle: { $0.status.rawValue },
            matches: { $0.name.localizedCaseInsensitiveContains($1) }
        )
    }

    private func unlinkExperiment(_ experiment: Experiment) {
        do {
            try store.unlinkExperimentFromProject(experiment, from: project)
        } catch {
            onError(error.localizedDescription)
        }
    }

    // MARK: - Writing

    private var writingTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            linkMoreHeader(title: "Linked Writing") { showingWritingPicker = true }

            if project.writingDocuments.isEmpty {
                emptyNote("No writing documents linked yet.")
            } else {
                ForEach(project.writingDocuments, id: \.id) { document in
                    projectLinkRow(
                        title: document.title,
                        subtitle: document.status.rawValue,
                        onUnlink: { unlinkWritingDocument(document) }
                    )
                }
            }
        }
    }

    private var writingPickerSheet: some View {
        ResearchLinkPickerView(
            navTitle: "Link Writing",
            items: allWritingDocuments,
            linkedIDs: linkedIDsBinding(
                current: { project.writingDocuments.map(\.id) }
            ) { newIDs in
                rb9ApplyLinks(
                    newIDs: newIDs,
                    current: project.writingDocuments,
                    all: allWritingDocuments,
                    link: { try store.linkWritingDocumentToProject($0, to: project) },
                    unlink: { try store.unlinkWritingDocumentFromProject($0, from: project) },
                    onError: onError
                )
            },
            emptyMessage: "No writing documents exist yet.",
            title: { $0.title },
            subtitle: { $0.status.rawValue },
            matches: { $0.title.localizedCaseInsensitiveContains($1) }
        )
    }

    private func unlinkWritingDocument(_ document: WritingDocument) {
        do {
            try store.unlinkWritingDocumentFromProject(document, from: project)
        } catch {
            onError(error.localizedDescription)
        }
    }

    // MARK: - Shared Helpers

    private func linkMoreHeader(title: String, action: @escaping () -> Void) -> some View {
        HStack {
            RBSectionLabel(text: title)

            Spacer()

            Button(action: action) {
                Label("Link More", systemImage: "plus")
                    .font(RBFont.caption(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(RBColor.accent)
            .rbHover()
        }
    }

    /// How many items of each type are linked to this project.
    private func linkedCount(for tab: ProjectLinkTab) -> Int {
        switch tab {
        case .papers: return project.papers.count
        case .notes: return project.notes.count
        case .findings: return project.findings.count
        case .gaps: return project.gaps.count
        case .problems: return project.problems.count
        case .ideas: return project.ideas.count
        case .experiments: return project.experiments.count
        case .writing: return project.writingDocuments.count
        }
    }

    /// One linked item: title, optional subtitle, and an Unlink action.
    /// Unlink only removes the link, never the item itself.
    private func projectLinkRow(
        title: String,
        subtitle: String,
        onUnlink: @escaping () -> Void
    ) -> some View {
        RBCard(padding: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(RBFont.secondary(.medium))
                        .foregroundStyle(RBColor.primaryText)
                        .lineLimit(1)

                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(RBFont.caption())
                            .foregroundStyle(RBColor.mutedText)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                Button("Unlink", action: onUnlink)
                    .buttonStyle(RBGhostButtonStyle())
            }
        }
    }

    private func emptyNote(_ message: String) -> some View {
        RB9InlineEmptyNote(
            icon: "tray",
            title: "Nothing Linked Yet",
            message: message
        )
    }

    /// Builds a `Set<UUID>` binding for `ResearchLinkPickerView` out
    /// of the project's *current* linked ids, applying the diff via
    /// `apply` only when the picker's selection changes (the
    /// binding's setter fires on every toggle, so `apply` itself
    /// must be cheap and idempotent — which `rb9ApplyLinks` already
    /// is, since it only calls link/unlink for ids that actually
    /// changed).
    private func linkedIDsBinding(
        current: @escaping () -> [UUID],
        apply: @escaping (Set<UUID>) -> Void
    ) -> Binding<Set<UUID>> {
        Binding(
            get: { Set(current()) },
            set: { apply($0) }
        )
    }
}
