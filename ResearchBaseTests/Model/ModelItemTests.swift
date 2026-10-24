//
//  ModelItemTests.swift
//  ResearchBaseTests
//
//  Phase 1, Step 1B (F-07, F-14) and the shared model plumbing.
//

import XCTest
@testable import ResearchBase

@MainActor
final class ModelItemTests: XCTestCase {

    // MARK: Create

    func testCreateStoresItemCreatorsAndKey() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let item = try model.items.create(NewItem(
            type: .conference,
            title: "  Communication-Efficient Learning of Deep Networks  ",
            creators: [
                CreatorInput(family: "McMahan", given: "H. Brendan"),
                CreatorInput(family: "Moore", given: "Eider")
            ],
            year: 2017,
            venue: "AISTATS",
            doi: "https://doi.org/10.5555/ABC"
        ))

        XCTAssertEqual(item.title, "Communication-Efficient Learning of Deep Networks")
        XCTAssertEqual(item.citationKey, "mcmahan2017communication")
        XCTAssertEqual(item.doi, "10.5555/abc")
        XCTAssertFalse(item.keyLocked)
        XCTAssertNil(item.deletedAt)

        let people = try model.creators.creators(of: item.id)
        XCTAssertEqual(people.map { $0.creator.family }, ["McMahan", "Moore"])
        XCTAssertEqual(people.map { $0.position }, [0, 1])
    }

    func testCaptureFieldsAreRecordedAndInboxItemsAreSeparate() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let captured = try model.items.create(NewItem(
            title: "From the browser",
            sourceKind: .browser,
            sourceURL: "https://example.org/paper",
            reviewState: .inbox
        ))

        XCTAssertEqual(captured.sourceKind, .browser)
        XCTAssertEqual(captured.sourceURL, "https://example.org/paper")
        XCTAssertEqual(captured.reviewState, .inbox)
        XCTAssertNotNil(captured.capturedAt)

        try ModelTestSupport.item(model)

        XCTAssertEqual(try model.items.count(reviewState: .inbox), 1)
        XCTAssertEqual(try model.items.count(reviewState: .accepted), 1)
        XCTAssertEqual(try model.items.count(), 2)
    }

    func testEmptyTitleIsRefusedAndNothingIsSaved() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        XCTAssertThrowsError(try model.items.create(NewItem(title: "   "))) { error in
            XCTAssertEqual(error as? ModelError, .emptyName)
        }
        XCTAssertEqual(try ModelTestSupport.count(model, "items"), 0)
    }

    func testFailedCreateLeavesNothingBehind() throws {

        // The sink fails on its 2nd report. By then the creator and the item rows are written.
        let model = try ModelTestSupport.makeModel(self, sink: FailingChangeSink(failOnCall: 1))
        defer { model.library.close() }

        XCTAssertThrowsError(try ModelTestSupport.item(model))

        XCTAssertEqual(try ModelTestSupport.count(model, "items"), 0)
        XCTAssertEqual(try ModelTestSupport.count(model, "creators"), 0)
        XCTAssertEqual(try ModelTestSupport.count(model, "item_creators"), 0)
    }

    func testBadCreatorStopsTheWholeCreate() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        XCTAssertThrowsError(try model.items.create(NewItem(
            title: "Has a nameless author",
            creators: [CreatorInput(family: "Fine"), CreatorInput(family: "  ")]
        )))
        XCTAssertEqual(try ModelTestSupport.count(model, "items"), 0)
        XCTAssertEqual(try ModelTestSupport.count(model, "creators"), 0)
    }

    // MARK: Item types (F-07)

    func testTenItemTypesWithTheHTMLNamesAndFields() {

        XCTAssertEqual(ItemType.allCases.count, 10)
        XCTAssertEqual(ItemType.webpage.displayName, "Web page")
        XCTAssertEqual(ItemType.article.fields.map { $0.label }, ["Journal", "Volume", "Issue", "Pages"])
        XCTAssertEqual(ItemType.webpage.fields.map { $0.label }, ["Website", "Accessed on"])
        XCTAssertEqual(ItemType.software.fields.map { $0.label }, ["Repository URL", "Version"])
        XCTAssertEqual(ItemType.thesis.fields.map { $0.label }, ["University", "Thesis type"])
    }

    func testEveryFieldWithAColumnReallyIsAColumnOfItems() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let columns = Set(try model.database.rows("PRAGMA table_info(items)").compactMap { $0.text("name") })

        for type in ItemType.allCases {
            for spec in type.fields where spec.field.hasColumn {
                let column = try XCTUnwrap(spec.field.column, "\(spec.label) has no column name")
                XCTAssertTrue(columns.contains(column), "\(type) field \(spec.label): no column \(column)")
            }
        }
    }

    func testFieldsThatHaveNoColumnYetAreFlagged() {
        // The HTML shows these four, docs/schema.sql has no column for them (reported as a question).
        for field in [ItemField.thesisType, .reportNumber, .accessedOn, .version] {
            XCTAssertFalse(field.hasColumn)
            XCTAssertNil(field.column)
        }
    }

    func testChangingTheTypeKeepsEveryValue() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let item = try model.items.create(NewItem(type: .article, title: "Typed", venue: "Nature", pages: "1--9"))
        let changed = try model.items.update(id: item.id) { $0.type = .book }

        XCTAssertEqual(changed.type, .book)
        XCTAssertEqual(changed.venue, "Nature")
        XCTAssertEqual(changed.pages, "1--9")
    }

    // MARK: Edit

    func testUpdateWritesOnlyWhatChangedAndReportsOldAndNew() throws {

        let sink = RecordingChangeSink()
        let model = try ModelTestSupport.makeModel(self, sink: sink)
        defer { model.library.close() }

        let item = try ModelTestSupport.item(model)
        sink.clear()

        let updated = try model.items.update(id: item.id) {
            $0.title = "A new title"
            $0.year = 2018
        }

        XCTAssertEqual(updated.title, "A new title")
        XCTAssertEqual(try model.items.fetch(id: item.id)?.year, 2018)

        let fields = Set(sink.entries(type: "item", action: .update).compactMap { $0.field })
        XCTAssertEqual(fields, ["title", "year"])

        let title = try XCTUnwrap(sink.entries(type: "item", field: "title").first)
        XCTAssertEqual(title.oldValue, "Communication-Efficient Learning of Deep Networks")
        XCTAssertEqual(title.newValue, "A new title")
    }

    func testUpdateWithNoChangeReportsNothing() throws {

        let sink = RecordingChangeSink()
        let model = try ModelTestSupport.makeModel(self, sink: sink)
        defer { model.library.close() }

        let item = try ModelTestSupport.item(model)
        sink.clear()

        let same = try model.items.update(id: item.id) { _ in }

        XCTAssertEqual(same, item)
        XCTAssertTrue(sink.entries.isEmpty)
    }

    func testProtectedFieldsCannotBeEditedThroughUpdate() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let item = try ModelTestSupport.item(model)

        XCTAssertThrowsError(try model.items.update(id: item.id) { $0.citationKey = "hacked" })
        XCTAssertThrowsError(try model.items.update(id: item.id) { $0.keyLocked = true })
        XCTAssertThrowsError(try model.items.update(id: item.id) { $0.deletedAt = "2026-01-01T00:00:00.000Z" })
        XCTAssertThrowsError(try model.items.update(id: item.id) { $0.rating = 9 })
        XCTAssertThrowsError(try model.items.update(id: item.id) { $0.title = "  " })

        let after = try XCTUnwrap(try model.items.fetch(id: item.id))
        XCTAssertEqual(after, item)
    }

    func testDOIIsStoredWithoutUrlPrefixAndInLowerCase() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let item = try ModelTestSupport.item(model)
        let updated = try model.items.update(id: item.id) { $0.doi = "DOI:10.1000/XYZ" }

        XCTAssertEqual(updated.doi, "10.1000/xyz")
        XCTAssertEqual(TextNormalizer.doi("  https://dx.doi.org/10.1/A "), "10.1/a")
        XCTAssertNil(TextNormalizer.doi("   "))
        XCTAssertEqual(TextNormalizer.arxivID("arXiv:1602.05629"), "1602.05629")
    }

    func testListNewestFirstAndItemsInTheTrashAreHidden() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let first = try ModelTestSupport.item(model, title: "First", author: "A")
        _ = try ModelTestSupport.item(model, title: "Second", author: "B")
        try ModelTestSupport.trash(model, itemID: first.id)

        XCTAssertEqual(try model.items.list().map { $0.title }, ["Second"])
        XCTAssertNil(try model.items.fetch(id: first.id))
        XCTAssertNotNil(try model.items.fetch(id: first.id, includeDeleted: true))
        XCTAssertEqual(try model.items.count(), 1)
    }

    // MARK: Plumbing

    func testNestedAtomicallyJoinsTheOuterAndRollsBackTogether() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        struct Boom: Error {}

        XCTAssertThrowsError(try model.atomically { () throws -> Void in
            try model.tags.create(name: "kept?")
            try model.collections.create(name: "kept too?")
            throw Boom()
        })

        XCTAssertEqual(try ModelTestSupport.count(model, "tags"), 0)
        XCTAssertEqual(try ModelTestSupport.count(model, "collections"), 0)

        try model.atomically {
            try model.tags.create(name: "kept")
            try model.collections.create(name: "kept too")
        }
        XCTAssertEqual(try ModelTestSupport.count(model, "tags"), 1)
        XCTAssertEqual(try ModelTestSupport.count(model, "collections"), 1)
    }

    func testDataSurvivesClosingAndReopening() throws {

        let folder = try TestSupport.makeTempDirectory(self)
            .appendingPathComponent(Library.folderName, isDirectory: true)

        let first = LibraryModel(library: try Library.open(at: folder))
        let item = try ModelTestSupport.item(first)
        try first.tags.assign(tagID: try first.tags.create(name: "kept").id, to: item.id)
        first.library.close()

        let second = LibraryModel(library: try Library.open(at: folder))
        defer { second.library.close() }

        XCTAssertEqual(try second.items.fetch(id: item.id)?.title, item.title)
        XCTAssertEqual(try second.tags.tags(of: item.id).map { $0.name }, ["kept"])
    }
}
