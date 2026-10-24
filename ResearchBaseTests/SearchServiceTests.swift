//
//  SearchServiceTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 20/10/26.
//


//
//  SearchServiceTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 14 · Features: F-22, F-24
//

import XCTest
@testable import ResearchBase

@MainActor
final class SearchServiceTests: XCTestCase {

    // MARK: Query building

    func testQueryBuilderQuotesWordsAndPrefixesTheLastOne() {
        XCTAssertEqual(SearchService.ftsQuery("federated learn")?.match, "\"federated\" \"learn\"*")
        XCTAssertEqual(SearchService.ftsQuery("\"deep networks\" fed")?.match, "\"deep networks\" \"fed\"*")
        XCTAssertEqual(SearchService.ftsQuery("\"deep networks\"")?.match, "\"deep networks\"")
    }

    func testQueryBuilderNeutralisesOperatorsAndJunk() {
        XCTAssertNil(SearchService.ftsQuery("   "))
        XCTAssertNil(SearchService.ftsQuery("AND OR ( ) - *"))
        XCTAssertEqual(SearchService.ftsQuery("graphs AND NOT (trees")?.match, "\"graphs\" \"(trees\"*")
        XCTAssertNotNil(SearchService.ftsQuery("10.1145/3292500"))
    }

    func testColumnFilterOnlyForKnownColumns() {
        let items = SearchService.ftsQuery("author:smith graph", columns: SearchService.itemColumns)
        XCTAssertEqual(items?.match, "authors : \"smith\" \"graph\"*")
        let plain = SearchService.ftsQuery("author:smith")
        XCTAssertEqual(plain?.match, "\"author:smith\"*")
    }

    // MARK: Items

    func testSearchFindsItemsByTitleAuthorTagAndAbstract() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let search = SearchService(model: model)

        let a = try model.items.create(NewItem(
            title: "Federated Learning at Scale", creators: [CreatorInput(family: "Müller", given: "Anna")],
            year: 2020, abstract: "We train models across many phones without sharing raw data."))
        let b = try ModelTestSupport.item(model, title: "Graph Attention Networks", author: "Veličković", given: "Petar")
        try search.rebuildItems()

