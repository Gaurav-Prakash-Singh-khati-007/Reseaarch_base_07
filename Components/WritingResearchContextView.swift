//
//  WritingResearchContextView.swift
//  ResearchBase
//
//  Phase 10 — Research Writing Workspace
//
//  STEP 10 — Research Context panel.
//  STEP 11 — Experiment/Results → Writing reference insertion.
//
//  A sheet the researcher can open from WritingView while editing a
//  document. It lets them:
//
//    - Browse every research object already linked to the document
//      (Problems, Ideas, Gaps, Experiments, Papers, Notes, Findings)
//    - Link/unlink more existing objects of each type (multi-select,
//      via the same generic ResearchLinkPickerView used elsewhere)
//    - Insert a short plain-text reference marker for any item into
//      whichever WritingSection is currently open in the editor
//
//  Nothing here duplicates data. "Insert" only ever writes a short
//  textual pointer (e.g. "[Experiment: Baseline Sweep, Run #3]") into
//  the section's own `content` string — the researcher's own words
//  own document. ResearchBase never generates or claims novelty,
//  significance, superiority, validity or correctness for anything
//  inserted from here; that interpretation is always the
//  researcher's, which is why experiment/result rows below carry a
//  neutral, factual label only (name, run number, status) and never
//  a summary of what the numbers mean.
//

import SwiftUI
import SwiftData

// MARK: - Context Tab

enum WritingContextTab: String, CaseIterable, Identifiable {
    case problems = "Problems"
    case ideas = "Ideas"
    case gaps = "Gaps"
    case experiments = "Experiments"
    case papers = "Papers"
    case notes = "Notes"
    case findings = "Findings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .problems: return "questionmark.circle"
        case .ideas: return "lightbulb"
        case .gaps: return "puzzlepiece"
        case .experiments: return "flask"
        case .papers: return "doc.text"
        case .notes: return "note.text"
        case .findings: return "text.magnifyingglass"
        }
    }
}

// MARK: - Root View

struct WritingResearchContextView: View {

    let document: WritingDocument

    let allProblems: [ResearchProblem]
    let allIdeas: [ResearchIdea]
    let allGaps: [ResearchGap]
    let allExperiments: [Experiment]
    let allPapers: [PaperRecord]
    let allNotes: [ResearchNote]
    let allFindings: [LiteratureFinding]

    let store: ResearchDataStore

    /// Inserts a short textual marker into the currently active
    /// section's content. WritingView supplies this from whatever
    /// section is selected in the editor.
    let onInsertText: (String) -> Void
    let onError: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: WritingContextTab = .problems

    // Pickers (one flag per type; only one sheet is ever presented)
    @State private var showingProblemPicker = false
    @State private var showingIdeaPicker = false
    @State private var showingGapPicker = false
    @State private var showingExperimentPicker = false
    @State private var showingPaperPicker = false
    @State private var showingNotePicker = false
    @State private var showingFindingPicker = false

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().overlay(RBColor.border)

            documentSummary

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
        .sheet(isPresented: $showingProblemPicker) { problemPickerSheet }
        .sheet(isPresented: $showingIdeaPicker) { ideaPickerSheet }
        .sheet(isPresented: $showingGapPicker) { gapPickerSheet }
        .sheet(isPresented: $showingExperimentPicker) { experimentPickerSheet }
        .sheet(isPresented: $showingPaperPicker) {
            PaperLinkPickerView(linkedPapers: paperBinding)
        }
        .sheet(isPresented: $showingNotePicker) { notePickerSheet }
        .sheet(isPresented: $showingFindingPicker) { findingPickerSheet }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Research Context")
                    .font(RBFont.section(.semibold))
                    .foregroundStyle(RBColor.primaryText)

