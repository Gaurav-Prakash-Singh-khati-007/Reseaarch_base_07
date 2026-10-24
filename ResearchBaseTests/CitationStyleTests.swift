//
//  CitationStyleTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 22/10/26.
//


//
//  CitationStyleTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 52 · Feature: F-34 (the hook from CitationStyle.swift to CSLEngine).
//  Tests only CitationStyle.swift. The CSL engine itself is covered by CSLEngineTests.
//  Papers are built in memory and never saved, so nothing touches disk.
//

import XCTest
@testable import ResearchBase

@MainActor
final class CitationStyleTests: XCTestCase {

    // MARK: Helpers

    private func makePaper(
        title: String = "Attention is all you need",
        authors: String = "Vaswani, Ashish; Shazeer, Noam",
        venue: String = "NeurIPS",
        year: Int = 2017,
        key: String = "vaswani2017attention",
        type: PublicationType = .conferencePaper,
        publisher: String = ""
    ) -> PaperRecord {
        PaperRecord(
            pdfFilePath: "",
            title: title,
            authors: authors,
            venue: venue,
            year: year,
            citationKey: key,
            publicationTypeRawValue: type.rawValue,
            publisher: publisher
        )
    }

    // MARK: The style enum

    func testStyleListHasFiveStylesWithTheRightIDs() {
        XCTAssertEqual(CitationStyle.allCases.count, 5)
        XCTAssertEqual(
            CitationStyle.allCases.map(\.cslID),
            ["apa", "ieee", "harvard", "nature", "chicago"]
        )
        // Every style must point at a style the engine really ships.
        let shipped = Set(CSLEngine.builtInStyles.map(\.id))
        for style in CitationStyle.allCases {
            XCTAssertTrue(shipped.contains(style.cslID), style.rawValue)
            XCTAssertNotNil(style.cslStyle, style.rawValue)
        }
    }

    func testBstNamesForLatex() {
        XCTAssertEqual(CitationStyle.apa.bstName, "apalike")
        XCTAssertEqual(CitationStyle.ieee.bstName, "IEEEtran")
        XCTAssertEqual(CitationStyle.harvard.bstName, "agsm")
        XCTAssertEqual(CitationStyle.nature.bstName, "naturemag")
        XCTAssertEqual(CitationStyle.chicago.bstName, "chicago")
    }

    func testOnlyIEEEAndNatureAreNumeric() {
        XCTAssertTrue(CitationStyle.ieee.isNumeric)
        XCTAssertTrue(CitationStyle.nature.isNumeric)
        XCTAssertFalse(CitationStyle.apa.isNumeric)
        XCTAssertFalse(CitationStyle.harvard.isNumeric)
        XCTAssertFalse(CitationStyle.chicago.isNumeric)
    }

    func testDisplayNamesAreLongNames() {
        for style in CitationStyle.allCases {
            XCTAssertFalse(style.displayName.isEmpty, style.rawValue)
        }
        XCTAssertEqual(CitationStyle.ieee.displayName, "IEEE")
        XCTAssertEqual(CitationStyle.apa.displayName, "APA (7th, simplified)")
    }

    // MARK: Picker rows and imported styles

    func testAvailableStylesMatchTheBuiltInStyles() {
        let choices = CitationFormatter.availableStyles()

        XCTAssertEqual(choices.map(\.id), CSLEngine.builtInStyles.map(\.id))
        XCTAssertTrue(choices.allSatisfy { !$0.isImported })
        XCTAssertTrue(choices.allSatisfy { !$0.name.isEmpty && !$0.bstName.isEmpty })
        XCTAssertEqual(choices.first { $0.id == "ieee" }?.isNumeric, true)
        XCTAssertEqual(choices.first { $0.id == "apa" }?.isNumeric, false)
    }

    func testImportedStyleBecomesAnImportedChoice() throws {
        let style = try XCTUnwrap(CSLEngine.builtIn("harvard"))

        let choice = CitationFormatter.choice(for: style)

        XCTAssertTrue(choice.isImported)
        XCTAssertEqual(choice.id, style.id)
        XCTAssertFalse(choice.name.isEmpty)
        XCTAssertEqual(choice.isNumeric, style.isNumeric)
    }

    func testLoadingABadCSLFileThrows() {
        XCTAssertThrowsError(try CitationFormatter.loadCSLStyle(from: Data("not xml".utf8)))
        XCTAssertThrowsError(try CitationFormatter.loadCSLStyle(from: Data("<foo/>".utf8))) {
            XCTAssertEqual($0 as? CSLEngineError, .notCSL)
        }
    }

