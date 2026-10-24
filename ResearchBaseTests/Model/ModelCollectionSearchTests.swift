//
//  ModelCollectionSearchTests.swift
//  ResearchBaseTests
//
//  Phase 1, Step 1B (F-09): nested folders and rule-based smart lists.
//

import XCTest
@testable import ResearchBase

@MainActor
final class ModelCollectionSearchTests: XCTestCase {

    // MARK: Folders

    func testFoldersNestAndHaveABreadcrumb() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let a = try model.collections.create(name: "Thesis")
        let b = try model.collections.create(name: "Chapter 2", parentID: a.id)
        let c = try model.collections.create(name: "Background", parentID: b.id)
        let other = try model.collections.create(name: "Reading")

        XCTAssertEqual(try model.collections.path(of: c.id).map { $0.name }, ["Thesis", "Chapter 2", "Background"])
        XCTAssertEqual(try model.collections.children(of: nil).map { $0.name }, ["Thesis", "Reading"])
        XCTAssertEqual(try model.collections.children(of: a.id).map { $0.name }, ["Chapter 2"])
        XCTAssertEqual(Set(try model.collections.subtreeIDs(of: a.id)), [a.id, b.id, c.id])
        XCTAssertEqual(other.position, 1)
    }

    func testAFolderCannotMoveInsideItselfOrItsOwnSubfolder() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let a = try model.collections.create(name: "A")
        let b = try model.collections.create(name: "B", parentID: a.id)
        let c = try model.collections.create(name: "C", parentID: b.id)

        XCTAssertThrowsError(try model.collections.move(id: a.id, toParent: a.id)) {
            XCTAssertEqual($0 as? ModelError, .collectionCycle)
        }
        XCTAssertThrowsError(try model.collections.move(id: a.id, toParent: c.id)) {
            XCTAssertEqual($0 as? ModelError, .collectionCycle)
        }
        XCTAssertEqual(try model.collections.collection(id: a.id)?.parentID, nil)

        let moved = try model.collections.move(id: c.id, toParent: nil)
        XCTAssertNil(moved.parentID)
        XCTAssertEqual(try model.collections.path(of: c.id).map { $0.name }, ["C"])

        XCTAssertThrowsError(try model.collections.move(id: c.id, toParent: "missing")) {
            XCTAssertEqual($0 as? ModelError, .collectionMissing("missing"))
        }
    }

    func testReorderRenameAndMissingParent() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let a = try model.collections.create(name: "A")
        let b = try model.collections.create(name: "B")
        let c = try model.collections.create(name: "C")

        try model.collections.reorder(parentID: nil, orderedIDs: [c.id, a.id])
        XCTAssertEqual(try model.collections.children(of: nil).map { $0.name }, ["C", "A", "B"])

        XCTAssertEqual(try model.collections.rename(id: b.id, to: "  Bee ").name, "Bee")
        XCTAssertThrowsError(try model.collections.rename(id: b.id, to: " ")) {
            XCTAssertEqual($0 as? ModelError, .emptyName)
        }
        XCTAssertThrowsError(try model.collections.create(name: "Orphan", parentID: "nope"))
    }

    func testItemsInFoldersIncludingSubfoldersAndManyFolders() throws {

        let sink = RecordingChangeSink()
        let model = try ModelTestSupport.makeModel(self, sink: sink)
        defer { model.library.close() }

        let a = try model.collections.create(name: "A")
        let b = try model.collections.create(name: "B", parentID: a.id)
        let c = try model.collections.create(name: "C", parentID: b.id)

        let both = try ModelTestSupport.item(model, title: "Both", author: "X")
        let onlyC = try ModelTestSupport.item(model, title: "OnlyC", author: "Y")
        let trashed = try ModelTestSupport.item(model, title: "Gone", author: "Z")

        try model.collections.addItem(both.id, to: b.id)
        try model.collections.addItem(both.id, to: c.id)
        try model.collections.addItem(onlyC.id, to: c.id)
        try model.collections.addItem(trashed.id, to: c.id)
        sink.clear()
        try model.collections.addItem(both.id, to: b.id)   // twice: no change
        XCTAssertTrue(sink.entries.isEmpty)

        try ModelTestSupport.trash(model, itemID: trashed.id)

        XCTAssertTrue(try model.collections.items(in: a.id).isEmpty)
        XCTAssertEqual(Set(try model.collections.items(in: a.id, includeSubfolders: true).map { $0.title }), ["Both", "OnlyC"])
        XCTAssertEqual(try model.collections.items(in: a.id, includeSubfolders: true).count, 2, "an item in two folders is listed once")
        XCTAssertEqual(try model.collections.collections(containing: both.id).count, 2)

        try model.collections.removeItem(both.id, from: b.id)
        XCTAssertEqual(try model.collections.collections(containing: both.id).map { $0.name }, ["C"])
        XCTAssertNotNil(try model.items.fetch(id: both.id), "taking an item out of a folder keeps the paper")
    }

    func testTrashedFoldersAreHidden() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let a = try model.collections.create(name: "A")
        let b = try model.collections.create(name: "B", parentID: a.id)
        try model.database.run("UPDATE collections SET deleted_at = ? WHERE id = ?", [.text(Library.nowISO()), .text(b.id)])

        XCTAssertTrue(try model.collections.children(of: a.id).isEmpty)
        XCTAssertNil(try model.collections.collection(id: b.id))
        XCTAssertThrowsError(try model.collections.create(name: "Child", parentID: b.id))
        XCTAssertEqual(try model.collections.subtreeIDs(of: a.id), [a.id])
    }

    // MARK: Smart lists

    private func fixture(_ model: LibraryModel) throws {
        let fed = try model.tags.create(name: "federated")

        let one = try model.items.create(NewItem(title: "Federated A", creators: [CreatorInput(family: "McMahan", given: "Brendan")], year: 2021, venue: "ICML"))
        let two = try model.items.create(NewItem(title: "Federated B", creators: [CreatorInput(family: "Li", given: "Tian")], year: 2019))
        _ = try model.items.create(NewItem(title: "Other C", creators: [CreatorInput(family: "Zed")], year: 2022))
        let inbox = try model.items.create(NewItem(title: "Federated D", year: 2023, reviewState: .inbox))
        let gone = try model.items.create(NewItem(title: "Federated E", year: 2024))

        for item in [one, two, inbox, gone] { try model.tags.assign(tagID: fed.id, to: item.id) }
        try ModelTestSupport.trash(model, itemID: gone.id)
    }

    private func titles(_ items: [ModelItem]) -> Set<String> { Set(items.map { $0.title }) }

    func testRulesAreStoredAsTheSchemaCommentShowsAndRunWithAnd() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        try fixture(model)

        let saved = try model.savedSearches.create(name: "Recent federated", rules: [
            SearchRule(field: "year", op: ">=", value: .number(2020)),
            SearchRule(field: "tag", op: "=", value: .text("Federated"))
        ])

        let json = try XCTUnwrap(try model.database.scalarText("SELECT rules_json FROM saved_searches WHERE id = ?", [.text(saved.id)]))
        XCTAssertEqual(json, #"[{"field":"year","op":">=","value":2020},{"field":"tag","op":"=","value":"Federated"}]"#)

        // Not the inbox paper, not the trashed one, not the 2019 one.
        XCTAssertEqual(titles(try model.savedSearches.items(matching: saved.id)), ["Federated A"])
        XCTAssertEqual(try model.savedSearches.all(), [saved])
    }

    func testMatchAnyAndTextAndAuthorRules() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        try fixture(model)

        let either = [
            SearchRule(field: "year", op: ">=", value: .number(2022)),
            SearchRule(field: "tag", op: "=", value: .text("federated"))
        ]
        XCTAssertEqual(titles(try model.savedSearches.items(matching: either, matchAll: false)), ["Federated A", "Federated B", "Other C"])

        XCTAssertEqual(titles(try model.savedSearches.items(matching: [SearchRule(field: "title", op: "contains", value: .text("FEDERATED"))], matchAll: true)),
                       ["Federated A", "Federated B"])
        XCTAssertEqual(titles(try model.savedSearches.items(matching: [SearchRule(field: "title", op: "not contains", value: .text("federated"))], matchAll: true)),
                       ["Other C"])
        XCTAssertEqual(titles(try model.savedSearches.items(matching: [SearchRule(field: "author", op: "=", value: .text("Li, Tian"))], matchAll: true)),
                       ["Federated B"])
        XCTAssertEqual(titles(try model.savedSearches.items(matching: [SearchRule(field: "author", op: "contains", value: .text("mcmah"))], matchAll: true)),
                       ["Federated A"])
        XCTAssertEqual(titles(try model.savedSearches.items(matching: [SearchRule(field: "type", op: "=", value: .text("article"))], matchAll: true)),
                       ["Federated A", "Federated B", "Other C"])
        XCTAssertEqual(titles(try model.savedSearches.items(matching: [SearchRule(field: "venue", op: "=", value: .text("icml"))], matchAll: true)),
                       ["Federated A"])
    }

    func testBadRulesAreRefusedAndNeverReachTheDatabase() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        try fixture(model)
        let before = try ModelTestSupport.count(model, "items")

        let bad: [[SearchRule]] = [
            [],
            [SearchRule(field: "password", op: "=", value: .text("x"))],
            [SearchRule(field: "title", op: "; DROP TABLE items; --", value: .text("x"))],
            [SearchRule(field: "title", op: ">", value: .text("x"))],
            [SearchRule(field: "year", op: ">=", value: .text("2020"))],
            [SearchRule(field: "year", op: "LIKE", value: .number(2020))],
            [SearchRule(field: "type", op: "=", value: .text("banana"))],
            [SearchRule(field: "status", op: "contains", value: .text("read"))]
        ]
        for rules in bad {
            XCTAssertThrowsError(try model.savedSearches.create(name: "bad", rules: rules)) { error in
                guard case .invalidRule = (error as? ModelError) else { return XCTFail("expected invalidRule, got \(error)") }
            }
        }
        XCTAssertEqual(try ModelTestSupport.count(model, "saved_searches"), 0)

        // A hostile VALUE is only ever text to look for.
        let hostile = [SearchRule(field: "title", op: "contains", value: .text("'); DROP TABLE items; --"))]
        XCTAssertTrue(try model.savedSearches.items(matching: hostile, matchAll: true).isEmpty)
        XCTAssertEqual(try ModelTestSupport.count(model, "items"), before)
    }

    func testUpdateAndRemoveReportTheOldDefinition() throws {

        let sink = RecordingChangeSink()
        let model = try ModelTestSupport.makeModel(self, sink: sink)
        defer { model.library.close() }

        let saved = try model.savedSearches.create(name: "Old", rules: [SearchRule(field: "year", op: "=", value: .number(2020))])
        sink.clear()

        let updated = try model.savedSearches.update(id: saved.id, name: "New", matchAll: false)
        XCTAssertEqual(updated.name, "New")
        XCTAssertFalse(updated.matchAll)
        XCTAssertEqual(sink.entries(type: "saved_search", action: .update).count, 1)

        XCTAssertThrowsError(try model.savedSearches.update(id: saved.id, rules: []))
        XCTAssertEqual(try model.savedSearches.search(id: saved.id)?.name, "New", "a refused update changes nothing")

        try model.savedSearches.remove(id: saved.id)
        XCTAssertNil(try model.savedSearches.search(id: saved.id))
        let removal = try XCTUnwrap(sink.entries(type: "saved_search", action: .delete).first)
        XCTAssertTrue(try XCTUnwrap(removal.oldValue).contains("New"))
    }
}
