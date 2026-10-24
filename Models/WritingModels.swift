//
//  WritingModels.swift
//  ResearchBase
//
//  Phase 10 — Research Writing Workspace
//
//  Introduces WritingDocument and WritingSection. These are the
//  only two new model types this phase adds.
//
//  A WritingDocument links to existing ResearchProblem / ResearchIdea
//  / ResearchGap / Experiment / PaperRecord / ResearchNote /
//  LiteratureFinding objects, but never duplicates them and never
//  deletes them when the document is deleted. This follows exactly
//  the same "plain, unidirectional array — references but never
//  owns" pattern Experiment already established for its own research
//  links in ExperimentModels.swift: no @Relationship macro on these
//  arrays, so nothing on PaperRecord, ResearchNote, LiteratureFinding,
//  ResearchGap, ResearchProblem, ResearchIdea or Experiment needs to
//  change.
//
//  A WritingDocument DOES own its WritingSections (cascade delete),
//  the same way Experiment owns its ExperimentRuns — deleting a
//  document removes its own sections, but never touches any linked
//  research object.
//
//  Citations (Phase 10, later step) will use the existing
//  PaperRecord relationship directly rather than a new
//  WritingCitation model, per the current implementation plan.
//

import Foundation
import SwiftData

// MARK: - Writing Document Type

enum WritingDocumentType: String, CaseIterable, Codable, Identifiable {

    case researchPaper = "Research Paper"
    case thesisChapter = "Thesis Chapter"
    case literatureReview = "Literature Review"
    case conferencePaper = "Conference Paper"
    case journalPaper = "Journal Paper"

    // Added in Phase 14 (v5 prototype). The older values stay.
    case thesis = "Thesis"
    case technicalReport = "Technical Report"

    case custom = "Custom"

    var id: String { rawValue }
}


// MARK: - Writing Document Status

enum WritingDocumentStatus: String, CaseIterable, Codable, Identifiable {

    case draft = "Draft"
    case inProgress = "In Progress"
    case review = "Review"
    case completed = "Completed"
    case archived = "Archived"

    var id: String { rawValue }
}


// MARK: - Writing Document Stage (Phase 14)

/// Where a document is in its publishing life. This sits ALONGSIDE the
/// old `WritingDocumentStatus`, which is kept so old data still works.
enum WritingDocumentStage: String, CaseIterable, Codable, Identifiable {

    case draft = "Draft"
    case submitted = "Submitted"
    case underReview = "Under Review"
    case revision = "Revision"
    case accepted = "Accepted"
    case published = "Published"

    var id: String { rawValue }

    /// The stage an old status turns into.
    /// Archived is not a stage: it becomes the archived flag instead
    /// (see `WritingDocument.isArchived`), so it maps to Draft here.
    init(migratingFrom status: WritingDocumentStatus) {
        switch status {
        case .draft, .inProgress, .archived:
            self = .draft
        case .review:
            self = .underReview
        case .completed:
            self = .accepted
        }
    }
}


// MARK: - Writing Document Format (Phase 14)

/// The layout/style a document is written for.
enum WritingDocumentFormat: String, CaseIterable, Codable, Identifiable {

    case ieee = "IEEE"
    case acm = "ACM"
    case elsevier = "Elsevier"
    case springer = "Springer"
    case universityThesis = "University thesis"
    case arxivPlain = "arXiv/plain"

    var id: String { rawValue }
}


// MARK: - Writing Section Type

/// Identifies the default academic sections a document can start
/// with, while still allowing the researcher to add arbitrary custom
/// sections. `.custom` is the fallback for any section whose title
/// doesn't correspond to one of the standard types — the same
/// "sensible default, always extensible" pattern `PublicationType`
/// uses with `.other`.
enum WritingSectionType: String, CaseIterable, Codable, Identifiable {

    case abstract = "Abstract"
    case introduction = "Introduction"
    case relatedWork = "Related Work"
    case problemStatement = "Problem Statement"
    case methodology = "Methodology"
    case experimentalSetup = "Experimental Setup"
    case results = "Results"
    case discussion = "Discussion"
    case conclusion = "Conclusion"
    case futureWork = "Future Work"
    case references = "References"
    case custom = "Custom"

    var id: String { rawValue }
}


// MARK: - Writing Document

@Model
final class WritingDocument {

    var id: UUID

    var title: String

    var documentTypeRawValue: String
    var statusRawValue: String

    var createdAt: Date
    var updatedAt: Date

    // ---------------------------------------------------------
    // Phase 14 additions (v5 prototype)
    // ---------------------------------------------------------
    //
    // Every one is optional with a default of nil, so an existing
    // store opens unchanged and an old backup (which lacks them)
    // still restores. Screens should read them through the computed
    // properties below (`stage`, `format`, `isArchived`, `progress`),
    // not these raw ones. The init is left unchanged on purpose.

    var stageRawValue: String? = nil
    var formatRawValue: String? = nil
    var venue: String? = nil
    var submissionNote: String? = nil
    var progressPercent: Int? = nil
    var archivedFlag: Bool? = nil

    // ---------------------------------------------------------
    // Owned Children
    // ---------------------------------------------------------

    // A document owns its sections outright. Deleting the document
    // deletes its sections, exactly the way Experiment owns its runs.
    @Relationship(deleteRule: .cascade, inverse: \WritingSection.document)
    var sections: [WritingSection] = []

