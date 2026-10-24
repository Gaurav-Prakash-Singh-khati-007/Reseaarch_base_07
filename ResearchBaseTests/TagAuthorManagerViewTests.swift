//
//  TagAuthorManagerViewTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 22/10/26.
//


//
//  TagAuthorManagerViewTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 46 · Features: X-03, F-08
//
//  Tests the logic behind TagAuthorManagerView (TagAuthorLogic): colours,
//  search, look-alike pairs, which author to keep, ORCID checks. The merge
//  itself belongs to TagStore / CreatorStore and is tested there; here it is
//  only checked together with the screen's choices. The SwiftUI views are
//  not tested.
//

import XCTest
import SwiftUI
@testable import ResearchBase

@MainActor
final class TagAuthorManagerViewTests: XCTestCase {

    // MARK: Helpers

    private func makeModel() throws -> LibraryModel {
        try ModelTestSupport.makeModel(self)
    }

    private func usage(_ id: String, family: String, given: String, papers: Int) -> CreatorUsage {
        CreatorUsage(
            creator: Creator(
                id: id, family: family, given: given, suffix: "", isOrganisation: false,
                orcid: nil, norm: TextNormalizer.norm("\(family) \(given)")
            ),
            itemCount: papers
        )
    }

    // MARK: Colours

    func testEveryPaletteColourIsAcceptedByTheStoreAndShowsAColour() throws {
        XCTAssertEqual(Set(TagAuthorLogic.palette.map(\.hex)).count, TagAuthorLogic.palette.count, "no duplicate colours")
        for swatch in TagAuthorLogic.palette {
            XCTAssertNoThrow(try TagStore.checkedColor(swatch.hex), "\(swatch.name) must be a colour the store accepts")
            XCTAssertNotNil(TagAuthorLogic.color(for: swatch.hex), swatch.name)
        }
    }

    func testStoredColoursAreReadBack() {
        XCTAssertNil(TagAuthorLogic.color(for: ""))
        XCTAssertNil(TagAuthorLogic.color(for: "   "))
        XCTAssertNotNil(TagAuthorLogic.color(for: "#3E63DD"))
        XCTAssertNotNil(TagAuthorLogic.color(for: "red"))
        XCTAssertNotNil(TagAuthorLogic.color(for: "Grey"))
        XCTAssertNil(TagAuthorLogic.color(for: "#12"))
        XCTAssertNil(TagAuthorLogic.color(for: "#ZZZZZZ"))
        XCTAssertNil(TagAuthorLogic.color(for: "notacolour"))
    }

    func testAColourChosenInTheMenuIsKeptByTheStore() throws {
        let model = try makeModel()
        defer { model.library.close() }
        let tag = try model.tags.create(name: "Federated")
        let swatch = try XCTUnwrap(TagAuthorLogic.palette.first)

        let saved = try model.tags.setColor(id: tag.id, to: swatch.hex)

        XCTAssertEqual(saved.color, swatch.hex)
        XCTAssertNotNil(TagAuthorLogic.color(for: saved.color))
    }

    // MARK: Search

    func testTagSearchIgnoresCaseAndAccents() throws {
        let model = try makeModel()
        defer { model.library.close() }
        for name in ["Federated", "Non-IID", "Café", "Privacy"] { try model.tags.create(name: name) }
        let all = try model.tags.usage()

        XCTAssertEqual(TagAuthorLogic.filterTags(all, query: "").count, 4)
        XCTAssertEqual(TagAuthorLogic.filterTags(all, query: "  ").count, 4)
        XCTAssertEqual(TagAuthorLogic.filterTags(all, query: "FED").map(\.tag.name), ["Federated"])
        XCTAssertEqual(TagAuthorLogic.filterTags(all, query: "cafe").map(\.tag.name), ["Café"])
        XCTAssertTrue(TagAuthorLogic.filterTags(all, query: "zzz").isEmpty)
    }

    func testAuthorSearchFindsNamesAndOrcids() throws {
        let model = try makeModel()
        defer { model.library.close() }
        try model.creators.findOrCreate(CreatorInput(family: "McMahan", given: "Brendan"))
        try model.creators.findOrCreate(CreatorInput(family: "Li", given: "Tian", orcid: "0000-0001-2345-6789"))
        try model.creators.findOrCreate(CreatorInput(family: "Müller", given: "Étienne"))
        let all = try model.creators.allWithUsage()

        XCTAssertEqual(TagAuthorLogic.filterAuthors(all, query: "").count, 3)
        XCTAssertEqual(TagAuthorLogic.filterAuthors(all, query: "mcm").map(\.creator.family), ["McMahan"])
        XCTAssertEqual(TagAuthorLogic.filterAuthors(all, query: "brendan").map(\.creator.family), ["McMahan"])
        XCTAssertEqual(TagAuthorLogic.filterAuthors(all, query: "muller").map(\.creator.family), ["Müller"], "accents are ignored")
        XCTAssertEqual(TagAuthorLogic.filterAuthors(all, query: "0000-0001").map(\.creator.family), ["Li"], "ORCID matches")
        XCTAssertTrue(TagAuthorLogic.filterAuthors(all, query: "zzz").isEmpty)
    }

