import Foundation
import SwiftData

// MARK: - Publication Type (Phase 6)

enum PublicationType: String, CaseIterable, Codable {

    case journalArticle = "Journal Article"
    case conferencePaper = "Conference Paper"
    case workshopPaper = "Workshop Paper"
    case book = "Book"
    case bookChapter = "Book Chapter"
    case thesis = "Thesis"
    case technicalReport = "Technical Report"
    case preprint = "Preprint"
    case website = "Website"
    case other = "Other"
}


// MARK: - Paper Record

@Model
final class PaperRecord {

    var id: UUID

    var pdfFilePath: String

    var title: String
    var authors: String
    var venue: String
    var year: Int

    var abstractText: String

    var doi: String
    var urlString: String

    var tagsText: String

    var statusRawValue: String
    var rating: Int

    var addedAt: Date
    var lastOpenedAt: Date?

    // ---------------------------------------------------------
    // Phase 6 — Bibliographic / Reference fields
    // ---------------------------------------------------------

    /// Optional user-editable citation key.
    /// Empty string means "not set yet".
    var citationKey: String = ""

    /// Stored raw value for `publicationType`.
    var publicationTypeRawValue: String =
        PublicationType.other.rawValue

    var publisher: String = ""
    var volume: String = ""
    var issue: String = ""
    var pages: String = ""
    var edition: String = ""
    var month: String = ""

    /// Tracks the last time bibliographic metadata was edited.
    /// Optional so existing records migrate cleanly.
    var updatedAt: Date?

    // ---------------------------------------------------------
    // PDF Notes
    // ---------------------------------------------------------

    @Relationship(
        deleteRule: .cascade,
        inverse: \PDFNoteRecord.paper
    )
    var notes: [PDFNoteRecord] = []

    // ---------------------------------------------------------
    // Research Notes
    // ---------------------------------------------------------

    // A paper can have many research notes.
    // The inverse is declared on ResearchNote.linkedPapers.
    var researchNotes: [ResearchNote] = []

    // ---------------------------------------------------------
    // Phase 7 — Literature Review Relationships
    // ---------------------------------------------------------

    // IMPORTANT:
    // These are intentionally plain relationship arrays.
    //
    // The inverse @Relationship declarations are defined on:
    // LiteratureReview
    // LiteratureTheme
    // LiteratureFinding
    //
    // This follows the same SwiftData pattern already used
    // by ResearchNote.linkedPapers and avoids circular
    // @Relationship macro resolution.

    /// A paper can belong to multiple literature reviews.
    var literatureReviews: [LiteratureReview] = []

    /// A paper can belong to multiple literature themes.
    var literatureThemes: [LiteratureTheme] = []

    /// A paper can support multiple literature findings.
    var literatureFindings: [LiteratureFinding] = []
    var literatureComparisonEntries: [LiteratureComparisonEntry] = []

    // ---------------------------------------------------------
    // Phase 8 — Research Gaps / Problems / Ideas Relationships
    // ---------------------------------------------------------

    // Same plain-array pattern as the Phase 7 relationships
    // above. The inverse @Relationship declarations live on
    // ResearchGap.papers, ResearchProblem.papers and
    // ResearchIdea.papers. A paper is never owned by any of
    // these — deleting a gap/problem/idea never deletes the
    // paper, and deleting a paper never deletes the gap/
    // problem/idea, only the relationship.

    /// A paper can support multiple research gaps.
    var linkedResearchGaps: [ResearchGap] = []

    /// A paper can support multiple research problems.
    var linkedResearchProblems: [ResearchProblem] = []

    /// A paper can support multiple research ideas.
    var linkedResearchIdeas: [ResearchIdea] = []


    // MARK: - Initializer

    init(
        id: UUID = UUID(),
        pdfFilePath: String,
        title: String,
        authors: String,
        venue: String,
        year: Int,
        abstractText: String = "",
        doi: String = "",
        urlString: String = "",
        tagsText: String = "",
        statusRawValue: String = "Unread",
        rating: Int = 0,
        addedAt: Date = Date(),
        lastOpenedAt: Date? = nil,
        citationKey: String = "",
        publicationTypeRawValue: String =
            PublicationType.other.rawValue,
        publisher: String = "",
        volume: String = "",
        issue: String = "",
        pages: String = "",
        edition: String = "",
        month: String = "",
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.pdfFilePath = pdfFilePath

        self.title = title
        self.authors = authors
        self.venue = venue
        self.year = year

        self.abstractText = abstractText

        self.doi = doi
        self.urlString = urlString

        self.tagsText = tagsText

        self.statusRawValue = statusRawValue
        self.rating = rating

        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt

        self.citationKey = citationKey
        self.publicationTypeRawValue =
            publicationTypeRawValue

        self.publisher = publisher
        self.volume = volume
        self.issue = issue
        self.pages = pages
        self.edition = edition
        self.month = month
        self.updatedAt = updatedAt
    }


