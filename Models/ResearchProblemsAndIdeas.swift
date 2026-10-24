//
//  ResearchProblemsAndIdeas.swift
//  ResearchBase
//
//  Phase 8 — Research Problems & Ideas
//
//  Introduces ResearchGap, ResearchProblem and ResearchIdea.
//  These models link back to the existing PaperRecord and
//  LiteratureFinding entities. They never duplicate a paper,
//  and deleting one of these objects never deletes the papers,
//  findings, or other research objects it links to — only the
//  relationship itself is removed (see ResearchDataStore).
//

import Foundation
import SwiftData

// MARK: - Research Gap Type

enum ResearchGapType: String, CaseIterable, Codable, Identifiable {

    case missingEvidence = "Missing Evidence"
    case methodological = "Methodological Gap"
    case knowledge = "Knowledge Gap"
    case application = "Application Gap"
    case data = "Data Gap"
    case performance = "Performance Gap"
    case theoretical = "Theoretical Gap"
    case contradictoryFindings = "Contradictory Findings"
    case unexploredArea = "Unexplored Area"
    case other = "Other"

    var id: String { rawValue }
}


// MARK: - Research Gap Status

enum ResearchGapStatus: String, CaseIterable, Codable, Identifiable {

    case identified = "Identified"
    case investigating = "Investigating"
    case validated = "Validated"
    case addressed = "Addressed"
    case archived = "Archived"

    var id: String { rawValue }
}


// MARK: - Research Problem Status

enum ResearchProblemStatus: String, CaseIterable, Codable, Identifiable {

    case draft = "Draft"
    case exploring = "Exploring"
    case defined = "Defined"
    case active = "Active"
    case resolved = "Resolved"
    case archived = "Archived"

    var id: String { rawValue }
}


// MARK: - Research Idea Status

enum ResearchIdeaStatus: String, CaseIterable, Codable, Identifiable {

    case draft = "Draft"
    case exploring = "Exploring"
    case promising = "Promising"
    case selected = "Selected"
    case testing = "Testing"
    case implemented = "Implemented"
    case rejected = "Rejected"
    case archived = "Archived"

    var id: String { rawValue }
}


// MARK: - Research Gap

@Model
final class ResearchGap {

    var id: UUID

    var title: String
    var descriptionText: String

    var gapTypeRawValue: String
    var statusRawValue: String

    var evidence: String
    var significance: String

    var createdAt: Date
    var updatedAt: Date

    // Evidence links back to existing canonical objects.
    // Deleting a ResearchGap must never delete a PaperRecord
    // or a LiteratureFinding, so these use the default
    // (nullify) delete rule — only the relationship is removed.
    @Relationship(inverse: \PaperRecord.linkedResearchGaps)
    var papers: [PaperRecord] = []

    @Relationship(inverse: \LiteratureFinding.researchGaps)
    var findings: [LiteratureFinding] = []

    // Reverse-navigation only. Owned by ResearchProblem /
    // ResearchIdea on the other side; deleting a gap must not
    // delete the problems/ideas that reference it.
    var linkedProblems: [ResearchProblem] = []
    var linkedIdeas: [ResearchIdea] = []

    init(
        id: UUID = UUID(),
        title: String,
        descriptionText: String = "",
        gapTypeRawValue: String = ResearchGapType.other.rawValue,
        statusRawValue: String = ResearchGapStatus.identified.rawValue,
        evidence: String = "",
        significance: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        papers: [PaperRecord] = [],
        findings: [LiteratureFinding] = []
    ) {
        self.id = id
        self.title = title
        self.descriptionText = descriptionText
        self.gapTypeRawValue = gapTypeRawValue
        self.statusRawValue = statusRawValue
        self.evidence = evidence
        self.significance = significance
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.papers = papers
        self.findings = findings
    }

    var gapType: ResearchGapType {
        get { ResearchGapType(rawValue: gapTypeRawValue) ?? .other }
        set { gapTypeRawValue = newValue.rawValue }
    }