    // MARK: Look-alike pairs

    func testPairKeyIsTheSameInEitherOrder() {
        XCTAssertEqual(TagAuthorLogic.pairKey("a", "b"), TagAuthorLogic.pairKey("b", "a"))
        XCTAssertNotEqual(TagAuthorLogic.pairKey("a", "b"), TagAuthorLogic.pairKey("a", "c"))
    }

    func testDismissedPairsAreHidden() {
        let one = CreatorLookalike(first: usage("1", family: "Li", given: "Tian", papers: 1),
                                   second: usage("2", family: "Li", given: "T.", papers: 2))
        let two = CreatorLookalike(first: usage("3", family: "Kairouz", given: "Peter", papers: 1),
                                   second: usage("4", family: "Kairouz", given: "P.", papers: 1))

        let hidden = Set([TagAuthorLogic.pairKey("2", "1")])
        let visible = TagAuthorLogic.visibleLookalikes([one, two], dismissed: hidden)

        XCTAssertEqual(visible, [two])
        XCTAssertEqual(TagAuthorLogic.visibleLookalikes([one, two], dismissed: []).count, 2)
    }

    func testSuggestedKeeperPrefersMorePapersThenFullerNameThenFirst() {
        let moreOnSecond = CreatorLookalike(first: usage("1", family: "Li", given: "T.", papers: 1),
                                            second: usage("2", family: "Li", given: "Tian", papers: 5))
        XCTAssertEqual(TagAuthorLogic.suggestedKeeper(moreOnSecond).keep.creator.id, "2")
        XCTAssertEqual(TagAuthorLogic.suggestedKeeper(moreOnSecond).drop.creator.id, "1")

        let tieFullerSecond = CreatorLookalike(first: usage("1", family: "Li", given: "T.", papers: 2),
                                               second: usage("2", family: "Li", given: "Tian", papers: 2))
        XCTAssertEqual(TagAuthorLogic.suggestedKeeper(tieFullerSecond).keep.creator.id, "2")

        let fullTie = CreatorLookalike(first: usage("1", family: "Li", given: "Tian", papers: 2),
                                       second: usage("2", family: "Li", given: "Tina", papers: 2))
        XCTAssertEqual(TagAuthorLogic.suggestedKeeper(fullTie).keep.creator.id, "1")
    }

    func testMergingTheSuggestedPairMovesEveryPaperToTheKeeper() throws {
        let model = try makeModel()
        defer { model.library.close() }
        try ModelTestSupport.item(model, title: "Paper one", author: "McMahan", given: "H. Brendan")
        try ModelTestSupport.item(model, title: "Paper two", author: "McMahan", given: "H. Brendan")
        try ModelTestSupport.item(model, title: "Paper three", author: "McMahan", given: "Brendan")

        let pair = try XCTUnwrap(try model.creators.lookalikes().first)
        let choice = TagAuthorLogic.suggestedKeeper(pair)
        XCTAssertEqual(choice.keep.creator.given, "H. Brendan", "the spelling on two papers is kept")
        XCTAssertEqual(choice.keep.itemCount, 2)
        XCTAssertEqual(choice.drop.itemCount, 1)

        try model.creators.merge(choice.drop.creator.id, into: choice.keep.creator.id)

        let after = try model.creators.allWithUsage()
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.itemCount, 3)
        XCTAssertTrue(try model.creators.lookalikes().isEmpty)
    }

    // MARK: Counts and ORCID

    func testPaperCountText() {
        XCTAssertEqual(TagAuthorLogic.paperCountText(0), "Not used")
        XCTAssertEqual(TagAuthorLogic.paperCountText(1), "1 paper")
        XCTAssertEqual(TagAuthorLogic.paperCountText(12), "12 papers")
    }

    func testOrcidCheck() {
        XCTAssertTrue(TagAuthorLogic.isValidORCID(""))
        XCTAssertTrue(TagAuthorLogic.isValidORCID("   "))
        XCTAssertTrue(TagAuthorLogic.isValidORCID("0000-0001-2345-6789"))
        XCTAssertTrue(TagAuthorLogic.isValidORCID("0000-0002-1825-009X"))
        XCTAssertTrue(TagAuthorLogic.isValidORCID("0000-0002-1825-009x"))
        XCTAssertFalse(TagAuthorLogic.isValidORCID("0000-0001-2345-678"))
        XCTAssertFalse(TagAuthorLogic.isValidORCID("0000000123456789"))
        XCTAssertFalse(TagAuthorLogic.isValidORCID("abcd-0001-2345-6789"))
        XCTAssertFalse(TagAuthorLogic.isValidORCID("000X-0001-2345-6789"), "X is only allowed as the last character")
    }
}