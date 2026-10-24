//
//  CSLEngineTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 20/10/26.
//


//
//  CSLEngineTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 23 · F-34. Tests only the CSL engine; no database needed.
//

import XCTest
@testable import ResearchBase

final class CSLEngineTests: XCTestCase {

    private func vaswani() -> CSLReference {
        var r = CSLReference(id: "vaswani2017attention")
        r.type = "paper-conference"
        r.title = "Attention is all you need"
        r.containerTitle = "Advances in Neural Information Processing Systems"
        r.authors = [CSLName(family: "Vaswani", given: "Ashish"), CSLName(family: "Shazeer", given: "Noam")]
        r.year = 2017
        r.page = "5998-6008"
        return r
    }

    private func journal() -> CSLReference {
        var r = CSLReference(id: "lecun2015deep")
        r.title = "Deep learning"
        r.containerTitle = "Nature"
        r.authors = [CSLName(family: "LeCun", given: "Yann"), CSLName(family: "Bengio", given: "Yoshua"), CSLName(family: "Hinton", given: "Geoffrey")]
        r.year = 2015
        r.volume = "521"
        r.issue = "7553"
        r.page = "436-444"
        r.doi = "10.1038/nature14539"
        return r
    }

    private func engine(_ id: String, _ format: CSLOutputFormat = .plain) throws -> CSLEngine {
        CSLEngine(style: try XCTUnwrap(CSLEngine.builtIn(id), id), format: format)
    }

    // MARK: Styles load

    func testEveryBuiltInStyleParses() {
        XCTAssertEqual(CSLEngine.builtInStyles.count, 5)
        for s in CSLEngine.builtInStyles {
            XCTAssertNotNil(CSLEngine.builtIn(s.id), s.id)
            XCTAssertEqual(CSLEngine.bstName(forStyleID: "researchbase/\(s.id)"), s.bst, s.id)
        }
    }

    func testBadFilesThrow() {
        XCTAssertThrowsError(try CSLStyle.parse(Data("not xml".utf8)))
        XCTAssertThrowsError(try CSLStyle.parse(Data("<foo/>".utf8))) { XCTAssertEqual($0 as? CSLEngineError, .notCSL) }
        XCTAssertThrowsError(try CSLStyle.parse(Data("<style/>".utf8))) { XCTAssertEqual($0 as? CSLEngineError, .missingLayout) }
    }

    // MARK: Author-date

    func testApaInTextCitation() throws {
        let e = try engine("apa")
        XCTAssertEqual(e.citation([CSLCitationItem(vaswani())]), "(Vaswani & Shazeer, 2017)")
        XCTAssertEqual(e.citation([CSLCitationItem(journal())]), "(LeCun et al., 2015)")
        XCTAssertEqual(e.citation([CSLCitationItem(journal(), locator: "437")]), "(LeCun et al., 2015, p. 437)")
    }

    func testApaBibliographyEntry() throws {
        let entry = try engine("apa").bibliography([journal()])[0]
        XCTAssertTrue(entry.hasPrefix("LeCun, Y., Bengio, Y., & Hinton, G. (2015). Deep learning."), entry)
        XCTAssertTrue(entry.contains("Nature, 521(7553), 436\u{2013}444"), entry)
        XCTAssertTrue(entry.hasSuffix("https://doi.org/10.1038/nature14539"), entry)
    }

    func testMarkdownKeepsItalics() throws {
        let entry = try engine("apa", .markdown).bibliography([journal()])[0]
        XCTAssertTrue(entry.contains("*Nature*"), entry)
        XCTAssertFalse(try engine("apa").bibliography([journal()])[0].contains("*"))
    }

    func testSameAuthorSameYearGetsLetters() throws {
        var a = journal(); a.id = "a"; a.title = "Alpha"
        var b = journal(); b.id = "b"; b.title = "Beta"
        let e = try engine("harvard")
        let all = [a, b]
        XCTAssertTrue(e.citation([CSLCitationItem(a)], allReferences: all).contains("2015a"))
        XCTAssertTrue(e.citation([CSLCitationItem(b)], allReferences: all).contains("2015b"))
        let bib = e.bibliography(all)
        XCTAssertTrue(bib[0].contains("(2015a)"), bib[0])
        XCTAssertTrue(bib[1].contains("(2015b)"), bib[1])
    }

    func testBibliographyIsSortedByAuthor() throws {
        let sorted = try engine("chicago").bibliography([vaswani(), journal()])
        XCTAssertTrue(sorted[0].hasPrefix("LeCun"), sorted[0])
        XCTAssertTrue(sorted[1].hasPrefix("Vaswani"), sorted[1])
    }

    // MARK: Numeric

    func testIeeeNumbersAndRangesCollapse() throws {
        let e = try engine("ieee")
        let refs = (1...4).map { i -> CSLReference in var r = journal(); r.id = "r\(i)"; return r }
        let numbers = Dictionary(uniqueKeysWithValues: refs.enumerated().map { ($1.id, $0 + 1) })
        XCTAssertEqual(e.citation([CSLCitationItem(refs[0])], numbers: numbers), "[1]")
        XCTAssertEqual(e.citation(refs.map { CSLCitationItem($0) }, numbers: numbers), "[1\u{2013}4]")
        XCTAssertEqual(e.citation([CSLCitationItem(refs[0]), CSLCitationItem(refs[2])], numbers: numbers), "[1, 3]")
    }

    func testIeeeBibliographyEntry() throws {
        let entry = try engine("ieee").bibliography([journal()])[0]
        XCTAssertTrue(entry.hasPrefix("[1] Y. LeCun"), entry)
        XCTAssertTrue(entry.contains("\u{201C}Deep learning\u{201D}"), entry)
        XCTAssertTrue(entry.hasSuffix("."), entry)
    }

    func testNatureUsesBareNumbers() throws {
        let e = try engine("nature")
        XCTAssertEqual(e.citation([CSLCitationItem(journal())], numbers: ["lecun2015deep": 7]), "7")
    }

    // MARK: Custom .csl file

    func testCustomStyleFileIsRead() throws {
        let xml = """
        <style xmlns="http://purl.org/net/xbiblio/csl" class="in-text" version="1.0">
          <info><title>Mine</title><id>x/mine</id></info>
          <citation><layout prefix="{" suffix="}"><text variable="citation-label"/></layout></citation>
          <bibliography><layout><text variable="title" text-case="uppercase"/></layout></bibliography>
        </style>
        """
        let e = try CSLEngine(styleXML: Data(xml.utf8))
        XCTAssertEqual(e.style.title, "Mine")
        XCTAssertEqual(e.citation([CSLCitationItem(journal())]), "{lecun2015deep}")
        XCTAssertEqual(e.bibliography([journal()]), ["DEEP LEARNING"])
    }

    func testEmptyGroupDisappears() throws {
        let xml = """
        <style xmlns="http://purl.org/net/xbiblio/csl" class="in-text" version="1.0">
          <info><title>G</title><id>x/g</id></info>
          <citation><layout><text variable="title"/></layout></citation>
          <bibliography><layout><group prefix="[" suffix="]"><text variable="volume"/></group><text variable="title"/></layout></bibliography>
        </style>
        """
        var r = journal(); r.volume = ""
        XCTAssertEqual(try CSLEngine(styleXML: Data(xml.utf8)).bibliography([r]), ["Deep learning"])
    }

    func testBstNames() {
        XCTAssertEqual(CSLEngine.bstName(forStyleID: "ieee"), "IEEEtran")
        XCTAssertEqual(CSLEngine.bstName(forStyleID: "unknown-style"), "plainnat")
    }
}