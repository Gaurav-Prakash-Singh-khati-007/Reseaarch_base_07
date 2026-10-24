//
//  MergeDuplicatesSheetTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 23/10/26.
//


//
//  MergeDuplicatesSheetTests.swift
//  Owner: Agent 59 (tests for MergeDuplicatesSheet.swift: MergeLogic)
//

import XCTest
@testable import ResearchBase

final class MergeDuplicatesSheetTests: XCTestCase {

    private func item(title: String = "T", venue: String = "", year: Int? = nil, doi: String? = nil,
                      rating: Int = 0, inQueue: Bool = false, status: ItemReadingStatus = .unread) -> ModelItem {
        ModelItem(
            id: UUID().uuidString, type: .article, title: title, abstract: "", venue: venue, year: year,
            month: "", volume: "", issue: "", pages: "", publisher: "", edition: "", doi: doi, arxivID: nil,
            url: "", citationKey: "k", keyLocked: false, readingStatus: status, inQueue: inQueue, rating: rating,
            language: "", sourceURL: "", sourceKind: .manual, capturedAt: nil, reviewState: .accepted,
            addedAt: "", updatedAt: "", deletedAt: nil
        )
    }

    func testDefaultChoiceKeepsLibraryUnlessEmpty() {
        XCTAssertEqual(MergeLogic.defaultChoice(existing: "ICML", new: "Proceedings of ICML"), .existing)
        XCTAssertEqual(MergeLogic.defaultChoice(existing: "  ", new: "ICML"), .new)
        XCTAssertEqual(MergeLogic.defaultChoice(existing: "", new: ""), .existing)
    }

    func testFieldsShowKeyRowsAlwaysAndOthersOnlyWhenDifferent() {
        var a = item(venue: "ICML", year: 2020)
        var b = item(venue: "Proc. ICML", year: 2020)
        a.pages = "1-10"; b.pages = "1-10"
        let keys = MergeLogic.fields(existing: a, existingCreators: [], new: b, newCreators: []).map(\.key)
        XCTAssertEqual(keys, [.title, .authors, .venue, .year, .doi, .arxivID])
        b.pages = "1-12"
        let keys2 = MergeLogic.fields(existing: a, existingCreators: [], new: b, newCreators: []).map(\.key)
        XCTAssertTrue(keys2.contains(.pages))
    }

    func testFillsEmptyDOIFromNewByDefault() {
        let a = item(doi: nil), b = item(doi: "10.1/x")
        let doi = MergeLogic.fields(existing: a, existingCreators: [], new: b, newCreators: []).first { $0.key == .doi }
        XCTAssertEqual(doi?.choice, .new)
    }

    func testApplyOnlyCopiesChosenFields() {
        var kept = item(title: "Old", venue: "A", year: 2019)
        let other = item(title: "New", venue: "B", year: 2020)
        MergeLogic.apply([.title: .new, .venue: .existing, .year: .new], from: other, to: &kept)
        XCTAssertEqual(kept.title, "New")
        XCTAssertEqual(kept.venue, "A")
        XCTAssertEqual(kept.year, 2020)
    }

    func testApplyNeverBlanksTitle() {
        var kept = item(title: "Keep")
        let other = item(title: "  ")
        MergeLogic.apply([.title: .new], from: other, to: &kept)
        XCTAssertEqual(kept.title, "Keep")
    }

    func testStatusMergeKeepsHigherValues() {
        var kept = item(rating: 2, inQueue: false, status: .reading)
        MergeLogic.mergeStatus(from: item(rating: 4, inQueue: true, status: .unread), to: &kept)
        XCTAssertEqual(kept.rating, 4)
        XCTAssertTrue(kept.inQueue)
        XCTAssertEqual(kept.readingStatus, .reading)
        MergeLogic.mergeStatus(from: item(status: .read), to: &kept)
        XCTAssertEqual(kept.readingStatus, .read)
    }

    func testMatchedText() {
        XCTAssertEqual(MergeLogic.matchedText([]), "These look like the same paper.")
        XCTAssertEqual(MergeLogic.matchedText([.sameDOI]), "Matched by DOI.")
        XCTAssertEqual(MergeLogic.matchedText([.sameTitle, .sameFile]), "Matched by identical file and title.")
    }

    func testCombineText() {
        XCTAssertNil(MergeLogic.combineText(tags: 0, folders: 0, links: 0, files: 0))
        XCTAssertEqual(MergeLogic.combineText(tags: 1, folders: 0, links: 0, files: 0),
                       "Will be added to the kept copy: 1 tag.")
        XCTAssertEqual(MergeLogic.combineText(tags: 2, folders: 1, links: 3, files: 0),
                       "Will be added to the kept copy: 2 tags, 1 folder and 3 links.")
    }

    func testCitedErrorWording() {
        XCTAssertTrue(ItemMergeError.citedByDrafts(count: 1, key: "he2016").errorDescription!.contains("A draft cites"))
        XCTAssertTrue(ItemMergeError.citedByDrafts(count: 3, key: "he2016").errorDescription!.contains("3 drafts cite"))
    }
}