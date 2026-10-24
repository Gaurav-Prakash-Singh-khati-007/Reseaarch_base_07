//
//  ModelCreatorTagTests.swift
//  ResearchBaseTests
//
//  Phase 1, Step 1B (F-08, X-03): authors as records, tags renamed, coloured, merged.
//

import XCTest
@testable import ResearchBase

@MainActor
final class ModelCreatorTagTests: XCTestCase {

    // MARK: Authors

    func testSameNameIsOneRecordAndOrderIsKept() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let a = try model.items.create(NewItem(title: "One", creators: [
            CreatorInput(family: "Smith", given: "Jane"),
            CreatorInput(family: "Doe", given: "John"),
            CreatorInput(family: "Ed", given: "Ito", role: .editor)
        ]))
        let b = try model.items.create(NewItem(title: "Two", creators: [CreatorInput(family: "Smith", given: "Jane")]))

        XCTAssertEqual(try ModelTestSupport.count(model, "creators"), 3)

        let list = try model.creators.creators(of: a.id)
        XCTAssertEqual(list.map { $0.creator.family }, ["Smith", "Doe", "Ed"])
        XCTAssertEqual(list.map { $0.role }, [.author, .author, .editor])
        XCTAssertEqual(list.map { $0.position }, [0, 1, 0])

        let shared = try XCTUnwrap(try model.creators.creators(of: b.id).first)
        XCTAssertEqual(shared.creator.id, list[0].creator.id)