    var status: ResearchGapStatus {
        get { ResearchGapStatus(rawValue: statusRawValue) ?? .identified }
        set { statusRawValue = newValue.rawValue }
    }
}


// MARK: - Research Problem

@Model
final class ResearchProblem {

    var id: UUID

    var title: String
    var problemStatement: String
    var background: String
    var motivation: String
    var significance: String
    var researchQuestion: String
    var objectives: String
    var hypotheses: String

    var statusRawValue: String

    var createdAt: Date
    var updatedAt: Date

    // A problem is converted from one or more gaps, and cites
    // supporting papers directly. Neither is owned — deleting a
    // problem must not delete a gap or a paper.
    @Relationship(inverse: \ResearchGap.linkedProblems)
    var gaps: [ResearchGap] = []

    @Relationship(inverse: \PaperRecord.linkedResearchProblems)
    var papers: [PaperRecord] = []

    // Reverse-navigation only, owned by ResearchIdea.
    var linkedIdeas: [ResearchIdea] = []

    init(
        id: UUID = UUID(),
        title: String,
        problemStatement: String = "",
        background: String = "",
        motivation: String = "",
        significance: String = "",
        researchQuestion: String = "",
        objectives: String = "",
        hypotheses: String = "",
        statusRawValue: String = ResearchProblemStatus.draft.rawValue,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        gaps: [ResearchGap] = [],
        papers: [PaperRecord] = []
    ) {
        self.id = id
        self.title = title
        self.problemStatement = problemStatement
        self.background = background
        self.motivation = motivation
        self.significance = significance
        self.researchQuestion = researchQuestion
        self.objectives = objectives
        self.hypotheses = hypotheses
        self.statusRawValue = statusRawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.gaps = gaps
        self.papers = papers
    }

    var status: ResearchProblemStatus {
        get { ResearchProblemStatus(rawValue: statusRawValue) ?? .draft }
        set { statusRawValue = newValue.rawValue }
    }
}


// MARK: - Research Idea

@Model
final class ResearchIdea {

    var id: UUID

    var title: String
    var summary: String
    var descriptionText: String
    var proposedApproach: String
    var expectedContribution: String

    /// The researcher's own claim about novelty. ResearchBase
    /// records this claim; it never asserts or validates novelty
    /// on the researcher's behalf.
    var novelty: String

    var assumptions: String
    var limitations: String

    var statusRawValue: String

    var createdAt: Date
    var updatedAt: Date

    // An idea can address one or more problems, cite gaps and
    // papers directly, and reference existing research notes.
    // None of these are owned — deleting an idea must not delete
    // any of them.
    @Relationship(inverse: \ResearchProblem.linkedIdeas)
    var problems: [ResearchProblem] = []

    @Relationship(inverse: \ResearchGap.linkedIdeas)
    var gaps: [ResearchGap] = []

    @Relationship(inverse: \PaperRecord.linkedResearchIdeas)
    var papers: [PaperRecord] = []

    @Relationship(inverse: \ResearchNote.linkedIdeas)
    var notes: [ResearchNote] = []

    init(
        id: UUID = UUID(),
        title: String,
        summary: String = "",
        descriptionText: String = "",
        proposedApproach: String = "",
        expectedContribution: String = "",
        novelty: String = "",
        assumptions: String = "",
        limitations: String = "",
        statusRawValue: String = ResearchIdeaStatus.draft.rawValue,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        problems: [ResearchProblem] = [],
        gaps: [ResearchGap] = [],
        papers: [PaperRecord] = [],
        notes: [ResearchNote] = []
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.descriptionText = descriptionText
        self.proposedApproach = proposedApproach
        self.expectedContribution = expectedContribution
        self.novelty = novelty
        self.assumptions = assumptions
        self.limitations = limitations
        self.statusRawValue = statusRawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.problems = problems
        self.gaps = gaps
        self.papers = papers
        self.notes = notes
    }

    var status: ResearchIdeaStatus {
        get { ResearchIdeaStatus(rawValue: statusRawValue) ?? .draft }
        set { statusRawValue = newValue.rawValue }
    }
}