        XCTAssertEqual(try search.searchItems("federated").hits.map(\.itemID), [a.id])
        XCTAssertEqual(try search.searchItems("feder").hits.map(\.itemID), [a.id], "last word matches as a prefix")
        XCTAssertEqual(try search.searchItems("muller").hits.map(\.itemID), [a.id], "accents ignored")
        XCTAssertEqual(try search.searchItems("author:velickovic").hits.map(\.itemID), [b.id])
        XCTAssertEqual(try search.searchItems("phones").hits.first?.snippet.contains("phones"), true)
        XCTAssertTrue(try search.searchItems("nonexistentword").hits.isEmpty)
        XCTAssertEqual(try search.searchItems("").total, 0)
    }

    func testTrashAndInboxAreHidden() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let search = SearchService(model: model)

        let kept = try ModelTestSupport.item(model, title: "Quantum Walks")
        let trashed = try ModelTestSupport.item(model, title: "Quantum Gravity", author: "Rovelli", given: "Carlo")
        let inbox = try ModelTestSupport.item(model, title: "Quantum Dots", author: "Brus", given: "Louis", state: .inbox)
        try search.rebuildItems()
        try ModelTestSupport.trash(model, itemID: trashed.id)

        XCTAssertEqual(try search.searchItems("quantum").hits.map(\.itemID), [kept.id])
        let withInbox = try search.searchItems("quantum", options: SearchOptions(includeInbox: true)).hits.map(\.itemID)
        XCTAssertEqual(Set(withInbox), [kept.id, inbox.id])
    }

    func testIncrementalIndexReplacesOldTextAndRemoveWorks() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let search = SearchService(model: model)

        let item = try ModelTestSupport.item(model, title: "Old Title About Zebras")
        try search.indexItem(id: item.id)
        XCTAssertEqual(try search.searchItems("zebras").total, 1)

        try model.items.update(id: item.id) { $0.title = "New Title About Giraffes" }
        try search.indexItem(id: item.id)
        XCTAssertEqual(try search.searchItems("zebras").total, 0, "old text is gone")
        XCTAssertEqual(try search.searchItems("giraffes").total, 1)

        try search.removeItem(id: item.id)
        XCTAssertEqual(try search.searchItems("giraffes").total, 0)
    }

    func testBetterMatchesRankFirstAndPagingWorks() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let search = SearchService(model: model)

        let inTitle = try ModelTestSupport.item(model, title: "Transformers", author: "Vaswani", given: "Ashish")
        for n in 0..<5 {
            try model.items.create(NewItem(title: "Paper \(n)", abstract: "mentions transformers once"))
        }
        try search.rebuildItems()

        let page1 = try search.searchItems("transformers", options: SearchOptions(limit: 2, offset: 0))
        XCTAssertEqual(page1.hits.first?.itemID, inTitle.id)
        XCTAssertEqual(page1.hits.count, 2)
        XCTAssertEqual(page1.total, 6)
        XCTAssertFalse(page1.totalIsCapped)

        let page3 = try search.searchItems("transformers", options: SearchOptions(limit: 2, offset: 4))
        XCTAssertEqual(page3.hits.count, 2)
    }

    func testSuggestTitlesMatchesTitleOnly() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let search = SearchService(model: model)

        let a = try ModelTestSupport.item(model, title: "Attention Is All You Need", author: "Vaswani", given: "Ashish")
        try model.items.create(NewItem(title: "Other", abstract: "attention appears in the abstract only"))
        try search.rebuildItems()

        XCTAssertEqual(try search.suggestTitles(prefix: "atten").map(\.itemID), [a.id])
    }

    // MARK: Thoughts, PDF, drafts

    func testThoughtSearchAndShadowedReindex() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let search = SearchService(model: model)

        let id = try ModelTestSupport.insertThought(model)
        try model.database.run("UPDATE thoughts SET title = 'Idea', body = 'try contrastive pretraining' WHERE id = ?", [.text(id)])
        try search.indexThought(id: id)
        XCTAssertEqual(try search.searchThoughts("contrastive").hits.map(\.thoughtID), [id])

        try model.database.run("UPDATE thoughts SET body = 'try masked modelling' WHERE id = ?", [.text(id)])
        try search.indexThought(id: id)
        XCTAssertEqual(try search.searchThoughts("contrastive").total, 0)
        XCTAssertEqual(try search.searchThoughts("masked").total, 1)

        try model.database.run("UPDATE thoughts SET deleted_at = ? WHERE id = ?", [.text(Library.nowISO()), .text(id)])
        XCTAssertEqual(try search.searchThoughts("masked").total, 0, "Trash is hidden")
    }

    func testPDFPageHitsCarryTheAttachmentAndPage() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let search = SearchService(model: model)

        let item = try ModelTestSupport.item(model)
        let now = Library.nowISO()
        try model.database.run(
            "INSERT INTO attachments (id, item_id, kind, sha256, rel_path, bytes, added_at) VALUES ('att1', ?, 'pdf', 'x', 'files/x.pdf', 1, ?)",
            [.text(item.id), .text(now)])

        try search.indexPDF(attachmentID: "att1", pages: [(1, "introduction"), (7, "the averaging step of federated training")])
        let hits = try search.searchPDF("averaging").hits

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.attachmentID, "att1")
        XCTAssertEqual(hits.first?.itemID, item.id)
        XCTAssertEqual(hits.first?.page, 7)

        try ModelTestSupport.trash(model, itemID: item.id)
        XCTAssertEqual(try search.searchPDF("averaging").total, 0)
    }

    func testDraftSearchGivesOneHitPerDraft() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let search = SearchService(model: model)

        let draft = try ModelTestSupport.insertDraft(model)
        try search.indexDraftFile(draftID: draft, file: "main.tex", text: "we study federated optimisation")
        try search.indexDraftFile(draftID: draft, file: "intro.tex", text: "federated learning is popular")

        let page = try search.searchDrafts("federated")
        XCTAssertEqual(page.hits.map(\.draftID), [draft])
        XCTAssertEqual(page.total, 1)
    }

    func testRowIDEncodingRoundTrips() {
        let rowID = SearchService.pdfRowID(attachmentRowID: 42, page: 317)
        let decoded = SearchService.decodePDFRowID(rowID)
        XCTAssertEqual(decoded.attachmentRowID, 42)
        XCTAssertEqual(decoded.page, 317)
        XCTAssertEqual(SearchService.draftRowID(draftRowID: 3, file: "main.tex") / 1_000_000, 3)
    }

    func testSearchAllGroupsResults() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let search = SearchService(model: model)

        try ModelTestSupport.item(model, title: "Sparse Coding")
        try search.rebuildItems()
        let all = try search.searchAll("sparse")
        XCTAssertEqual(all.items.count, 1)
        XCTAssertTrue(all.pdf.isEmpty && all.thoughts.isEmpty && all.drafts.isEmpty)
        XCTAssertTrue(try search.searchAll("zzzz").isEmpty)
    }
}