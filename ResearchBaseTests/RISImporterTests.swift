//
//  RISImporterTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 20/10/26.
//


//
//  RISImporterTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 10 · F-19
//

import XCTest
@testable import ResearchBase

final class RISImporterTests: XCTestCase {

    func testBasicJournalArticle() {
        let ris = """
        TY  - JOUR
        ID  - smith2020
        AU  - Smith, Jane
        AU  - Doe, John, Jr.
        TI  - Deep Learning
        for Science
        JO  - Nature
        PY  - 2020/05/12/
        VL  - 5
        IS  - 2
        SP  - 10
        EP  - 20
        DO  - https://doi.org/10.1000/ABC
        AB  - An abstract.
        KW  - ignored
        ER  - 

        """
        let r = RISImporter.parse(ris)
        XCTAssertEqual(r.entryCount, 1)
        let e = r.entries[0]
        XCTAssertEqual(e.originalID, "smith2020")
        XCTAssertEqual(e.item.type, .article)
        XCTAssertEqual(e.item.title, "Deep Learning for Science")
        XCTAssertEqual(e.item.year, 2020)
        XCTAssertEqual(e.item.venue, "Nature")
        XCTAssertEqual(e.item.issue, "2")
        XCTAssertEqual(e.item.pages, "10–20")
        XCTAssertEqual(e.item.doi, "10.1000/abc")
        XCTAssertEqual(e.item.abstract, "An abstract.")
        XCTAssertEqual(e.item.sourceKind, .import)
        XCTAssertEqual(e.item.reviewState, .inbox)
        XCTAssertEqual(e.item.creators.map(\.family), ["Smith", "Doe"])
        XCTAssertEqual(e.item.creators[1].suffix, "Jr.")
        XCTAssertTrue(e.warnings.isEmpty)
    }

    func testTypesAndEditors() {
        let r = RISImporter.parse("""
        TY  - CONF
        T1  - A
        A1  - X, Y
        T2  - Proceedings of Z
        PY  - 2018
        DO  - 10.1/a
        ER  -
        TY  - THES
        T1  - B
        A1  - X, Y
        PB  - MIT
        Y1  - 2010
        DO  - 10.1/b
        ER  -
        TY  - CHAP
        T1  - C
        A1  - X, Y
        A2  - E, F
        T2  - The Book
        PY  - 2012
        DO  - 10.1/c
        ER  -
        """)
        XCTAssertEqual(r.entries.map(\.item.type), [.conference, .thesis, .chapter])
        XCTAssertEqual(r.entries[0].item.venue, "Proceedings of Z")
        XCTAssertEqual(r.entries[1].item.publisher, "MIT")
        XCTAssertEqual(r.entries[2].item.creators.last?.role, .editor)
    }

    func testArxivFromURLAndDOI() {
        let r = RISImporter.parse("""
        TY  - UNPB
        TI  - P
        AU  - A, B
        PY  - 2023
        UR  - https://arxiv.org/abs/2301.12345
        ER  -
        TY  - GEN
        TI  - Q
        AU  - A, B
        PY  - 2023
        DO  - 10.48550/arXiv.2302.00001
        ER  -
        """)
        XCTAssertEqual(r.entries[0].item.type, .preprint)
        XCTAssertEqual(r.entries[0].item.arxivID, "2301.12345")
        XCTAssertEqual(r.entries[1].item.arxivID, "2302.00001")
    }

    func testNamesWithoutComma() {
        let r = RISImporter.parse("TY  - BOOK\nTI  - T\nAU  - Jane Q. Public\nAU  - Plato\nPY  - 2001\nER  - ")
        let c = r.entries[0].item.creators
        XCTAssertEqual(c[0].family, "Public")
        XCTAssertEqual(c[0].given, "Jane Q.")
        XCTAssertEqual(c[1].family, "Plato")
    }

    func testMissingEndTitleAndEmpty() {
        let r = RISImporter.parse("""
        TY  - JOUR
        AU  - A, B
        PY  - 2000
        ER  -
        TY  - JOUR
        TI  - No end line
        AU  - A, B
        PY  - 2000
        JO  - J
        DO  - 10.1/z
        """)
        XCTAssertEqual(r.entryCount, 1)
        XCTAssertEqual(r.skipped.count, 1)
        XCTAssertEqual(r.entries[0].warnings.count, 1)
        XCTAssertEqual(RISImporter.parse("").entryCount, 0)
        XCTAssertEqual(RISImporter.parse("hello\nworld").entryCount, 0)
    }

    func testWindowsLineEndingsAndBOM() {
        let r = RISImporter.parse("\u{FEFF}TY  - JOUR\r\nTI  - T\r\nAU  - A, B\r\nPY  - 1999\r\nJO  - J\r\nDO  - 10.1/q\r\nER  - \r\n")
        XCTAssertEqual(r.entryCount, 1)
        XCTAssertEqual(r.entries[0].item.title, "T")
    }

    func testFileReading() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rbA10-\(UUID().uuidString).ris")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("TY  - JOUR\nTI  - Caf\u{E9}\nPY  - 2001\nER  - \n".utf8).write(to: url)
        XCTAssertEqual(try RISImporter.parse(fileAt: url).entries[0].item.title, "Café")
    }
}