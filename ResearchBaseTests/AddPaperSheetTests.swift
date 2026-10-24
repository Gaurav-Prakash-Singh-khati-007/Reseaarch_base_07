//
//  AddPaperSheetTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 23/10/26.
//


//
//  AddPaperSheetTests.swift
//  Owner: Agent 57 (tests for AddPaperSheet.swift: AddPaperLogic)
//

import XCTest
@testable import ResearchBase

final class AddPaperSheetTests: XCTestCase {

    func testParsesFamilyCommaGivenList() {
        let c = AddPaperLogic.parseAuthors("He, Kaiming; Zhang, Xiangyu")
        XCTAssertEqual(c.map(\.family), ["He", "Zhang"])
        XCTAssertEqual(c.map(\.given), ["Kaiming", "Xiangyu"])
    }

    func testParsesGivenFamilyAndAnd() {
        let c = AddPaperLogic.parseAuthors("Kaiming He and Xiangyu Zhang")
        XCTAssertEqual(c.map(\.family), ["He", "Zhang"])
        XCTAssertEqual(c.first?.given, "Kaiming")
    }

    func testSingleNameAndEmptyInput() {
        XCTAssertEqual(AddPaperLogic.parseAuthors("UNESCO").first?.family, "UNESCO")
        XCTAssertTrue(AddPaperLogic.parseAuthors("  ;  ").isEmpty)
    }

    func testAuthorsTextRoundTrip() {
        let text = "He, Kaiming; Zhang, Xiangyu"
        XCTAssertEqual(AddPaperLogic.authorsText(AddPaperLogic.parseAuthors(text)), text)
    }

    func testAuthorsSummaryTruncates() {
        let many = (1...8).map { CreatorInput(family: "A\($0)") }
        XCTAssertEqual(AddPaperLogic.authorsSummary(many), "A1, A2, A3, A4, A5, A6 et al.")
        XCTAssertEqual(AddPaperLogic.authorsSummary([]), "Unknown authors")
    }

    func testYear() {
        XCTAssertNil(AddPaperLogic.parseYear("").value)
        XCTAssertTrue(AddPaperLogic.parseYear("").isValid)
        XCTAssertEqual(AddPaperLogic.parseYear(" 2016 ").value, 2016)
        XCTAssertFalse(AddPaperLogic.parseYear("20x6").isValid)
        XCTAssertFalse(AddPaperLogic.parseYear("10000").isValid)
    }

    func testProbeDropsEmptyIdentifiersAndUsesFirstAuthor() {
        let p = AddPaperLogic.probe(title: "T", doi: "", arxivID: nil, year: 2016,
                                    creators: [CreatorInput(family: "He")])
        XCTAssertNil(p.doi)
        XCTAssertNil(p.arxivID)
        XCTAssertEqual(p.firstAuthorFamily, "He")
        XCTAssertTrue(AddPaperLogic.isWorthChecking(p))
        XCTAssertFalse(AddPaperLogic.isWorthChecking(AddPaperLogic.probe(title: " ", doi: nil, arxivID: nil, year: nil, creators: [])))
    }

    func testGuessedType() {
        XCTAssertEqual(AddPaperLogic.guessedType(doi: nil, arxivID: "1706.03762"), .preprint)
        XCTAssertEqual(AddPaperLogic.guessedType(doi: "10.1/x", arxivID: "1706.03762"), .article)
        XCTAssertEqual(AddPaperLogic.guessedType(doi: nil, arxivID: nil), .article)
    }

    func testCancellationIsRecognised() {
        XCTAssertTrue(AddPaperLogic.isCancellation(CancellationError()))
        XCTAssertTrue(AddPaperLogic.isCancellation(URLError(.cancelled)))
        XCTAssertFalse(AddPaperLogic.isCancellation(URLError(.notConnectedToInternet)))
    }

    func testPDFProblemMessagesMentionManualEntry() {
        for p in [PDFMetadata.Problem.cannotOpen, .passwordProtected, .noPages] {
            XCTAssertTrue(AddPaperLogic.message(for: p).contains("by hand"))
        }
    }

    // MARK: Add to collection

    func testCollectionChoicesAreIndentedAndSurviveLoops() {
        func c(_ id: String, _ parent: String?, _ name: String, _ pos: Int) -> ModelCollection {
            ModelCollection(id: id, parentID: parent, name: name, position: pos, deletedAt: nil)
        }
        let choices = AddPaperLogic.collectionChoices([
            c("2", "1", "Child", 0), c("1", nil, "Top", 0), c("3", "gone", "Orphan", 1),
            c("a", "b", "LoopA", 5), c("b", "a", "LoopB", 6)
        ])
        XCTAssertEqual(Array(choices.prefix(3)).map(\.name), ["Top", "Child", "Orphan"])
        XCTAssertEqual(choices.first(where: { $0.name == "Child" })?.depth, 1)
        XCTAssertEqual(Set(choices.map(\.id)).count, choices.count)
    }

    func testSaveItemPutsThePaperInTheChosenCollection() throws {
        let model = try ModelTestSupport.makeModel(self, sink: nil)
        defer { model.library.close() }

        let folder = try model.collections.create(name: "Thesis")
        let saved = try AddPaperLogic.saveItem(
            model: model, new: NewItem(title: "Paper A"), pdf: nil, collectionID: folder.id
        )
        XCTAssertEqual(try model.collections.items(in: folder.id).map(\.id), [saved.id])

        // No collection chosen: the paper is saved and no folder gains it.
        let plain = try AddPaperLogic.saveItem(
            model: model, new: NewItem(title: "Paper B"), pdf: nil, collectionID: nil
        )
        XCTAssertEqual(try model.collections.items(in: folder.id).map(\.id), [saved.id])
        XCTAssertNotNil(try model.items.fetch(id: plain.id))
    }

    func testSaveItemSavesNothingWhenTheCollectionIsMissing() throws {
        let model = try ModelTestSupport.makeModel(self, sink: nil)
        defer { model.library.close() }

        XCTAssertThrowsError(try AddPaperLogic.saveItem(
            model: model, new: NewItem(title: "Ghost"), pdf: nil, collectionID: UUID().uuidString
        ))
        XCTAssertEqual(try model.items.count(), 0)
    }
}
