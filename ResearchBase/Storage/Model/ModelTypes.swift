//
//  ModelTypes.swift
//  ResearchBase
//
//  Phase 1, Step 1B (F-06, F-07, F-08, F-09, F-10, F-14)
//
//  Plain value types for rows of docs/schema.sql. Raw values are the
//  exact strings the schema's CHECK constraints allow.
//

import Foundation

// MARK: - Item types (F-07)

/// Names exactly as in the HTML (TYPEL).
enum ItemType: String, CaseIterable, Equatable {

    case article, preprint, conference, book, chapter, thesis, report, webpage, dataset, software

    var displayName: String {
        switch self {
        case .article: return "Journal article"
        case .preprint: return "Preprint"
        case .conference: return "Conference paper"
        case .book: return "Book"
        case .chapter: return "Book chapter"
        case .thesis: return "Thesis"
        case .report: return "Report"
        case .webpage: return "Web page"
        case .dataset: return "Dataset"
        case .software: return "Software"
        }
    }

    /// The type-specific fields the HTML shows (FIELDS), in order.
    var fields: [ItemFieldSpec] {
        switch self {
        case .article:
            return [.init(.venue, "Journal"), .init(.volume, "Volume"), .init(.issue, "Issue"), .init(.pages, "Pages")]
        case .preprint:
            return [.init(.venue, "Repository"), .init(.arxivID, "arXiv ID")]
        case .conference:
            return [.init(.venue, "Proceedings"), .init(.volume, "Volume"), .init(.pages, "Pages")]
        case .book:
            return [.init(.publisher, "Publisher"), .init(.edition, "Edition")]
        case .chapter:
            return [.init(.venue, "Book title"), .init(.publisher, "Publisher"), .init(.pages, "Pages")]
        case .thesis:
            return [.init(.publisher, "University"), .init(.thesisType, "Thesis type")]
        case .report:
            return [.init(.publisher, "Institution"), .init(.reportNumber, "Report number")]
        case .webpage:
            return [.init(.url, "Website"), .init(.accessedOn, "Accessed on")]
        case .dataset:
            return [.init(.publisher, "Repository"), .init(.version, "Version")]
        case .software:
            return [.init(.url, "Repository URL"), .init(.version, "Version")]
        }
    }
}

/// A field a form can show. The last four appear in the HTML but have
/// NO column in docs/schema.sql yet (see `hasColumn`). They are listed
/// so the screen can be built; saving them needs a decision from the owner.
enum ItemField: String, Equatable {

    case venue, volume, issue, pages, publisher, edition, url, arxivID
    case thesisType, reportNumber, accessedOn, version

    var hasColumn: Bool {
        switch self {
        case .thesisType, .reportNumber, .accessedOn, .version: return false
        default: return true
        }
    }

    /// Column in `items`, or nil when the schema has none.
    var column: String? {
        switch self {
        case .venue: return "venue"
        case .volume: return "volume"
        case .issue: return "issue"
        case .pages: return "pages"
        case .publisher: return "publisher"
        case .edition: return "edition"
        case .url: return "url"
        case .arxivID: return "arxiv_id"
        default: return nil
        }
    }
}

struct ItemFieldSpec: Equatable {
    let field: ItemField
    let label: String
    init(_ field: ItemField, _ label: String) {
        self.field = field
        self.label = label
    }
}

// MARK: - Capture provenance (F-14)

enum SourceKind: String, CaseIterable, Equatable {
    case manual, doi, arxiv, url
    case pdfDrop = "pdf_drop"
    case `import`
    case browser
    case inboxFolder = "inbox_folder"
}

enum ReviewState: String, Equatable {
    case inbox, accepted
}

enum ItemReadingStatus: String, Equatable {
    case unread, reading, read
}

// MARK: - Items

struct ModelItem: Equatable {
    var id: String
    var type: ItemType
    var title: String
    var abstract: String
    var venue: String
    var year: Int?
    var month: String
    var volume: String
    var issue: String
    var pages: String
    var publisher: String
    var edition: String
    var doi: String?
    var arxivID: String?
    var url: String
    var citationKey: String
    var keyLocked: Bool
    var readingStatus: ItemReadingStatus
    var inQueue: Bool
    var rating: Int
    var language: String
    var sourceURL: String
    var sourceKind: SourceKind
    var capturedAt: String?
    var reviewState: ReviewState
    var addedAt: String
    var updatedAt: String
    var deletedAt: String?
}

