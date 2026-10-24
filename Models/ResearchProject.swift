//
//  ResearchProject.swift
//  ResearchBase
//
//  Phase 11 — Dashboard + Research Workflow / Projects
//
//  Introduces ResearchProject. This is the only new model type this
//  phase adds to the persistence layer.
//
//  A ResearchProject is a pure organizational container. It links to
//  existing PaperRecord / ResearchNote / LiteratureFinding /
//  ResearchGap / ResearchProblem / ResearchIdea / Experiment /
//  WritingDocument objects, but never duplicates them and never
//  deletes them when the project is deleted. This follows exactly
//  the same "plain, unidirectional array — references but never
//  owns" pattern Experiment and WritingDocument already established
//  for their own research links (see ExperimentModels.swift and
//  WritingModels.swift): no @Relationship macro on these arrays, so
//  nothing on PaperRecord, ResearchNote, LiteratureFinding,
//  ResearchGap, ResearchProblem, ResearchIdea, Experiment or
//  WritingDocument needs to change.
//
//  A ResearchProject owns nothing. Deleting a project is therefore a
//  single, safe modelContext.delete(project) — there are no owned
//  children and no relationship macros to configure a delete rule
//  for. The same research object may be linked from multiple
//  projects at once, since these arrays are plain data on the
//  project side only.
//

import Foundation
import SwiftData

// MARK: - Research Project Status

enum ResearchProjectStatus: String, CaseIterable, Codable, Identifiable {

    case planning = "Planning"
    case active = "Active"
    case onHold = "On Hold"
    case completed = "Completed"
    case archived = "Archived"

    var id: String { rawValue }
}


// MARK: - Research Project

@Model
final class ResearchProject {

    var id: UUID

    var name: String
    var descriptionText: String

    var statusRawValue: String

    var createdAt: Date
    var updatedAt: Date

    // ---------------------------------------------------------
    // Research Links (Phase 1–10 → Phase 11)
    // ---------------------------------------------------------
    //
    // Plain, unidirectional arrays — same pattern used by Experiment
    // and WritingDocument for their own research links. No
    // @Relationship macro here, so nothing on PaperRecord,
    // ResearchNote, LiteratureFinding, ResearchGap, ResearchProblem,
    // ResearchIdea, Experiment or WritingDocument needs to change.
    // Deleting a ResearchProject never deletes any of these; deleting
    // one of these never deletes the ResearchProject — only the
    // relationship entry disappears from this array.

    var papers: [PaperRecord] = []
    var notes: [ResearchNote] = []
    var findings: [LiteratureFinding] = []
    var gaps: [ResearchGap] = []
    var problems: [ResearchProblem] = []
    var ideas: [ResearchIdea] = []
    var experiments: [Experiment] = []
    var writingDocuments: [WritingDocument] = []


    // MARK: - Initializer

    init(
        id: UUID = UUID(),
        name: String,
        descriptionText: String = "",
        statusRawValue: String = ResearchProjectStatus.planning.rawValue,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        papers: [PaperRecord] = [],
        notes: [ResearchNote] = [],
        findings: [LiteratureFinding] = [],
        gaps: [ResearchGap] = [],
        problems: [ResearchProblem] = [],
        ideas: [ResearchIdea] = [],
        experiments: [Experiment] = [],
        writingDocuments: [WritingDocument] = []
    ) {
        self.id = id
        self.name = name
        self.descriptionText = descriptionText
        self.statusRawValue = statusRawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.papers = papers
        self.notes = notes
        self.findings = findings
        self.gaps = gaps
        self.problems = problems
        self.ideas = ideas
        self.experiments = experiments
        self.writingDocuments = writingDocuments
    }


    // MARK: - Status

    var status: ResearchProjectStatus {
        get { ResearchProjectStatus(rawValue: statusRawValue) ?? .planning }
        set { statusRawValue = newValue.rawValue }
    }


    // MARK: - Linked Counts

    /// Total number of linked research objects across every category.
    /// Purely arithmetic — used by list rows and the detail overview,
    /// never a claim about project completeness or quality.
    var totalLinkedCount: Int {
        papers.count
            + notes.count
            + findings.count
            + gaps.count
            + problems.count
            + ideas.count
            + experiments.count
            + writingDocuments.count
    }
}