    // MARK: - Tags

    var tags: [String] {
        tagsText
            .split(separator: ",")
            .map {
                $0.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            }
            .filter {
                !$0.isEmpty
            }
    }


    // MARK: - Reading Status

    var readingStatus: ReadingStatus {
        ReadingStatus(
            rawValue: statusRawValue
        ) ?? .unread
    }


    // MARK: - Publication Type

    var publicationType: PublicationType {
        get {
            PublicationType(
                rawValue: publicationTypeRawValue
            ) ?? .other
        }

        set {
            publicationTypeRawValue = newValue.rawValue
        }
    }


    // MARK: - Missing Metadata

    /// Short, subtle warnings about incomplete bibliographic
    /// metadata, used by the Reference Manager.
    var missingMetadataWarnings: [String] {

        var warnings: [String] = []

        if authors
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            .isEmpty {

            warnings.append("Missing authors")
        }

        if year <= 0 {
            warnings.append("Missing year")
        }

        if venue
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            .isEmpty {

            warnings.append("Missing venue")
        }

        if doi
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            .isEmpty {

            warnings.append("Missing DOI")
        }

        return warnings
    }


    // MARK: - Effective Updated Date

    /// Falls back to `addedAt` for records that predate Phase 6.
    var effectiveUpdatedAt: Date {
        updatedAt ?? addedAt
    }
}


// MARK: - PDF Note Record

@Model
final class PDFNoteRecord {

    var id: UUID

    var text: String
    var note: String

    var pageNumber: Int

    var boundsX: Double
    var boundsY: Double
    var boundsWidth: Double
    var boundsHeight: Double

    var createdAt: Date
    var updatedAt: Date

    var paper: PaperRecord?

    init(
        id: UUID = UUID(),
        text: String,
        note: String,
        pageNumber: Int,
        boundsX: Double,
        boundsY: Double,
        boundsWidth: Double,
        boundsHeight: Double,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        paper: PaperRecord? = nil
    ) {
        self.id = id

        self.text = text
        self.note = note

        self.pageNumber = pageNumber

        self.boundsX = boundsX
        self.boundsY = boundsY
        self.boundsWidth = boundsWidth
        self.boundsHeight = boundsHeight

        self.createdAt = createdAt
        self.updatedAt = updatedAt

        self.paper = paper
    }
}


// MARK: - Research Note

@Model
final class ResearchNote {

    var id: UUID

    var title: String
    var content: String

    var typeRawValue: String
    var tagsText: String

    var createdAt: Date
    var updatedAt: Date

    // A note can link to many papers, and a paper can have
    // many notes.
    @Relationship(
        inverse: \PaperRecord.researchNotes
    )
    var linkedPapers: [PaperRecord] = []

    // ---------------------------------------------------------
    // Phase 8 — Research Idea Relationship
    // ---------------------------------------------------------

    /// A note can be referenced by multiple research ideas.
    /// The inverse @Relationship lives on ResearchIdea.notes.
    /// Deleting an idea never deletes the note.
    var linkedIdeas: [ResearchIdea] = []

    init(
        id: UUID = UUID(),
        title: String,
        content: String,
        typeRawValue: String,
        tagsText: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        linkedPapers: [PaperRecord] = []
    ) {
        self.id = id

        self.title = title
        self.content = content

        self.typeRawValue = typeRawValue
        self.tagsText = tagsText

        self.createdAt = createdAt
        self.updatedAt = updatedAt

        self.linkedPapers = linkedPapers
    }


    // MARK: - Note Type

    var noteType: ResearchNoteType {
        ResearchNoteType(
            rawValue: typeRawValue
        ) ?? .concept
    }


    // MARK: - Tags

    var tags: [String] {
        tagsText
            .split(separator: ",")
            .map {
                $0.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            }
            .filter {
                !$0.isEmpty
            }
    }
}


// MARK: - Research Note Type

enum ResearchNoteType: String, CaseIterable, Codable {

    case concept = "Concept"
    case method = "Method"
    case finding = "Finding"
    case definition = "Definition"
    case importantQuote = "Important Quote"
    case criticism = "Criticism"
    case researchGap = "Research Gap"
    case personalInsight = "Personal Insight"
}