    // ---------------------------------------------------------
    // Research Links (Phase 7/8/9 → Phase 10)
    // ---------------------------------------------------------
    //
    // Plain, unidirectional arrays — same pattern used by
    // Experiment for its own research links. No @Relationship
    // macro here, so nothing on ResearchProblem/ResearchIdea/
    // ResearchGap/Experiment/PaperRecord/ResearchNote/
    // LiteratureFinding needs to change. Deleting a WritingDocument
    // never deletes any of these; deleting one of these never
    // deletes the WritingDocument — only the relationship entry
    // disappears from whichever side is edited.

    var problems: [ResearchProblem] = []
    var ideas: [ResearchIdea] = []
    var gaps: [ResearchGap] = []
    var experiments: [Experiment] = []
    var papers: [PaperRecord] = []
    var notes: [ResearchNote] = []
    var findings: [LiteratureFinding] = []


    // MARK: - Initializer

    init(
        id: UUID = UUID(),
        title: String,
        documentTypeRawValue: String = WritingDocumentType.researchPaper.rawValue,
        statusRawValue: String = WritingDocumentStatus.draft.rawValue,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        problems: [ResearchProblem] = [],
        ideas: [ResearchIdea] = [],
        gaps: [ResearchGap] = [],
        experiments: [Experiment] = [],
        papers: [PaperRecord] = [],
        notes: [ResearchNote] = [],
        findings: [LiteratureFinding] = []
    ) {
        self.id = id
        self.title = title
        self.documentTypeRawValue = documentTypeRawValue
        self.statusRawValue = statusRawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.problems = problems
        self.ideas = ideas
        self.gaps = gaps
        self.experiments = experiments
        self.papers = papers
        self.notes = notes
        self.findings = findings
    }


    // MARK: - Document Type

    var documentType: WritingDocumentType {
        get { WritingDocumentType(rawValue: documentTypeRawValue) ?? .researchPaper }
        set { documentTypeRawValue = newValue.rawValue }
    }


    // MARK: - Status

    var status: WritingDocumentStatus {
        get { WritingDocumentStatus(rawValue: statusRawValue) ?? .draft }
        set { statusRawValue = newValue.rawValue }
    }


    // MARK: - Lifecycle Stage (Phase 14)

    /// The document's stage. If it was never set (every document made
    /// before Phase 14), it is worked out from the old status:
    /// Draft or In Progress -> Draft, Review -> Under Review,
    /// Completed -> Accepted, Archived -> Draft.
    var stage: WritingDocumentStage {
        get {
            if let raw = stageRawValue,
               let stored = WritingDocumentStage(rawValue: raw) {
                return stored
            }
            return WritingDocumentStage(migratingFrom: status)
        }
        set { stageRawValue = newValue.rawValue }
    }

    /// nil means no format has been chosen yet.
    var format: WritingDocumentFormat? {
        get {
            guard let raw = formatRawValue else { return nil }
            return WritingDocumentFormat(rawValue: raw)
        }
        set { formatRawValue = newValue?.rawValue }
    }

    /// True when archived. Until the flag is set, an old "Archived"
    /// status counts as archived.
    var isArchived: Bool {
        get { archivedFlag ?? (status == .archived) }
        set { archivedFlag = newValue }
    }

    /// Progress from 0 to 100. Not set yet reads as 0.
    var progress: Int {
        min(max(progressPercent ?? 0, 0), 100)
    }


    // MARK: - Ordered Sections

    /// Sections in their researcher-defined display order. SwiftData
    /// does not guarantee array order is preserved, so anything that
    /// displays sections should read them through this rather than
    /// `sections` directly.
    var orderedSections: [WritingSection] {
        sections.sorted { $0.order < $1.order }
    }


    // MARK: - Word Count

    /// Total word count across all sections. Purely arithmetic
    /// document information — not a claim about quality or
    /// completeness.
    var totalWordCount: Int {
        sections.reduce(0) { total, section in
            total + section.wordCount
        }
    }
}


// MARK: - Writing Section

@Model
final class WritingSection {

    var id: UUID

    var title: String
    var sectionTypeRawValue: String

    var content: String

    /// Display order within the parent document. Lower values sort
    /// first. Not required to be contiguous.
    var order: Int

    var createdAt: Date
    var updatedAt: Date

    // Owning side (cascade) is declared on WritingDocument.sections
    // above — same shape as ExperimentRun.experiment.
    var document: WritingDocument?

    init(
        id: UUID = UUID(),
        title: String,
        sectionTypeRawValue: String = WritingSectionType.custom.rawValue,
        content: String = "",
        order: Int,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        document: WritingDocument? = nil
    ) {
        self.id = id
        self.title = title
        self.sectionTypeRawValue = sectionTypeRawValue
        self.content = content
        self.order = order
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.document = document
    }


    // MARK: - Section Type

    var sectionType: WritingSectionType {
        get { WritingSectionType(rawValue: sectionTypeRawValue) ?? .custom }
        set { sectionTypeRawValue = newValue.rawValue }
    }


    // MARK: - Word Count

    var wordCount: Int {
        content
            .split { $0.isWhitespace || $0.isNewline }
            .filter { !$0.isEmpty }
            .count
    }
}
