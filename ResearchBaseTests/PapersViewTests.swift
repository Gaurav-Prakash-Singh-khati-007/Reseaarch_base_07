//
//  PapersViewTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 23/10/26.
//


//
//  PapersViewTests.swift
//  Owner: Agent 69 (tests for PapersView.swift: RBA69Logic and the queue it shows)
//

import XCTest
@testable import ResearchBase

@MainActor
final class PapersViewTests: XCTestCase {

    // MARK: Ordering

    func testOrderedKeepsOnlyQueuedItemsInQueueOrder() {
        let papers = ["a", "b", "c", "d"]
        XCTAssertEqual(RBA69Logic.ordered(papers, id: { $0 }, queueIDs: ["c", "a"]), ["c", "a"])
    }

    func testOrderedIgnoresUnknownIDsAndRepeats() {
        let papers = ["a", "b"]
        XCTAssertEqual(RBA69Logic.ordered(papers, id: { $0 }, queueIDs: ["x", "b", "b", "a"]), ["b", "a"])
        XCTAssertTrue(RBA69Logic.ordered(papers, id: { $0 }, queueIDs: []).isEmpty)
    }

    func testMoveTargets() {
        XCTAssertEqual(RBA69Logic.moveTargets(position: 0, count: 3).up, nil)
        XCTAssertEqual(RBA69Logic.moveTargets(position: 0, count: 3).down, 1)
        XCTAssertEqual(RBA69Logic.moveTargets(position: 1, count: 3).up, 0)
        XCTAssertEqual(RBA69Logic.moveTargets(position: 1, count: 3).down, 2)
        XCTAssertEqual(RBA69Logic.moveTargets(position: 2, count: 3).down, nil)
        XCTAssertNil(RBA69Logic.moveTargets(position: nil, count: 3).up)
        XCTAssertNil(RBA69Logic.moveTargets(position: nil, count: 3).down)
        XCTAssertNil(RBA69Logic.moveTargets(position: 7, count: 3).up)
    }

    // MARK: Text

    func testDurationText() {
        XCTAssertEqual(RBA69Logic.formatDuration(seconds: 20), "under a minute")
        XCTAssertEqual(RBA69Logic.formatDuration(seconds: 12 * 60), "12 min")
        XCTAssertEqual(RBA69Logic.formatDuration(seconds: 3600), "1 h")
        XCTAssertEqual(RBA69Logic.formatDuration(seconds: 72 * 60), "1 h 12 min")
        XCTAssertEqual(RBA69Logic.formatDuration(seconds: -5), "under a minute")
    }

    func testQueueSubtitle() {
        XCTAssertEqual(RBA69Logic.queueSubtitle(count: 0, totalSeconds: 0), "Reading queue · nothing to read")
        XCTAssertEqual(RBA69Logic.queueSubtitle(count: 1, totalSeconds: 10), "Reading queue · 1 paper to read")
        XCTAssertEqual(
            RBA69Logic.queueSubtitle(count: 4, totalSeconds: 130 * 60),
            "Reading queue · 4 papers to read · 2 h 10 min read in total"
        )
    }

    // MARK: The library queue this screen shows

    func testQueueRoundTripThroughTheLibrary() throws {
        let model = try ModelTestSupport.makeModel(self, sink: nil)
        defer { model.library.close() }

        let a = try ModelTestSupport.item(model, title: "Paper A")
        let b = try ModelTestSupport.item(model, title: "Paper B")
        let c = try ModelTestSupport.item(model, title: "Paper C")
        let queue = ReadingQueueStore(model: model)

        try queue.add(itemID: a.id)
        try queue.add(itemID: b.id)
        try queue.add(itemID: c.id)
        XCTAssertEqual(try queue.queue().map(\.id), [a.id, b.id, c.id])

        // "Move to Top" on C, then "Move Down" on C.
        try queue.move(itemID: c.id, toIndex: 0)
        XCTAssertEqual(try queue.queue().map(\.id), [c.id, a.id, b.id])
        try queue.move(itemID: c.id, toIndex: 1)
        XCTAssertEqual(try queue.queue().map(\.id), [a.id, c.id, b.id])

        // The screen shows the library's papers in exactly this order.
        let shown = RBA69Logic.ordered(
            [b, c, a], id: { $0.id }, queueIDs: try queue.queue().map(\.id)
        )
        XCTAssertEqual(shown.map(\.title), ["Paper A", "Paper C", "Paper B"])

        try queue.remove(itemID: c.id)
        XCTAssertEqual(try queue.queue().map(\.id), [a.id, b.id])
        XCTAssertEqual(try queue.stats().queued, 2)
    }

    func testQueueingAPaperThatIsNotInTheLibraryFailsInsteadOfPretending() throws {
        let model = try ModelTestSupport.makeModel(self, sink: nil)
        defer { model.library.close() }

        let queue = ReadingQueueStore(model: model)
        XCTAssertThrowsError(try queue.add(itemID: UUID().uuidString))
        XCTAssertEqual(try queue.queueCount(), 0)
    }

    // MARK: SQLite-backed list (D1)