        let usage = try model.creators.allWithUsage()
        XCTAssertEqual(usage.first(where: { $0.creator.family == "Smith" })?.itemCount, 2)
    }

    func testOrcidSharesARecordEvenWhenTheSpellingDiffers() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let first = try model.creators.findOrCreate(CreatorInput(family: "Li", given: "Tian", orcid: "0000-0001-2345-6789"))
        let second = try model.creators.findOrCreate(CreatorInput(family: "Li", given: "T.", orcid: "0000-0001-2345-6789"))
        XCTAssertEqual(first.id, second.id)

        let plain = try model.creators.findOrCreate(CreatorInput(family: "Li", given: "T."))
        XCTAssertNotEqual(plain.id, first.id, "A different spelling without ORCID stays separate until merged")
    }

    func testOrganisationAuthorAndNormForSearch() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let org = try model.creators.findOrCreate(CreatorInput(family: "World Health Organization", isOrganisation: true))
        XCTAssertTrue(org.isOrganisation)
        XCTAssertEqual(org.displayName, "World Health Organization")

        let person = try model.creators.findOrCreate(CreatorInput(family: "Müller", given: "Étienne"))
        XCTAssertEqual(person.norm, "muller etienne")
        XCTAssertEqual(person.displayName, "Müller, Étienne")
    }

    func testRenamingACreatorChangesEveryItemAndTheSearchForm() throws {

        let sink = RecordingChangeSink()
        let model = try ModelTestSupport.makeModel(self, sink: sink)
        defer { model.library.close() }

        let item = try ModelTestSupport.item(model, author: "Mcmahan", given: "B")
        let creator = try XCTUnwrap(try model.creators.creators(of: item.id).first).creator

        let fixed = try model.creators.update(id: creator.id) {
            $0.family = "McMahan"
            $0.given = "H. Brendan"
        }

        XCTAssertEqual(fixed.norm, "mcmahan h. brendan")
        XCTAssertEqual(try model.creators.creators(of: item.id).first?.creator.given, "H. Brendan")
        XCTAssertFalse(sink.entries(type: "creator", action: .update).isEmpty)
    }

    func testLookAlikeAuthorsAreFoundLikeInTheHTML() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        for (family, given) in [
            ("McMahan", "H. Brendan"), ("McMahan", "Brendan"),
            ("Li", "Tian"), ("Li", "T."), ("Li", "Wei"),
            ("Kairouz", "Peter"), ("Kairouz", "P.")
        ] {
            _ = try model.creators.findOrCreate(CreatorInput(family: family, given: given))
        }

        let pairs = try model.creators.lookalikes().map { Set([$0.first.creator.displayName, $0.second.creator.displayName]) }

        XCTAssertEqual(pairs.count, 3)
        XCTAssertTrue(pairs.contains(["McMahan, H. Brendan", "McMahan, Brendan"]))
        XCTAssertTrue(pairs.contains(["Li, Tian", "Li, T."]))
        XCTAssertTrue(pairs.contains(["Kairouz, Peter", "Kairouz, P."]))
    }

    func testGivenNameMatching() {
        XCTAssertTrue(CreatorStore.givenNamesLookAlike("Tian", "T."))
        XCTAssertTrue(CreatorStore.givenNamesLookAlike("H. Brendan", "Brendan"))
        XCTAssertFalse(CreatorStore.givenNamesLookAlike("Tian", "Tao"))
        XCTAssertFalse(CreatorStore.givenNamesLookAlike("Wei", "T."))
        XCTAssertFalse(CreatorStore.givenNamesLookAlike("", "T."))
    }

    func testMergingCreatorsMovesEveryPaperAndRemovesOnlyTheDuplicate() throws {

        let sink = RecordingChangeSink()
        let model = try ModelTestSupport.makeModel(self, sink: sink)
        defer { model.library.close() }

        let one = try ModelTestSupport.item(model, title: "One", author: "Li", given: "Tian")
        let two = try ModelTestSupport.item(model, title: "Two", author: "Li", given: "T.")
        let keep = try XCTUnwrap(try model.creators.creators(of: one.id).first).creator
        let drop = try XCTUnwrap(try model.creators.creators(of: two.id).first).creator

        sink.clear()
        let moved = try model.creators.merge(drop.id, into: keep.id)

        XCTAssertEqual(moved, 1)
        XCTAssertNil(try model.creators.creator(id: drop.id))
        XCTAssertEqual(try model.creators.creators(of: two.id).first?.creator.id, keep.id)
        XCTAssertEqual(try model.creators.allWithUsage().first?.itemCount, 2)

        // The citation keys do not change when authors are merged.
        XCTAssertEqual(try model.items.fetch(id: two.id)?.citationKey, two.citationKey)

        let merge = try XCTUnwrap(sink.entries(type: "creator", action: .merge).first)
        XCTAssertEqual(merge.entityID, drop.id)
        XCTAssertEqual(merge.newValue, keep.id)
        XCTAssertTrue(try XCTUnwrap(merge.oldValue).contains(two.id), "the snapshot lists the paper it held")
    }

    func testMergingWithItselfOrAMissingCreatorIsRefused() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let one = try model.creators.findOrCreate(CreatorInput(family: "Solo"))

        XCTAssertThrowsError(try model.creators.merge(one.id, into: one.id)) {
            XCTAssertEqual($0 as? ModelError, .sameRecord)
        }
        XCTAssertThrowsError(try model.creators.merge(one.id, into: "nope"))
        XCTAssertNotNil(try model.creators.creator(id: one.id))
    }

    // MARK: Tags

    func testTagNamesAreUniqueIgnoringCase() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let tag = try model.tags.create(name: " Federated ")
        XCTAssertEqual(tag.name, "Federated")

        XCTAssertThrowsError(try model.tags.create(name: "federated")) {
            XCTAssertEqual($0 as? ModelError, .tagNameTaken("federated"))
        }
        XCTAssertEqual(try model.tags.findOrCreate(name: "FEDERATED").id, tag.id)
        XCTAssertThrowsError(try model.tags.create(name: "  ")) {
            XCTAssertEqual($0 as? ModelError, .emptyName)
        }
        XCTAssertEqual(try ModelTestSupport.count(model, "tags"), 1)
    }

    func testRenameRefusesATakenNameButAllowsChangingCapitals() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let a = try model.tags.create(name: "federated")
        _ = try model.tags.create(name: "privacy")

        XCTAssertThrowsError(try model.tags.rename(id: a.id, to: "Privacy")) {
            XCTAssertEqual($0 as? ModelError, .tagNameTaken("Privacy"))
        }
        XCTAssertEqual(try model.tags.tag(id: a.id)?.name, "federated")

        XCTAssertEqual(try model.tags.rename(id: a.id, to: "Federated").name, "Federated")
        XCTAssertEqual(try model.tags.rename(id: a.id, to: "federated learning").name, "federated learning")
    }

    func testColours() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let tag = try model.tags.create(name: "colour me")

        XCTAssertEqual(try model.tags.setColor(id: tag.id, to: "#12ab34").color, "#12AB34")
        XCTAssertEqual(try model.tags.setColor(id: tag.id, to: "red").color, "red")
        XCTAssertEqual(try model.tags.setColor(id: tag.id, to: "").color, "")

        for bad in ["#12", "#GGGGGG", "Red", "red; background:url(x)", "rgb(1,2,3)"] {
            XCTAssertThrowsError(try model.tags.setColor(id: tag.id, to: bad), bad)
        }
        XCTAssertEqual(try model.tags.tag(id: tag.id)?.color, "")
    }

    func testAssigningTwiceChangesNothingAndUnassignKeepsTheTag() throws {

        let sink = RecordingChangeSink()
        let model = try ModelTestSupport.makeModel(self, sink: sink)
        defer { model.library.close() }

        let item = try ModelTestSupport.item(model)
        let tag = try model.tags.create(name: "x")
        sink.clear()

        try model.tags.assign(tagID: tag.id, to: item.id)
        try model.tags.assign(tagID: tag.id, to: item.id)
        XCTAssertEqual(try model.tags.tags(of: item.id).count, 1)
        XCTAssertEqual(sink.entries(type: "item", field: "tag").count, 1)

        try model.tags.unassign(tagID: tag.id, from: item.id)
        XCTAssertTrue(try model.tags.tags(of: item.id).isEmpty)
        XCTAssertNotNil(try model.tags.tag(id: tag.id))
        XCTAssertEqual(sink.entries(type: "item", field: "tag").last?.oldValue, tag.id)
    }

    func testMergingTagsMovesItemsAndKeepsOneCopyWhereBothWerePresent() throws {

        let sink = RecordingChangeSink()
        let model = try ModelTestSupport.makeModel(self, sink: sink)
        defer { model.library.close() }

        let i1 = try ModelTestSupport.item(model, title: "1", author: "A")
        let i2 = try ModelTestSupport.item(model, title: "2", author: "B")
        let i3 = try ModelTestSupport.item(model, title: "3", author: "C")
        let a = try model.tags.create(name: "fl")
        let b = try model.tags.create(name: "federated", color: "#112233")

        try model.tags.assign(tagID: a.id, to: i1.id)
        try model.tags.assign(tagID: a.id, to: i2.id)
        try model.tags.assign(tagID: b.id, to: i2.id)
        try model.tags.assign(tagID: b.id, to: i3.id)
        sink.clear()

        let moved = try model.tags.merge(a.id, into: b.id)

        XCTAssertEqual(moved, 2)
        XCTAssertNil(try model.tags.tag(id: a.id))
        XCTAssertEqual(try model.tags.tags(of: i1.id).map { $0.name }, ["federated"])
        XCTAssertEqual(try model.tags.tags(of: i2.id).map { $0.name }, ["federated"])
        XCTAssertEqual(try model.tags.tag(id: b.id)?.color, "#112233")
        XCTAssertEqual(try model.tags.usage().first?.itemCount, 3)

        let merge = try XCTUnwrap(sink.entries(type: "tag", action: .merge).first)
        XCTAssertEqual(merge.entityID, a.id)
        XCTAssertEqual(merge.newValue, b.id)
        XCTAssertTrue(try XCTUnwrap(merge.oldValue).contains(i1.id))

        XCTAssertThrowsError(try model.tags.merge(b.id, into: b.id))
    }

    func testTagCountsLeaveOutItemsInTheTrash() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let i1 = try ModelTestSupport.item(model, title: "1", author: "A")
        let i2 = try ModelTestSupport.item(model, title: "2", author: "B")
        let tag = try model.tags.create(name: "t")
        try model.tags.assign(tagID: tag.id, to: i1.id)
        try model.tags.assign(tagID: tag.id, to: i2.id)

        try ModelTestSupport.trash(model, itemID: i1.id)

        XCTAssertEqual(try model.tags.usage().first?.itemCount, 1)
    }
}
