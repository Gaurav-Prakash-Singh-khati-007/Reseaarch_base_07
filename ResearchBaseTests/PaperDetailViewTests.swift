//
//  PaperDetailViewTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 23/10/26.
//


//
//  PaperDetailViewTests.swift
//  Owner: Agent 68 (tests for PaperDetailView.swift: RBA68Logic)
//

import XCTest
@testable import ResearchBase

@MainActor
final class PaperDetailViewTests: XCTestCase {

    // MARK: F-21

    func testQueryUsesDOIAndOnlyRealArXivLinks() {
        let q = RBA68Logic.query(doi: " https://doi.org/10.1109/CVPR.2016.90 ", urlString: "https://arxiv.org/abs/1706.03762v5")
        XCTAssertEqual(q.doi, "10.1109/cvpr.2016.90")
        XCTAssertEqual(q.arxivID, "1706.03762")

        let plain = RBA68Logic.query(doi: "", urlString: "https://example.com/paper")
        XCTAssertNil(plain.doi)
        XCTAssertNil(plain.arxivID)

        XCTAssertEqual(RBA68Logic.arxivID(fromURLString: "arXiv:1706.03762"), "1706.03762")
    }

    private func result(
        _ status: PublishedVersionResult.Status = .checked,
        retraction: RetractionState = .noneFound,
        publishedDOI: String? = nil
    ) -> PublishedVersionResult {
        PublishedVersionResult(
            status: status, publishedDOI: publishedDOI, publishedVenue: nil, publishedYear: nil,
            retraction: retraction, checkedAt: Date(), sourcesAnswered: ["Crossref"]
        )
    }

    func testBadgePriorityIsRetractionThenConcernThenPublished() {
        XCTAssertEqual(RBA68Logic.versionBadge(result(retraction: .retracted(noticeDOI: nil), publishedDOI: "10.1/x")).kind, .retracted)
        XCTAssertEqual(RBA68Logic.versionBadge(result(retraction: .expressionOfConcern(noticeDOI: nil))).kind, .concern)
        XCTAssertEqual(RBA68Logic.versionBadge(result(publishedDOI: "10.1/x")).kind, .published)
        XCTAssertEqual(RBA68Logic.versionBadge(result()).kind, .clear)
    }

    func testFailedOrOfflineChecksNeverLookLikeAllClear() {
        XCTAssertEqual(RBA68Logic.versionBadge(result(.offline)).kind, .notChecked)
        XCTAssertEqual(RBA68Logic.versionBadge(result(.failed("down"))).kind, .notChecked)
        XCTAssertEqual(RBA68Logic.versionBadge(result(.nothingToCheck)).kind, .notChecked)
    }

    // MARK: F-10

    func testFileKindFromExtension() {
        XCTAssertEqual(RBA68Logic.kind(forFileExtension: "PDF"), .pdf)
        XCTAssertEqual(RBA68Logic.kind(forFileExtension: "py"), .code)
        XCTAssertEqual(RBA68Logic.kind(forFileExtension: "pptx"), .slides)
        XCTAssertEqual(RBA68Logic.kind(forFileExtension: "csv"), .data)
        XCTAssertEqual(RBA68Logic.kind(forFileExtension: "html"), .snapshot)
        XCTAssertEqual(RBA68Logic.kind(forFileExtension: "docx"), .supplement)
    }

    func testSeveralFilesPrimaryFirstAndPrimaryCanChange() throws {
        let model = try ModelTestSupport.makeModel(self, sink: nil)
        defer { model.library.close() }

        let item = try ModelTestSupport.item(model)
        let main = try model.attachments.add(
            fileAt: try ModelTestSupport.makeFile(self, name: "paper.pdf", content: "main \(UUID())"), to: item.id)
        let supp = try model.attachments.add(
            fileAt: try ModelTestSupport.makeFile(self, name: "supp.pdf", content: "supp \(UUID())"),
            to: item.id, kind: .supplement, label: "Appendix")
        let code = try model.attachments.add(
            fileAt: try ModelTestSupport.makeFile(self, name: "train.py", content: "code \(UUID())"),
            to: item.id, kind: .code)

        var files = RBA68Logic.files(model: model, itemID: item.id)
        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(files.first?.id, main.id)
        XCTAssertTrue(files.first?.isPrimary == true)

        try model.attachments.setPrimary(attachmentID: supp.id)
        files = RBA68Logic.files(model: model, itemID: item.id)
        XCTAssertEqual(files.first?.id, supp.id)
        XCTAssertTrue(Set(files.map(\.id)).isSuperset(of: [main.id, code.id]))
    }

