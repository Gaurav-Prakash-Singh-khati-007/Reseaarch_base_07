//
//  ProjectDetailView.swift
//  ResearchBase
//
//  Phase 11 — Dashboard + Research Workflow / Projects
//
//  The project workspace: name, description, status, last updated,
//  linked-entity counts, a workflow visualization/navigation layer,
//  and a condensed preview of what's linked in each research
//  category, with a way to open the full link/unlink manager
//  (ProjectResearchLinkView).
//
//  This view never infers or claims novelty, correctness,
//  superiority, significance or validity about the researcher's
//  work — the workflow chain below is purely a navigation aid over
//  the existing entity counts, not a scientific judgment.
//

import SwiftUI
import SwiftData

// MARK: - Status Color

func rbProjectStatusColor(_ status: ResearchProjectStatus) -> Color {
    switch status {
    case .planning: return RBColor.mutedText
    case .active: return RBColor.success
    case .onHold: return RBColor.warning
    case .completed: return RBColor.success
    case .archived: return RBColor.mutedText
    }
}

// MARK: - Root View

struct ProjectDetailView: View {

    let project: ResearchProject

    let allPapers: [PaperRecord]
    let allNotes: [ResearchNote]
    let allFindings: [LiteratureFinding]
    let allGaps: [ResearchGap]
    let allProblems: [ResearchProblem]
    let allIdeas: [ResearchIdea]
    let allExperiments: [Experiment]
    let allWritingDocuments: [WritingDocument]

    let onEdit: () -> Void
    let onDelete: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var showingLinkSheet = false
    @State private var errorMessage: String?

    private var store: ResearchDataStore {
        ResearchDataStore(modelContext: modelContext)
    }

    /// Total experiment runs across every experiment linked to this
    /// project — a purely arithmetic stand-in for "Results" in the
    /// workflow chain below, since results live on ExperimentRun
    /// rather than as their own linkable entity.
    private var totalRunCount: Int {
        project.experiments.reduce(0) { $0 + $1.runs.count }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                RB9DetailHeader(
                    title: project.name,
                    statusText: project.status.rawValue,
                    statusColor: rbProjectStatusColor(project.status),
                    onEdit: onEdit,
                    onDelete: onDelete
                )

                Text("Last updated \(project.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)

                RB9DetailSection(title: "Description", text: project.descriptionText)

                countsGrid

                workflowSection

                linkedResearchSection
            }
            .rbResponsiveContentPadding()
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(RBColor.background)
        .sheet(isPresented: $showingLinkSheet) {
            ProjectResearchLinkView(
                project: project,
                allPapers: allPapers,
                allNotes: allNotes,
                allFindings: allFindings,
                allGaps: allGaps,
                allProblems: allProblems,
                allIdeas: allIdeas,
                allExperiments: allExperiments,
                allWritingDocuments: allWritingDocuments,
                store: store,
                onError: { errorMessage = $0 }
            )
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

    // MARK: - Counts Grid

    private var countGridItems: [(label: String, icon: String, count: Int)] {
        [
            ("Papers", "doc.text", project.papers.count),
            ("Notes", "note.text", project.notes.count),
            ("Findings", "text.magnifyingglass", project.findings.count),
            ("Gaps", "puzzlepiece", project.gaps.count),
            ("Problems", "questionmark.circle", project.problems.count),
            ("Ideas", "lightbulb", project.ideas.count),
            ("Experiments", "flask", project.experiments.count),
            ("Writing", "pencil", project.writingDocuments.count)
        ]
    }

    private var countsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 12)],
            spacing: 12
        ) {
            ForEach(countGridItems, id: \.label) { item in
                RBCard(padding: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: item.icon)
                            .font(.system(size: 12))
                            .foregroundStyle(RBColor.accent)
                        Spacer()
                    }

                    Text("\(item.count)")
                        .font(RBFont.detail(.semibold))
                        .foregroundStyle(RBColor.primaryText)

                    Text(item.label)
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.secondaryText)
                }
                }
            }
        }
    }

    // MARK: - Workflow Section

    private var workflowChain: [(label: String, count: Int)] {
        [
            ("Papers", project.papers.count),
            ("Findings", project.findings.count),
            ("Gaps", project.gaps.count),
            ("Problems", project.problems.count),
            ("Ideas", project.ideas.count),
            ("Experiments", project.experiments.count),
            ("Results", totalRunCount),
            ("Writing", project.writingDocuments.count)
        ]
    }

    private var workflowSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            RB9SectionLabel(text: "Research Workflow")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(workflowChain.enumerated()), id: \.offset) { index, step in
                        workflowStep(label: step.label, count: step.count)

                        if index < workflowChain.count - 1 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11))
                                .foregroundStyle(RBColor.mutedText)
                                .padding(.horizontal, 10)
                        }
                    }
                }
                .padding(16)
            }
            .background(RBColor.card)
            .clipShape(RoundedRectangle(cornerRadius: RBRadius.panel))
            .overlay(
                RoundedRectangle(cornerRadius: RBRadius.panel)
                    .stroke(RBColor.border)
            )
        }
    }

    private func workflowStep(label: String, count: Int) -> some View {
        VStack(spacing: 4) {
            Text("\(count)")
                .font(RBFont.section(.semibold))
                .foregroundStyle(RBColor.primaryText)

            Text(label)
                .font(RBFont.caption())
                .foregroundStyle(RBColor.secondaryText)
        }
        .frame(minWidth: 74)
    }

    // MARK: - Linked Research Section

    private var linkedResearchSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                RB9SectionLabel(text: "Linked Research")

                Spacer()

                Button {
                    showingLinkSheet = true
                } label: {
                    Label("Manage Links", systemImage: "link")
                }
                .buttonStyle(RBGhostButtonStyle())
            }

            if project.totalLinkedCount == 0 {
                RB9InlineEmptyNote(
                    icon: "tray",
                    title: "Nothing Linked Yet",
                    message: "Link existing papers, notes, findings, gaps, problems, ideas, experiments or writing documents to this project."
                )
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    previewRow(title: "Papers", items: project.papers.map { $0.title })
                    previewRow(title: "Notes", items: project.notes.map { $0.title })
                    previewRow(title: "Findings", items: project.findings.map { $0.title })
                    previewRow(title: "Gaps", items: project.gaps.map { $0.title })
                    previewRow(title: "Problems", items: project.problems.map { $0.title })
                    previewRow(title: "Ideas", items: project.ideas.map { $0.title })
                    previewRow(title: "Experiments", items: project.experiments.map { $0.name })
                    previewRow(title: "Writing", items: project.writingDocuments.map { $0.title })
                }
            }
        }
    }

    @ViewBuilder
    private func previewRow(title: String, items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(title) (\(items.count))")
                    .font(RBFont.label(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(RBColor.mutedText)

                Text(items.prefix(4).joined(separator: " · ") + (items.count > 4 ? " · …" : ""))
                    .font(RBFont.secondary())
                    .foregroundStyle(RBColor.secondaryText)
                    .lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RBColor.card)
            .clipShape(RoundedRectangle(cornerRadius: RBRadius.field))
            .overlay(
                RoundedRectangle(cornerRadius: RBRadius.field)
                    .stroke(RBColor.border)
            )
        }
    }
}
