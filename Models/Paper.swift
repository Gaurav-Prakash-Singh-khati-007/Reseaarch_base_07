import Foundation

struct Paper: Identifiable {

    let id: UUID

    let title: String
    let authors: String
    let venue: String
    let year: Int

    let tags: [String]
    let status: ReadingStatus
    let rating: Int

    let abstractText: String

    let doi: String
    let urlString: String

    let pdfFilePath: String

    let addedAt: Date
    let lastOpenedAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        authors: String,
        venue: String,
        year: Int,
        tags: [String] = [],
        status: ReadingStatus = .unread,
        rating: Int = 0,
        abstractText: String = "",
        doi: String = "",
        urlString: String = "",
        pdfFilePath: String = "",
        addedAt: Date = Date(),
        lastOpenedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.authors = authors
        self.venue = venue
        self.year = year
        self.tags = tags
        self.status = status
        self.rating = rating
        self.abstractText = abstractText
        self.doi = doi
        self.urlString = urlString
        self.pdfFilePath = pdfFilePath
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
    }
}

enum ReadingStatus: String, CaseIterable, Codable {

    case unread = "Unread"
    case reading = "Reading"
    case read = "Read"
}
