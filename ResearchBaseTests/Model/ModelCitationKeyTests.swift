//
//  ModelCitationKeyTests.swift
//  ResearchBaseTests
//
//  Phase 1, Step 1B (F-13): stable citation keys.
//

import XCTest
@testable import ResearchBase

@MainActor
final class ModelCitationKeyTests: XCTestCase {

    // MARK: Generation

    func testKeyFormatFollowsAuthorYearWord() {

        func key(_ family: String?, _ year: Int?, _ title: String) -> String {
            CitationKeyGenerator.base(
                firstCreator: family.map { CreatorInput(family: $0) }, year: year, title: title)
        }

        XCTAssertEqual(key("McMahan", 2017, "Communication-Efficient Learning of Deep Networks"), "mcmahan2017communication")
        XCTAssertEqual(key("van der Berg", 2020, "The Art of Lists"), "vanderberg2020art")
        XCTAssertEqual(key("Müller", 2019, "Über alles"), "muller2019uber")
        XCTAssertEqual(key(nil, nil, "Deep Learning"), "unknownnddeep")
        XCTAssertEqual(key("Li", 2020, "A of the"), "li2020", "a title of only small words adds nothing")
        XCTAssertEqual(key("O'Brien", 2001, "On the Origin"), "obrien2001origin")
    }

    func testEveryGeneratedKeyIsValid() {
        for key in ["mcmahan2017communication", "unknownnddeep", "li2020", "a-b_c:d.e"] {
            XCTAssertTrue(CitationKeyGenerator.isValid(key), key)
        }
        for key in ["", "has space", "ü", "a/b", "a{b}", "a,b", "a'b"] {
            XCTAssertFalse(CitationKeyGenerator.isValid(key), key)
        }
    }

    func testClashesGetLettersEvenAgainstItemsInTheTrash() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let first = try ModelTestSupport.item(model, title: "Learning Things", author: "Same", year: 2020)
        let second = try ModelTestSupport.item(model, title: "Learning Things", author: "Same", year: 2020)
        XCTAssertEqual(first.citationKey, "same2020learning")
        XCTAssertEqual(second.citationKey, "same2020learninga")