    // MARK: APA and IEEE are unchanged

    func testApaTextIsUnchanged() {
        let paper = makePaper()

        XCTAssertEqual(
            CitationFormatter.citation(for: paper, style: .apa),
            "Vaswani, A., Shazeer, N. (2017). Attention is all you need. NeurIPS."
        )
    }

    func testIeeeTextIsUnchanged() {
        let paper = makePaper()

        XCTAssertEqual(
            CitationFormatter.citation(for: paper, style: .ieee),
            "A. Vaswani, N. Shazeer, \"Attention is all you need,\", NeurIPS, 2017."
        )
    }

    func testApaAndIeeeStillHandleMissingYearAndTitle() {
        let paper = makePaper(title: "  ", venue: "", year: 0)

        XCTAssertTrue(CitationFormatter.apaCitation(for: paper).contains("(n.d.)."))
        XCTAssertTrue(CitationFormatter.apaCitation(for: paper).contains("Untitled."))
        XCTAssertTrue(CitationFormatter.ieeeCitation(for: paper).contains("n.d."))
    }

    // MARK: Harvard, Nature and Chicago come from CSL

    func testCSLStylesNeverComeBackBlank() {
        let paper = makePaper()

        for style in CitationStyle.allCases {
            let text = CitationFormatter.citation(for: paper, style: style)
            XCTAssertFalse(
                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                style.rawValue
            )
        }
    }

    func testHarvardNatureAndChicagoUseTheCSLEntry() throws {
        let paper = makePaper()

        for style in [CitationStyle.harvard, .nature, .chicago] {
            let csl = try XCTUnwrap(
                CitationFormatter.cslBibliographyEntry(for: paper, style: style),
                style.rawValue
            )
            XCTAssertEqual(CitationFormatter.citation(for: paper, style: style), csl, style.rawValue)
            XCTAssertTrue(csl.contains("Vaswani"), csl)
        }
    }

    // MARK: Turning a paper into a CSL reference

    func testCSLTypeMapping() {
        XCTAssertEqual(CitationFormatter.cslType(for: .journalArticle), "article-journal")
        XCTAssertEqual(CitationFormatter.cslType(for: .conferencePaper), "paper-conference")
        XCTAssertEqual(CitationFormatter.cslType(for: .workshopPaper), "paper-conference")
        XCTAssertEqual(CitationFormatter.cslType(for: .book), "book")
        XCTAssertEqual(CitationFormatter.cslType(for: .bookChapter), "chapter")
        XCTAssertEqual(CitationFormatter.cslType(for: .thesis), "thesis")
        XCTAssertEqual(CitationFormatter.cslType(for: .technicalReport), "report")
        XCTAssertEqual(CitationFormatter.cslType(for: .preprint), "article")
        XCTAssertEqual(CitationFormatter.cslType(for: .website), "webpage")
        XCTAssertEqual(CitationFormatter.cslType(for: .other), "article-journal")
    }

    func testAuthorStringsBecomeNames() {
        let semicolons = CitationFormatter.cslNames(from: "A. Smith; B. Jones")
        XCTAssertEqual(semicolons.map(\.family), ["Smith", "Jones"])
        XCTAssertEqual(semicolons.map(\.given), ["A.", "B."])

        let surnameFirst = CitationFormatter.cslNames(from: "Smith, A.")
        XCTAssertEqual(surnameFirst.count, 1)
        XCTAssertEqual(surnameFirst.first?.family, "Smith")
        XCTAssertEqual(surnameFirst.first?.given, "A.")

        let single = CitationFormatter.cslNames(from: "Plato")
        XCTAssertEqual(single.first?.family, "Plato")
        XCTAssertEqual(single.first?.given, "")

        XCTAssertTrue(CitationFormatter.cslNames(from: "   ").isEmpty)
    }

    func testReferenceUsesTheCitationKeyAndFallsBackToTheID() {
        let keyed = makePaper(key: "  vaswani2017attention  ")
        XCTAssertEqual(CitationFormatter.cslReference(for: keyed).id, "vaswani2017attention")

        let unkeyed = makePaper(key: "")
        XCTAssertEqual(CitationFormatter.cslReference(for: unkeyed).id, unkeyed.id.uuidString)
    }