    private func row(
        _ title: String, year: Int? = 2020, status: ItemReadingStatus = .unread,
        tags: [String] = [], pdf: RBA69PDFState = .none, authors: String = "",
        rating: Int = 0, added: String = "2026-01-01T00:00:00Z"
    ) -> RBA69Row {
        let item = ModelItem(
            id: UUID().uuidString, type: .article, title: title, abstract: "", venue: "",
            year: year, month: "", volume: "", issue: "", pages: "", publisher: "", edition: "",
            doi: nil, arxivID: nil, url: "", citationKey: "", keyLocked: false,
            readingStatus: status, inQueue: false, rating: rating, language: "",
            sourceURL: "", sourceKind: .manual, capturedAt: nil, reviewState: .accepted,
            addedAt: added, updatedAt: added, deletedAt: nil
        )
        return RBA69Row(item: item, authors: authors, tags: tags, pdf: pdf)
    }

    func testFiltersSearchStatusTagAndPDF() {
        let rows = [
            row("Federated Learning", status: .reading, tags: ["fl"], pdf: .available, authors: "McMahan, Brendan"),
            row("Graph Networks", status: .read, tags: ["gnn"], pdf: .missing),
            row("Old Survey", status: .unread, pdf: .none)
        ]

        var f = RBA69Filters()
        f.searchText = "mcmahan federated"
        XCTAssertEqual(f.apply(to: rows).map(\.item.title), ["Federated Learning"])

        f = RBA69Filters(); f.status = .read
        XCTAssertEqual(f.apply(to: rows).map(\.item.title), ["Graph Networks"])

        f = RBA69Filters(); f.tag = "FL"
        XCTAssertEqual(f.apply(to: rows).map(\.item.title), ["Federated Learning"])

        f = RBA69Filters(); f.pdf = .withPDF
        XCTAssertEqual(f.apply(to: rows).count, 1)
        f.pdf = .withoutPDF
        XCTAssertEqual(f.apply(to: rows).count, 2)

        XCTAssertTrue(f.isFiltering)
        f.reset()
        XCTAssertFalse(f.isFiltering)
        XCTAssertEqual(RBA69Filters.count(for: .read, in: rows), 1)
        XCTAssertEqual(RBA69Filters.allTags(in: rows), ["fl", "gnn"])
    }

    func testFiltersSort() {
        let rows = [
            row("B", year: 2019, rating: 2, added: "2026-01-02T00:00:00Z"),
            row("A", year: nil, rating: 5, added: "2026-01-03T00:00:00Z"),
            row("C", year: 2021, rating: 2, added: "2026-01-01T00:00:00Z")
        ]
        var f = RBA69Filters()
        XCTAssertEqual(f.apply(to: rows).map(\.item.title), ["A", "B", "C"])
        f.sort = .titleAZ
        XCTAssertEqual(f.apply(to: rows).map(\.item.title), ["A", "B", "C"])
        f.sort = .yearNewest
        XCTAssertEqual(f.apply(to: rows).map(\.item.title), ["C", "B", "A"])
        f.sort = .yearOldest
        XCTAssertEqual(f.apply(to: rows).map(\.item.title), ["B", "C", "A"])
        f.sort = .highestRated
        XCTAssertEqual(f.apply(to: rows).map(\.item.title), ["A", "B", "C"])
    }

    func testFolderFlattenOrdersParentsBeforeChildrenAndSurvivesLoops() {
        func c(_ id: String, _ parent: String?, _ name: String, _ pos: Int) -> ModelCollection {
            ModelCollection(id: id, parentID: parent, name: name, position: pos, deletedAt: nil)
        }
        let flat = RBA69Folders.flatten([
            c("2", "1", "Child", 0), c("1", nil, "Top", 0), c("3", "x", "Orphan", 1),
            c("a", "b", "LoopA", 5), c("b", "a", "LoopB", 6)
        ])
        XCTAssertEqual(Array(flat.prefix(3)).map(\.name), ["Top", "Child", "Orphan"])
        XCTAssertEqual(flat.first(where: { $0.name == "Child" })?.depth, 1)
        XCTAssertEqual(Set(flat.map(\.id)).count, flat.count)
    }

    func testLoaderReadsAcceptedPapersWithAuthorsTagsAndFolders() throws {
        let model = try ModelTestSupport.makeModel(self, sink: nil)
        defer { model.library.close() }

        let a = try ModelTestSupport.item(model, title: "Paper A")
        _ = try ModelTestSupport.item(model, title: "In the inbox", state: .inbox)
        let tag = try model.tags.findOrCreate(name: "fl")
        try model.tags.assign(tagID: tag.id, to: a.id)
        let folder = try model.collections.create(name: "Thesis")
        try model.collections.addItem(a.id, to: folder.id)

        let rows = try RBA69Loader.rows(model: model)
        XCTAssertEqual(rows.map(\.item.title), ["Paper A"])
        XCTAssertEqual(rows.first?.authors, "McMahan, Brendan")
        XCTAssertEqual(rows.first?.tags, ["fl"])
        XCTAssertEqual(rows.first?.pdf, RBA69PDFState.none)

        let members = try model.collections.items(in: folder.id, includeSubfolders: true)
        XCTAssertEqual(members.map(\.id), [a.id])
        // A library item id is a UUID string, so the router can open it.
        XCTAssertNotNil(UUID(uuidString: a.id))
    }
}