        // The first one goes to the Trash. Its key is still reserved, so restoring it can never collide.
        try ModelTestSupport.trash(model, itemID: first.id)
        let third = try ModelTestSupport.item(model, title: "Learning Things", author: "Same", year: 2020)
        XCTAssertEqual(third.citationKey, "same2020learningb")
    }

    func testKeysAreUniqueIgnoringCase() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let one = try ModelTestSupport.item(model, title: "Alpha Beta", author: "Kay", year: 2020)
        let two = try ModelTestSupport.item(model, title: "Other", author: "Kay", year: 2021)

        XCTAssertThrowsError(try model.citationKeys.change(itemID: two.id, to: one.citationKey.uppercased(), confirmed: true)) {
            guard case .citationKeyInUse = ($0 as? ModelError) else { return XCTFail("expected citationKeyInUse") }
        }
        XCTAssertEqual(try model.items.fetch(id: two.id)?.citationKey, two.citationKey)
    }

    func testEditingTitleOrAuthorsNeverChangesTheKey() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let item = try ModelTestSupport.item(model)
        let edited = try model.items.update(id: item.id) {
            $0.title = "Completely different"
            $0.year = 1999
        }
        try model.creators.setCreators(itemID: item.id, [CreatorInput(family: "Someone Else")])

        XCTAssertEqual(edited.citationKey, item.citationKey)
        XCTAssertEqual(try model.items.fetch(id: item.id)?.citationKey, item.citationKey)
    }

    // MARK: Locking

    func testAKeyLocksOnceADraftCitesItAndLockingIsRepeatable() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let cited = try ModelTestSupport.item(model, title: "Cited", author: "A")
        let free = try ModelTestSupport.item(model, title: "Free", author: "B")
        let draft = try ModelTestSupport.insertDraft(model)

        XCTAssertFalse(try model.citationKeys.isLocked(itemID: cited.id))

        try ModelTestSupport.cite(model, draftID: draft, itemID: cited.id, key: cited.citationKey)
        try ModelTestSupport.cite(model, draftID: draft, itemID: nil, key: "missingkey", line: 2)

        XCTAssertEqual(try model.citationKeys.lockKeysUsedByDrafts(), 1)
        XCTAssertTrue(try model.citationKeys.isLocked(itemID: cited.id))
        XCTAssertFalse(try model.citationKeys.isLocked(itemID: free.id))
        XCTAssertEqual(try model.citationKeys.lockKeysUsedByDrafts(), 0, "second call changes nothing")
    }

    func testChangingALockedKeyNeedsConfirmationThenUpdatesTheDrafts() throws {

        let sink = RecordingChangeSink()
        let model = try ModelTestSupport.makeModel(self, sink: sink)
        defer { model.library.close() }

        let item = try ModelTestSupport.item(model)
        let draftA = try ModelTestSupport.insertDraft(model, id: "draft-a")
        let draftB = try ModelTestSupport.insertDraft(model, id: "draft-b")
        try ModelTestSupport.cite(model, draftID: draftA, itemID: item.id, key: item.citationKey, line: 4)
        try ModelTestSupport.cite(model, draftID: draftB, itemID: item.id, key: item.citationKey, line: 9)
        try model.citationKeys.lockKeysUsedByDrafts()
        sink.clear()

        XCTAssertThrowsError(try model.citationKeys.change(itemID: item.id, to: "newkey2017", confirmed: false)) {
            XCTAssertEqual($0 as? ModelError, .citationKeyLocked(item.citationKey))
        }
        XCTAssertEqual(try model.items.fetch(id: item.id)?.citationKey, item.citationKey)
        XCTAssertTrue(sink.entries.isEmpty)

        let change = try model.citationKeys.change(itemID: item.id, to: " newkey2017 ", confirmed: true)

        XCTAssertEqual(change.oldKey, item.citationKey)
        XCTAssertEqual(change.newKey, "newkey2017")
        XCTAssertEqual(change.draftIDs, ["draft-a", "draft-b"])
        XCTAssertTrue(change.wasLocked)

        let keysInDrafts = try model.database.rows("SELECT DISTINCT citation_key FROM draft_citations").compactMap { $0.text("citation_key") }
        XCTAssertEqual(keysInDrafts, ["newkey2017"])
        XCTAssertTrue(try model.citationKeys.isLocked(itemID: item.id), "it stays locked")

        let reported = try XCTUnwrap(sink.entries(type: "item", field: "citation_key").first)
        XCTAssertEqual(reported.oldValue, item.citationKey)
        XCTAssertEqual(reported.newValue, "newkey2017")
    }

    func testAnUnlockedKeyCanBeChangedAndBadKeysAreRefused() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let item = try ModelTestSupport.item(model)

        let change = try model.citationKeys.change(itemID: item.id, to: "mine2020", confirmed: false)
        XCTAssertFalse(change.wasLocked)
        XCTAssertEqual(change.draftIDs, [])
        XCTAssertEqual(try model.items.fetch(id: item.id)?.citationKey, "mine2020")

        for bad in ["", "   ", "has space", "ü", "a{b}"] {
            XCTAssertThrowsError(try model.citationKeys.change(itemID: item.id, to: bad, confirmed: true), bad) {
                guard case .citationKeyInvalid = ($0 as? ModelError) else { return XCTFail("expected citationKeyInvalid for \(bad)") }
            }
        }
        XCTAssertEqual(try model.items.fetch(id: item.id)?.citationKey, "mine2020")

        XCTAssertThrowsError(try model.citationKeys.change(itemID: "ghost", to: "fine", confirmed: true)) {
            guard case .notFound = ($0 as? ModelError) else { return XCTFail("expected notFound") }
        }
    }

    func testChangingToTheSameKeyDoesNothing() throws {

        let sink = RecordingChangeSink()
        let model = try ModelTestSupport.makeModel(self, sink: sink)
        defer { model.library.close() }

        let item = try ModelTestSupport.item(model)
        let draft = try ModelTestSupport.insertDraft(model)
        try ModelTestSupport.cite(model, draftID: draft, itemID: item.id, key: item.citationKey)
        try model.citationKeys.lockKeysUsedByDrafts()
        sink.clear()

        let change = try model.citationKeys.change(itemID: item.id, to: item.citationKey, confirmed: false)

        XCTAssertEqual(change.draftIDs, [])
        XCTAssertTrue(sink.entries.isEmpty)
    }
}