/// What a caller gives to create an item. Everything else has a default.
struct NewItem {
    var type: ItemType = .article
    var title: String
    var creators: [CreatorInput] = []
    var year: Int?
    var venue: String = ""
    var abstract: String = ""
    var volume: String = ""
    var issue: String = ""
    var pages: String = ""
    var publisher: String = ""
    var doi: String?
    var arxivID: String?
    var url: String = ""
    var sourceKind: SourceKind = .manual
    var sourceURL: String = ""
    var reviewState: ReviewState = .accepted
}

// MARK: - Creators (F-08)

struct Creator: Equatable {
    var id: String
    var family: String
    var given: String
    var suffix: String
    var isOrganisation: Bool
    var orcid: String?
    var norm: String

    /// "Family, Given" (or just the organisation name).
    var displayName: String {
        if isOrganisation || given.isEmpty { return family }
        return suffix.isEmpty ? "\(family), \(given)" : "\(family), \(suffix), \(given)"
    }
}

enum CreatorRole: String, CaseIterable, Equatable {
    case author, editor, translator
}

struct CreatorInput: Equatable {
    var family: String
    var given: String = ""
    var suffix: String = ""
    var isOrganisation: Bool = false
    var orcid: String?
    var role: CreatorRole = .author
}

struct ItemCreator: Equatable {
    let creator: Creator
    let role: CreatorRole
    let position: Int
}

// MARK: - Tags

struct Tag: Equatable {
    var id: String
    var name: String
    var color: String
}

struct TagUsage: Equatable {
    let tag: Tag
    let itemCount: Int
}

// MARK: - Collections and saved searches (F-09)

struct ModelCollection: Equatable {
    var id: String
    var parentID: String?
    var name: String
    var position: Int
    var deletedAt: String?
}

struct SavedSearch: Equatable {
    var id: String
    var name: String
    var rules: [SearchRule]
    var matchAll: Bool
    var position: Int
}

// MARK: - Attachments (F-10)

enum AttachmentKind: String, CaseIterable, Equatable {
    case pdf, supplement, code, slides, data, snapshot, other
}

struct Attachment: Equatable {
    var id: String
    var itemID: String
    var kind: AttachmentKind
    var isPrimary: Bool
    var label: String
    var sha256: String
    var relativePath: String
    var originalName: String
    var bytes: Int64
    var pages: Int?
    var addedAt: String
    var deletedAt: String?
}

// MARK: - Links (F-06)

/// What a link can point at. The table is where the existence check looks.
enum LinkEntity: String, CaseIterable, Equatable {
    case item, thought, experiment, draft, project, task, review, collection

    var table: String {
        switch self {
        case .item: return "items"
        case .thought: return "thoughts"
        case .experiment: return "experiments"
        case .draft: return "drafts"
        case .project: return "projects"
        case .task: return "tasks"
        case .review: return "reviews"
        case .collection: return "collections"
        }
    }
}

enum LinkRel: String, CaseIterable, Equatable {
    case related, cites, supports, contradicts, uses, extends
    case partOf = "part_of"
    case derivedFrom = "derived_from"
}

struct LinkEnd: Hashable {
    let type: LinkEntity
    let id: String
    init(_ type: LinkEntity, _ id: String) {
        self.type = type
        self.id = id
    }
}

struct ModelLink: Equatable {
    let id: String
    let from: LinkEnd
    let to: LinkEnd
    let rel: LinkRel
    let note: String
    let createdAt: String
}

enum LinkDirection: Equatable {
    /// The asked-about record is the "from" side.
    case outgoing
    /// The asked-about record is the "to" side.
    case incoming
}

/// One link as seen from one record. `other` is the record on the far end.
struct LinkedEntry: Equatable {
    let link: ModelLink
    let other: LinkEnd
    let direction: LinkDirection
}