                Text("Browse and link research while you write. Insert adds a reference, never a copy.")
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
                ForEach(WritingContextTab.allCases) { tab in
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

    // MARK: Document Summary (Phase 14, Agent 7)

    /// Compact status block from the workspace info panel, so the
    /// document's stage, progress and counts stay visible while linking
    /// research. Everything is read from the document's computed
    /// properties. Progress shows whatever is stored (0% if unset).
    private var documentSummary: some View {
        let stages = WritingDocumentStage.allCases
        let currentIndex = stages.firstIndex(of: document.stage) ?? 0
        let stageColor = rbWritingStageColor(document.stage)

        return RBCard(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {

                HStack(spacing: 6) {
                    RBBadge(text: document.stage.rawValue, tone: stageTone(document.stage))

                    if let format = document.format {
                        RBBadge(text: format.rawValue, tone: .neutral)
                    }

                    Spacer(minLength: 8)

                    Text(document.title.isEmpty ? "Untitled Document" : document.title)
                        .font(RBFont.caption(.medium))
                        .foregroundStyle(RBColor.secondaryText)
                        .lineLimit(1)
                }

                HStack(spacing: 4) {
                    ForEach(Array(stages.enumerated()), id: \.offset) { index, _ in
                        Capsule()
                            .fill(
                                index < currentIndex
                                    ? RBColor.accent.opacity(0.5)
                                    : (index == currentIndex ? stageColor : RBColor.border)
                            )
                            .frame(height: 4)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Lifecycle: \(document.stage.rawValue)")

                HStack(spacing: 8) {
                    RBProgressBar(value: Double(document.progress) / 100)

                    Text("\(document.progress)%")
                        .font(RBFont.caption(.semibold))
                        .foregroundStyle(RBColor.primaryText)
                }

                HStack(spacing: 18) {
                    summaryStat("Words", document.totalWordCount.formatted())
                    summaryStat("Sections", "\(document.sections.count)")
                    summaryStat("Citations", "\(document.papers.count)")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func summaryStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(RBFont.secondary(.semibold))
                .foregroundStyle(RBColor.primaryText)

            Text(label)
                .font(RBFont.label())
                .foregroundStyle(RBColor.mutedText)
        }
    }

    private func stageTone(_ stage: WritingDocumentStage) -> RBBadgeTone {
        switch stage {
        case .draft: return .muted
        case .submitted, .underReview: return .warning
        case .revision: return .error
        case .accepted, .published: return .ok
        }
    }

    private func linkedCount(for tab: WritingContextTab) -> Int {
        switch tab {
        case .problems: return document.problems.count
        case .ideas: return document.ideas.count
        case .gaps: return document.gaps.count
        case .experiments: return document.experiments.count
        case .papers: return document.papers.count
        case .notes: return document.notes.count
        case .findings: return document.findings.count
        }
    }

    // MARK: Tab Content

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .problems: problemsTab
        case .ideas: ideasTab
        case .gaps: gapsTab
        case .experiments: experimentsTab
        case .papers: papersTab
        case .notes: notesTab
        case .findings: findingsTab
        }
    }

    // MARK: - Problems

    private var problemsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            linkMoreHeader(title: "Linked Problems") { showingProblemPicker = true }

            if document.problems.isEmpty {
                emptyNote("No research problems linked yet.")
            } else {
                ForEach(document.problems, id: \.id) { problem in
                    ContextItemRow(
                        title: problem.title,
                        subtitle: "",
                        onInsert: { onInsertText("[Problem: \(problem.title)]") },
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
                current: { document.problems.map(\.id) }
            ) { newIDs in
                rb9ApplyLinks(
                    newIDs: newIDs,
                    current: document.problems,
                    all: allProblems,
                    link: { try store.linkProblemToWritingDocument($0, to: document) },
                    unlink: { try store.unlinkProblemFromWritingDocument($0, from: document) },
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
            try store.unlinkProblemFromWritingDocument(problem, from: document)
        } catch {
            onError(error.localizedDescription)
        }
    }

    // MARK: - Ideas

    private var ideasTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            linkMoreHeader(title: "Linked Ideas") { showingIdeaPicker = true }

            if document.ideas.isEmpty {
                emptyNote("No research ideas linked yet.")
            } else {
                ForEach(document.ideas, id: \.id) { idea in
                    ContextItemRow(
                        title: idea.title,
                        subtitle: "",
                        onInsert: { onInsertText("[Idea: \(idea.title)]") },
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
                current: { document.ideas.map(\.id) }
            ) { newIDs in
                rb9ApplyLinks(
                    newIDs: newIDs,
                    current: document.ideas,
                    all: allIdeas,
                    link: { try store.linkIdeaToWritingDocument($0, to: document) },
                    unlink: { try store.unlinkIdeaFromWritingDocument($0, from: document) },
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
            try store.unlinkIdeaFromWritingDocument(idea, from: document)
        } catch {
            onError(error.localizedDescription)
        }
    }

    // MARK: - Gaps

    private var gapsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            linkMoreHeader(title: "Linked Gaps") { showingGapPicker = true }

            if document.gaps.isEmpty {
                emptyNote("No research gaps linked yet.")
            } else {
                ForEach(document.gaps, id: \.id) { gap in
                    ContextItemRow(
                        title: gap.title,
                        subtitle: "",
                        onInsert: { onInsertText("[Gap: \(gap.title)]") },
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
                current: { document.gaps.map(\.id) }
            ) { newIDs in
                rb9ApplyLinks(
                    newIDs: newIDs,
                    current: document.gaps,
                    all: allGaps,
                    link: { try store.linkGapToWritingDocument($0, to: document) },
                    unlink: { try store.unlinkGapFromWritingDocument($0, from: document) },
                    onError: onError
                )
            },
            emptyMessage: "No research gaps exist yet.",
            title: { $0.title },
            matches: { $0.title.localizedCaseInsensitiveContains($1) }
        )
    }

    private func unlinkGap(_ gap: ResearchGap) {
        do {
            try store.unlinkGapFromWritingDocument(gap, from: document)
        } catch {
            onError(error.localizedDescription)
        }
    }

    // MARK: - Experiments (Step 11 — Experiment/Results → Writing)

    private var experimentsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            linkMoreHeader(title: "Linked Experiments") { showingExperimentPicker = true }

            Text("The researcher interprets these results — ResearchBase never labels a run significant, superior, valid or novel.")
                .font(RBFont.label())
                .foregroundStyle(RBColor.mutedText)

            if document.experiments.isEmpty {
                emptyNote("No experiments linked yet.")
            } else {
                ForEach(document.experiments, id: \.id) { experiment in
                    VStack(alignment: .leading, spacing: 6) {
                        ContextItemRow(
                            title: experiment.name,
                            subtitle: "\(experiment.runs.count) run\(experiment.runs.count == 1 ? "" : "s")",
                            onInsert: { onInsertText("[Experiment: \(experiment.name)]") },
                            onUnlink: { unlinkExperiment(experiment) }
                        )

                        if !experiment.runs.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(
                                    experiment.runs.sorted { $0.runNumber < $1.runNumber },
                                    id: \.id
                                ) { run in
                                    HStack {
                                        Text("Run #\(run.runNumber) · \(run.status.rawValue)")
                                            .font(RBFont.caption())
                                            .foregroundStyle(RBColor.secondaryText)

                                        Spacer()

                                        Button("Insert") {
                                            onInsertText(
                                                "[Experiment: \(experiment.name), Run #\(run.runNumber)]"
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .font(RBFont.label(.medium))
                                        .foregroundStyle(RBColor.accent)
                                        .rbHover()
                                    }
                                    .padding(.leading, 12)
                                }
                            }
                        }
                    }
                    .padding(10)
                    .background(RBColor.card)
                    .clipShape(RoundedRectangle(cornerRadius: RBRadius.panel))
                    .overlay(RoundedRectangle(cornerRadius: RBRadius.panel).stroke(RBColor.border))
                }
            }
        }
    }

    private var experimentPickerSheet: some View {
        ResearchLinkPickerView(
            navTitle: "Link Experiments",
            items: allExperiments,
            linkedIDs: linkedIDsBinding(
                current: { document.experiments.map(\.id) }
            ) { newIDs in
                rb9ApplyLinks(
                    newIDs: newIDs,
                    current: document.experiments,
                    all: allExperiments,
                    link: { try store.linkExperimentToWritingDocument($0, to: document) },
                    unlink: { try store.unlinkExperimentFromWritingDocument($0, from: document) },
                    onError: onError
                )
            },
            emptyMessage: "No experiments exist yet.",
            title: { $0.name },
            matches: { $0.name.localizedCaseInsensitiveContains($1) }
        )
    }

    private func unlinkExperiment(_ experiment: Experiment) {
        do {
            try store.unlinkExperimentFromWritingDocument(experiment, from: document)
        } catch {
            onError(error.localizedDescription)
        }
    }

    // MARK: - Papers

    private var papersTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            linkMoreHeader(title: "Linked Papers") { showingPaperPicker = true }

            if document.papers.isEmpty {
                emptyNote("No papers linked yet.")
            } else {
                ForEach(document.papers, id: \.id) { paper in
                    ContextItemRow(
                        title: paper.title,
                        subtitle: paper.authors.isEmpty ? "Unknown authors" : paper.authors,
                        onInsert: { onInsertText(citationMarker(for: paper)) },
                        onUnlink: { unlinkPaper(paper) }
                    )
                }
            }
        }
    }

    private var paperBinding: Binding<[PaperRecord]> {
        Binding(
            get: { document.papers },
            set: { newValue in
                rb9ApplyLinks(
                    newIDs: Set(newValue.map(\.id)),
                    current: document.papers,
                    all: allPapers,
                    link: { try store.linkPaperToWritingDocument($0, to: document) },
                    unlink: { try store.unlinkPaperFromWritingDocument($0, from: document) },
                    onError: onError
                )
            }
        )
    }

    private func unlinkPaper(_ paper: PaperRecord) {
        do {
            try store.unlinkPaperFromWritingDocument(paper, from: document)
        } catch {
            onError(error.localizedDescription)
        }
    }

    private func citationMarker(for paper: PaperRecord) -> String {
        if !paper.citationKey.trimmingCharacters(in: .whitespaces).isEmpty {
            return "[\(paper.citationKey)]"
        }
        return "[\(paper.title), \(paper.year)]"
    }

    // MARK: - Notes

    private var notesTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            linkMoreHeader(title: "Linked Notes") { showingNotePicker = true }

            if document.notes.isEmpty {
                emptyNote("No research notes linked yet.")
            } else {
                ForEach(document.notes, id: \.id) { note in
                    ContextItemRow(
                        title: note.title,
                        subtitle: "",
                        onInsert: { onInsertText("[Note: \(note.title)]") },
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
                current: { document.notes.map(\.id) }
            ) { newIDs in
                rb9ApplyLinks(
                    newIDs: newIDs,
                    current: document.notes,
                    all: allNotes,
                    link: { try store.linkNoteToWritingDocument($0, to: document) },
                    unlink: { try store.unlinkNoteFromWritingDocument($0, from: document) },
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
            try store.unlinkNoteFromWritingDocument(note, from: document)
        } catch {
            onError(error.localizedDescription)
        }
    }

    // MARK: - Findings

    private var findingsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            linkMoreHeader(title: "Linked Findings") { showingFindingPicker = true }

            if document.findings.isEmpty {
                emptyNote("No literature findings linked yet.")
            } else {
                ForEach(document.findings, id: \.id) { finding in
                    ContextItemRow(
                        title: finding.title,
                        subtitle: "",
                        onInsert: { onInsertText("[Finding: \(finding.title)]") },
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
                current: { document.findings.map(\.id) }
            ) { newIDs in
                rb9ApplyLinks(
                    newIDs: newIDs,
                    current: document.findings,
                    all: allFindings,
                    link: { try store.linkFindingToWritingDocument($0, to: document) },
                    unlink: { try store.unlinkFindingFromWritingDocument($0, from: document) },
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
            try store.unlinkFindingFromWritingDocument(finding, from: document)
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

    private func emptyNote(_ message: String) -> some View {
        RB9InlineEmptyNote(
            icon: "tray",
            title: "Nothing Linked Yet",
            message: message
        )
    }

    /// Builds a `Set<UUID>` binding for `ResearchLinkPickerView` out
    /// of the document's *current* linked ids, applying the diff via
    /// `apply` only when the picker sheet is dismissed (the binding's
    /// setter fires on every toggle, so `apply` itself must be cheap
    /// and idempotent — which `rb9ApplyLinks` already is, since it
    /// only calls link/unlink for ids that actually changed).
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

// MARK: - Context Item Row

private struct ContextItemRow: View {
    let title: String
    let subtitle: String
    let onInsert: () -> Void
    let onUnlink: () -> Void

    var body: some View {
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

                Spacer()

                Button("Insert", action: onInsert)
                    .buttonStyle(.plain)
                    .font(RBFont.label(.medium))
                    .foregroundStyle(RBColor.accent)
                    .rbHover()

                Button(action: onUnlink) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(RBColor.mutedText)
                }
                .buttonStyle(.plain)
                .rbHover()
            }
        }
    }
}