    func testReferenceFieldsAndMissingYear() {
        let paper = makePaper(year: 0)

        let reference = CitationFormatter.cslReference(for: paper)

        XCTAssertEqual(reference.type, "paper-conference")
        XCTAssertEqual(reference.title, "Attention is all you need")
        XCTAssertEqual(reference.authors.count, 2)
        XCTAssertNil(reference.year, "no year must not become 0")
    }

    func testVenueIsThePublisherForBooksAndTheContainerForEverythingElse() {
        let book = makePaper(venue: "MIT Press", type: .book)
        let bookRef = CitationFormatter.cslReference(for: book)
        XCTAssertEqual(bookRef.publisher, "MIT Press")

        let bookWithPublisher = makePaper(venue: "Ignored", type: .book, publisher: "Springer")
        XCTAssertEqual(CitationFormatter.cslReference(for: bookWithPublisher).publisher, "Springer")

        let article = makePaper(venue: "Nature", type: .journalArticle)
        XCTAssertEqual(CitationFormatter.cslReference(for: article).containerTitle, "Nature")
    }

    // MARK: Bibliography and in-text citations

    func testBibliographyEntryAndList() throws {
        let apa = try XCTUnwrap(CitationStyle.apa.cslStyle)
        let paper = makePaper()
        let other = makePaper(
            title: "Deep learning",
            authors: "LeCun, Yann",
            venue: "Nature",
            year: 2015,
            key: "lecun2015deep",
            type: .journalArticle
        )

        let entry = try XCTUnwrap(CitationFormatter.cslBibliographyEntry(for: paper, style: apa))
        XCTAssertTrue(entry.contains("Vaswani"), entry)
        XCTAssertTrue(entry.contains("2017"), entry)

        let list = CitationFormatter.cslBibliography(for: [paper, other], style: apa)
        XCTAssertEqual(list.count, 2)
        XCTAssertTrue(list[0].hasPrefix("LeCun"), "sorted by author, not by the order given: \(list)")
    }

    func testApaInTextCitation() throws {
        let apa = try XCTUnwrap(CitationStyle.apa.cslStyle)

        let text = CitationFormatter.cslInTextCitation(for: [makePaper()], style: apa)

        XCTAssertTrue(text.hasPrefix("("), text)
        XCTAssertTrue(text.contains("Vaswani"), text)
        XCTAssertTrue(text.contains("2017"), text)
    }

    func testNumericInTextCitationNumbersPapersInOrderOrByTheGivenNumbers() throws {
        let ieee = try XCTUnwrap(CitationStyle.ieee.cslStyle)
        let paper = makePaper()

        XCTAssertEqual(CitationFormatter.cslInTextCitation(for: [paper], style: ieee), "[1]")
        XCTAssertEqual(
            CitationFormatter.cslInTextCitation(
                for: [paper], style: ieee, numbers: ["vaswani2017attention": 7]
            ),
            "[7]"
        )
    }

    func testLocatorAppearsInTheCitation() throws {
        let apa = try XCTUnwrap(CitationStyle.apa.cslStyle)

        let text = CitationFormatter.cslInTextCitation(
            for: [makePaper()], style: apa, locators: ["vaswani2017attention": "5"]
        )

        XCTAssertTrue(text.contains("5"), text)
    }

    // MARK: The SQLite layer (ModelItem + creators)

    func testModelItemBibliographyAndNumberedCitation() throws {
        let model = try ModelTestSupport.makeModel(self)
        addTeardownBlock { model.library.close() }
        let item = try ModelTestSupport.item(model)
        let creators = [
            ItemCreator(
                creator: Creator(
                    id: "c1", family: "McMahan", given: "Brendan", suffix: "",
                    isOrganisation: false, orcid: nil, norm: "mcmahan brendan"
                ),
                role: .author,
                position: 0
            )
        ]
        let apa = try XCTUnwrap(CitationStyle.apa.cslStyle)
        let ieee = try XCTUnwrap(CitationStyle.ieee.cslStyle)

        let entry = try XCTUnwrap(
            CitationFormatter.cslBibliographyEntry(for: item, creators: creators, style: apa)
        )
        XCTAssertTrue(entry.contains("McMahan"), entry)

        XCTAssertEqual(
            CitationFormatter.cslInTextCitation(for: item, creators: creators, style: ieee, number: 3),
            "[3]"
        )
        XCTAssertEqual(
            CitationFormatter.cslInTextCitation(for: item, creators: creators, style: ieee),
            "[1]",
            "no number given means 1"
        )
    }
}
