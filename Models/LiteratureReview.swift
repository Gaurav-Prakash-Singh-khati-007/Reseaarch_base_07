//
//  LiteratureReview.swift
//  ResearchBase
//
//  Literature Review Models
//  Phase 7 + Phase 8
//

import Foundation
import SwiftData


// MARK: - Literature Review

@Model
final class LiteratureReview {

    var id: UUID
    var title: String
    var descriptionText: String
    var researchQuestion: String

    var createdAt: Date
    var updatedAt: Date

    // One review can contain many existing PaperRecords.
    // A PaperRecord can belong to multiple reviews.
    //
    // PaperRecord owns the plain relationship array.
    // This side declares the inverse.
    @Relationship(
        inverse: \PaperRecord.literatureReviews
    )
    var papers: [PaperRecord] = []

    // One review owns its themes.
    // Deleting a review deletes its themes,
    // but never deletes PaperRecords.
    @Relationship(
        deleteRule: .cascade,
        inverse: \LiteratureTheme.review
    )
    var themes: [LiteratureTheme] = []

    // One review owns its findings.
    // Deleting a review deletes its findings,
    // but never deletes PaperRecords or ResearchGaps.
    @Relationship(
        deleteRule: .cascade,
        inverse: \LiteratureFinding.review
    )
    var findings: [LiteratureFinding] = []

    // One review owns its comparison entries.
    @Relationship(
        deleteRule: .cascade,
        inverse: \LiteratureComparisonEntry.review
    )
    var comparisonEntries: [LiteratureComparisonEntry] = []

    // One persisted synthesis per review.
    @Relationship(
        deleteRule: .cascade,
        inverse: \LiteratureSynthesis.review
    )
    var synthesis: LiteratureSynthesis?

    init(
        id: UUID = UUID(),
        title: String,
        descriptionText: String = "",
        researchQuestion: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        papers: [PaperRecord] = []
    ) {
        self.id = id
        self.title = title
        self.descriptionText = descriptionText
        self.researchQuestion = researchQuestion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.papers = papers
    }
}


// MARK: - Literature Theme

@Model
final class LiteratureTheme {

    var id: UUID
    var name: String
    var descriptionText: String

    var createdAt: Date
    var updatedAt: Date

    // Theme belongs to one Literature Review.
    var review: LiteratureReview?

    // A PaperRecord can belong to multiple themes.
    @Relationship(
        inverse: \PaperRecord.literatureThemes
    )
    var papers: [PaperRecord] = []

    init(
        id: UUID = UUID(),
        name: String,
        descriptionText: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        review: LiteratureReview? = nil,
        papers: [PaperRecord] = []
    ) {
        self.id = id
        self.name = name
        self.descriptionText = descriptionText
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.review = review
        self.papers = papers
    }
}


// MARK: - Literature Finding


// MARK: - Literature Finding

@Model
final class LiteratureFinding {

    var id: UUID
    var title: String
    var content: String

    var createdAt: Date
    var updatedAt: Date

    // Finding belongs to one Literature Review.
    var review: LiteratureReview?

    // A PaperRecord can support multiple findings.
    @Relationship(
        inverse: \PaperRecord.literatureFindings
    )
    var supportingPapers: [PaperRecord] = []

    // ---------------------------------------------------------
    // Phase 8 — Research Gap Relationship
    // ---------------------------------------------------------

    /// A finding can support multiple research gaps.
    /// This relationship does not own the ResearchGap.
    var researchGaps: [ResearchGap] = []

    init(
        id: UUID = UUID(),
        title: String,
        content: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        review: LiteratureReview? = nil,
        supportingPapers: [PaperRecord] = [],
        researchGaps: [ResearchGap] = []
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.review = review
        self.supportingPapers = supportingPapers
        self.researchGaps = researchGaps
    }
}
// MARK: - Literature Comparison Entry

@Model
final class LiteratureComparisonEntry {

    var id: UUID

    var method: String
    var dataset: String
    var mainFinding: String
    var notes: String

    var createdAt: Date
    var updatedAt: Date

    // Comparison entry belongs to one Literature Review.
    var review: LiteratureReview?

    // Comparison entry is associated with one PaperRecord.
    @Relationship(
        inverse: \PaperRecord.literatureComparisonEntries
    )
    var paper: PaperRecord?

    init(
        id: UUID = UUID(),
        method: String = "",
        dataset: String = "",
        mainFinding: String = "",
        notes: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        review: LiteratureReview? = nil,
        paper: PaperRecord? = nil
    ) {
        self.id = id
        self.method = method
        self.dataset = dataset
        self.mainFinding = mainFinding
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.review = review
        self.paper = paper
    }
}





@Model
final class LiteratureSynthesis {

    var id: UUID

    var commonApproaches: String
    var majorFindings: String
    var areasOfAgreement: String
    var areasOfDisagreement: String
    var methodologicalDifferences: String
    var limitationsAcrossLiterature: String
    var overallSummary: String

    var createdAt: Date
    var updatedAt: Date

    // One synthesis belongs to one Literature Review.
    var review: LiteratureReview?

    init(
        id: UUID = UUID(),
        commonApproaches: String = "",
        majorFindings: String = "",
        areasOfAgreement: String = "",
        areasOfDisagreement: String = "",
        methodologicalDifferences: String = "",
        limitationsAcrossLiterature: String = "",
        overallSummary: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        review: LiteratureReview? = nil
    ) {
        self.id = id
        self.commonApproaches = commonApproaches
        self.majorFindings = majorFindings
        self.areasOfAgreement = areasOfAgreement
        self.areasOfDisagreement = areasOfDisagreement
        self.methodologicalDifferences = methodologicalDifferences
        self.limitationsAcrossLiterature = limitationsAcrossLiterature
        self.overallSummary = overallSummary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.review = review
    }
}