    func testFileTextHelpers() {
        func file(label: String, name: String, pages: Int?) -> Attachment {
            Attachment(id: "a", itemID: "i", kind: .supplement, isPrimary: false, label: label,
                       sha256: "", relativePath: "", originalName: name, bytes: 2048,
                       pages: pages, addedAt: "", deletedAt: nil)
        }
        XCTAssertEqual(RBA68Logic.displayName(file(label: " Appendix ", name: "s.pdf", pages: nil)), "Appendix")
        XCTAssertEqual(RBA68Logic.displayName(file(label: "", name: "s.pdf", pages: nil)), "s.pdf")
        XCTAssertEqual(RBA68Logic.displayName(file(label: "", name: "", pages: nil)), "Untitled file")
        XCTAssertTrue(RBA68Logic.detailLine(file(label: "", name: "s.pdf", pages: 1)).hasSuffix("1 page"))
        XCTAssertTrue(RBA68Logic.detailLine(file(label: "", name: "s.pdf", pages: 12)).hasSuffix("12 pages"))
        XCTAssertEqual(RBA68Logic.formatBytes(-5), RBA68Logic.formatBytes(0))
    }

    // MARK: F-25

    func testRelatedShowsWhatThePaperCitesAndWhatCitesIt() throws {
        let model = try ModelTestSupport.makeModel(self, sink: nil)
        defer { model.library.close() }

        let a = try ModelTestSupport.item(model, title: "Paper A")
        let b = try ModelTestSupport.item(model, title: "Paper B")
        try model.links.add(from: LinkEnd(.item, a.id), to: LinkEnd(.item, b.id), rel: .cites)

        let forA = RBA68Logic.loadRelated(model: model, itemID: a.id)
        XCTAssertEqual(forA.graph?.cites.inLibrary.map(\.title), ["Paper B"])
        XCTAssertTrue(forA.graph?.citedBy.inLibrary.isEmpty == true)

        let forB = RBA68Logic.loadRelated(model: model, itemID: b.id)
        XCTAssertEqual(forB.graph?.citedBy.inLibrary.map(\.title), ["Paper A"])
    }

    func testRelatedIsEmptyForAnUnlinkedPaperAndNeverAsksTheNetwork() throws {
        let model = try ModelTestSupport.makeModel(self, sink: nil)
        defer { model.library.close() }

        let lone = try ModelTestSupport.item(model, title: "Lone paper")
        let result = RBA68Logic.loadRelated(model: model, itemID: lone.id)

        XCTAssertTrue(result.graph?.cites.inLibrary.isEmpty == true)
        XCTAssertTrue(result.related.isEmpty)
        if case .libraryOnly? = result.graph?.source {} else {
            XCTFail("expected a library-only graph")
        }
    }

    func testRefLineShowsYearWhenKnown() {
        XCTAssertEqual(RBA68Logic.refLine(CitationLibraryRef(itemID: "1", title: "T", year: 2017)), "T (2017)")
        XCTAssertEqual(RBA68Logic.refLine(CitationLibraryRef(itemID: "1", title: "T", year: nil)), "T")
    }

    // MARK: D1 — the screen reads SQLite

    func testFieldsAreReadFromTheLibraryItem() throws {
        let model = try ModelTestSupport.makeModel(self, sink: nil)
        defer { model.library.close() }

        let item = try ModelTestSupport.item(model, title: "Paper A")
        let tag = try model.tags.findOrCreate(name: "fl")
        try model.tags.assign(tagID: tag.id, to: item.id)

        let fields = try XCTUnwrap(RBA68Logic.fields(model: model, itemID: item.id))
        XCTAssertEqual(fields.title, "Paper A")
        XCTAssertEqual(fields.authors, "McMahan, Brendan")
        XCTAssertEqual(fields.year, 2017)
        XCTAssertEqual(fields.tags, ["fl"])
        XCTAssertEqual(fields.status, .unread)
        XCTAssertEqual(fields.typeLabel, "Conference paper")
        XCTAssertNil(RBA68Logic.fields(model: model, itemID: UUID().uuidString))
    }

    func testStatusAndRatingWriteToTheLibrary() throws {
        let model = try ModelTestSupport.makeModel(self, sink: nil)
        defer { model.library.close() }

        let item = try ModelTestSupport.item(model)
        _ = try ReadingQueueStore(model: model)
            .setStatus(itemID: item.id, RBA68Logic.itemStatus(.reading))
        _ = try model.items.update(id: item.id) { $0.rating = 4 }

        let fields = try XCTUnwrap(RBA68Logic.fields(model: model, itemID: item.id))
        XCTAssertEqual(fields.status, .reading)
        XCTAssertEqual(fields.rating, 4)
        XCTAssertEqual(RBA68Logic.readingStatus(.read), .read)
    }

    func testDeleteIsASoftDeleteThatTheScreenThenCannotSee() throws {
        let model = try ModelTestSupport.makeModel(self, sink: nil)
        defer { model.library.close() }

        let item = try ModelTestSupport.item(model)
        try RBA68Logic.trash(model: model, itemID: item.id)

        XCTAssertNil(RBA68Logic.fields(model: model, itemID: item.id))
        XCTAssertNotNil(try model.items.fetch(id: item.id, includeDeleted: true))
    }

    func testMissingWarnings() {
        let fields = RBA68Fields(
            title: "T", authors: "", venue: "", year: 0, tags: [], status: .unread,
            rating: 0, abstractText: "", doi: "", urlString: "", citationKey: "", typeLabel: ""
        )
        XCTAssertEqual(fields.missingWarnings, ["Missing authors", "Missing year", "Missing venue", "Missing DOI"])
    }
}
