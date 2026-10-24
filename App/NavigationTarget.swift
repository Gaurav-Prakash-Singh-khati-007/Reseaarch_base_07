//
//  NavigationTarget.swift
//  ResearchBase
//
//  Phase 12 — Search, Linking & Cross-Module Intelligence
//
//  A single, typed "go to this existing item" instruction. Global
//  search results and "Related Research" rows never open a new
//  item — they always resolve to one of these cases and hand it to
//  ContentView, which is the only place that knows how to open each
//  screen at a specific item.
//
//  This file introduces no new persistence and no new relationships.
//  It only names the entity types Phase 12's navigation needs to
//  reach, using the ids of records that already exist.
//

import Foundation

// MARK: - Navigation Target

enum NavigationTarget: Hashable, Identifiable {

    case paper(UUID)
    case researchNote(UUID)
    case literatureFinding(UUID)
    case researchGap(UUID)
    case researchProblem(UUID)
    case researchIdea(UUID)
    case experiment(UUID)
    case writingDocument(UUID)
    case project(UUID)
    case task(UUID)

    // MARK: - Identifiable

    /// Stable identity for use in `.sheet(item:)`, `ForEach`, etc.
    var id: String {
        "\(caseLabel)-\(recordID.uuidString)"
    }

    // MARK: - Underlying Record ID

    /// The id of the existing record this target points at.
    var recordID: UUID {
        switch self {
        case .paper(let id): return id
        case .researchNote(let id): return id
        case .literatureFinding(let id): return id
        case .researchGap(let id): return id
        case .researchProblem(let id): return id
        case .researchIdea(let id): return id
        case .experiment(let id): return id
        case .writingDocument(let id): return id
        case .project(let id): return id
        case .task(let id): return id
        }
    }

    // MARK: - Destination Screen

    /// The sidebar screen that hosts this target. `.paper` is the one
    /// exception: a PaperRecord opens directly in ContentView's own
    /// detail pane rather than through PapersView, so ContentView
    /// checks for `.paper` before consulting `screen` at all — this
    /// value exists only so every case has one, for completeness.
    var screen: ResearchScreen {
        switch self {
        case .paper:
            return .papers
        case .researchNote:
            return .knowledge
        case .literatureFinding:
            return .literatureReview
        case .researchGap, .researchProblem, .researchIdea:
            return .researchIdeas
        case .experiment:
            return .experiments
        case .writingDocument:
            return .writing
        case .project:
            return .projects
        case .task:
            return .tasks
        }
    }

    // MARK: - Display Label

    /// Short, human-readable name for the kind of thing this target
    /// points at — used to label a group in search results or a row
    /// in "Related Research", never to describe the record itself.
    var kindLabel: String {
        switch self {
        case .paper: return "Paper"
        case .researchNote: return "Research Note"
        case .literatureFinding: return "Finding"
        case .researchGap: return "Research Gap"
        case .researchProblem: return "Research Problem"
        case .researchIdea: return "Research Idea"
        case .experiment: return "Experiment"
        case .writingDocument: return "Writing Document"
        case .project: return "Project"
        case .task: return "Task"
        }
    }

    /// System symbol matching the icon already used for this kind of
    /// item elsewhere in the app (sidebar, ProjectLinkTab, etc.), so
    /// search results and related-item rows look consistent with the
    /// rest of the UI.
    var iconName: String {
        switch self {
        case .paper: return "doc.text"
        case .researchNote: return "note.text"
        case .literatureFinding: return "text.magnifyingglass"
        case .researchGap: return "puzzlepiece"
        case .researchProblem: return "questionmark.circle"
        case .researchIdea: return "lightbulb"
        case .experiment: return "flask"
        case .writingDocument: return "pencil"
        case .project: return "square.grid.2x2"
        case .task: return "checkmark.square"
        }
    }

    // MARK: - Private

    private var caseLabel: String {
        switch self {
        case .paper: return "paper"
        case .researchNote: return "researchNote"
        case .literatureFinding: return "literatureFinding"
        case .researchGap: return "researchGap"
        case .researchProblem: return "researchProblem"
        case .researchIdea: return "researchIdea"
        case .experiment: return "experiment"
        case .writingDocument: return "writingDocument"
        case .project: return "project"
        case .task: return "task"
        }
    }
}

// MARK: - Quick Add Kind (Phase 14)

/// A request to CREATE a new item of one kind — the counterpart of
/// `NavigationTarget`, which means "go to an EXISTING item".
///
/// Home's Quick Add menu calls `router.requestCreate(_:)` with one of
/// these. ContentView switches to `screen`, and the request stays in
/// `router.pendingCreate` until the destination screen consumes and
/// clears it. This type only names the request; it creates nothing.
enum QuickAddKind: Hashable, CaseIterable {

    case paper
    case note
    case finding
    case gap
    case problem
    case idea
    case experiment
    case task
    case project
    case writing

    /// The sidebar screen that hosts this kind of item. Gap, problem
    /// and idea all live inside the one Research Ideas screen.
    var screen: ResearchScreen {
        switch self {
        case .paper: return .papers
        case .note: return .knowledge
        case .finding: return .literatureReview
        case .gap, .problem, .idea: return .researchIdeas
        case .experiment: return .experiments
        case .task: return .tasks
        case .project: return .projects
        case .writing: return .writing
        }
    }

    /// Human-readable menu label.
    var menuLabel: String {
        switch self {
        case .paper: return "Paper"
        case .note: return "Note"
        case .finding: return "Finding"
        case .gap: return "Research Gap"
        case .problem: return "Research Problem"
        case .idea: return "Research Idea"
        case .experiment: return "Experiment"
        case .task: return "Task"
        case .project: return "Project"
        case .writing: return "Writing"
        }
    }

    /// Same symbols NavigationTarget already uses for these kinds.
    var iconName: String {
        switch self {
        case .paper: return "doc.text"
        case .note: return "note.text"
        case .finding: return "text.magnifyingglass"
        case .gap: return "puzzlepiece"
        case .problem: return "questionmark.circle"
        case .idea: return "lightbulb"
        case .experiment: return "flask"
        case .task: return "checkmark.square"
        case .project: return "square.grid.2x2"
        case .writing: return "pencil"
        }
    }
}
