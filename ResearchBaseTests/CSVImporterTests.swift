//
//  CSVImporterTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 20/10/26.
//


//
//  CSVImporterTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 11 · F-19
//

import XCTest
@testable import ResearchBase

final class CSVImporterTests: XCTestCase {

    func testZoteroStyleRow() {
        let csv = """
        "Key","Item Type","Publication Year","Author","Title","Publication Title","Volume","Issue","Pages","DOI","Abstract Note","Date Added"
        "ABC","Journal Article","2020","Smith, Jane; Doe, John","Deep \"\"Learning\"\"","Nature","5","2","10--20","https://doi.org/10.1000/ABC","Line one
        line two","2021-01-01"
        """
        let r = CSVImporter.parse(csv)
        XCTAssertEqual(r.entryCount, 1)
        let e = r.entries[0]
        XCTAssertEqual(e.row, 2)
        XCTAssertEqual(e.item.type, .article)
        XCTAssertEqual(e.item.title, "Deep \"Learning\"")
        XCTAssertEqual(e.item.year, 2020)
        XCTAssertEqual(e.item.venue, "Nature")
        XCTAssertEqual(e.item.pages, "10–20")
        XCTAssertEqual(e.item.doi, "10.1000/abc")
        XCTAssertEqual(e.item.abstract, "Line one line two")
        XCTAssertEqual(e.item.creators.map(\.family), ["Smith", "Doe"])
        XCTAssertEqual(e.item.creators.map(\.given), ["Jane", "John"])
        XCTAssertEqual(e.item.sourceKind, .import)
        XCTAssertEqual(e.item.reviewState, .inbox)
        XCTAssertTrue(e.warnings.isEmpty)
        XCTAssertTrue(r.ignoredColumns.contains("Date Added"))
        XCTAssertTrue(r.recognisedColumns.contains("Publication Title"))
    }

    func testSemicolonAndTabDelimiters() {
        let semi = CSVImporter.parse("title;year;doi\nA;2001;10.1/a\nB;2002;10.1/b")
        XCTAssertEqual(semi.entries.map(\.item.title), ["A", "B"])
        let tab = CSVImporter.parse("Title\tYear\tDOI\nA\t2001\t10.1/a")
        XCTAssertEqual(tab.entries[0].item.year, 2001)
    }

    func testOwnExportRoundTripAndFormulaGuard() {
        let csv = "\u{FEFF}id,citation_key,title,authors,year,publication_type,venue,doi\r\n"
            + "1,k,'=Odd title,Jane Smith and John Doe,2019,Conference Paper,Proc,10.1/z\r\n"
        let r = CSVImporter.parse(csv)
        XCTAssertEqual(r.entryCount, 1)
        XCTAssertEqual(r.entries[0].item.title, "=Odd title")
        XCTAssertEqual(r.entries[0].item.type, .conference)
        XCTAssertEqual(r.entries[0].item.creators.map(\.family), ["Smith", "Doe"])
        XCTAssertTrue(r.ignoredColumns.contains("citation_key"))
    }

    func testAuthorListShapes() {
        func names(_ authors: String) -> [String] {
            let q = authors.replacingOccurrences(of: "\"", with: "\"\"")
            return CSVImporter.parse("title,authors\nT,\"\(q)\"").entries[0].item.creators.map(\.family)
        }
        XCTAssertEqual(names("Smith, Jane"), ["Smith"])
        XCTAssertEqual(names("Jane Smith, John Doe"), ["Smith", "Doe"])
        XCTAssertEqual(names("Jane Smith, John Doe, Ann Lee"), ["Smith", "Doe", "Lee"])
        XCTAssertEqual(names("Smith, Jane; Doe"), ["Smith", "Doe"])
    }

    func testMissingTitleColumnAndBlankRows() {
        let none = CSVImporter.parse("name2,year\nA,2000")
        XCTAssertEqual(none.entryCount, 0)
        XCTAssertEqual(none.skipped.count, 1)

        let r = CSVImporter.parse("Title,Year\nA,2000\n,,\n,1999\n\nB,2001\n")
        XCTAssertEqual(r.entries.map(\.item.title), ["A", "B"])
        XCTAssertEqual(r.skipped.count, 1)
        XCTAssertEqual(r.entries[1].row, 6)
    }

    func testUnknownTypeAndArxivURL() {
        let r = CSVImporter.parse("""
        Title,Type,URL,Year
        A,Podcast,http://x,2000
        B,,https://arxiv.org/abs/2301.12345,2023
        """)
        XCTAssertEqual(r.entries[0].item.type, .article)
        XCTAssertTrue(r.entries[0].warnings.contains { $0.contains("Podcast") })
        XCTAssertEqual(r.entries[1].item.type, .preprint)
        XCTAssertEqual(r.entries[1].item.arxivID, "2301.12345")
    }

    func testEmptyAndUnclosedQuote() {
        XCTAssertEqual(CSVImporter.parse("").entryCount, 0)
        XCTAssertEqual(CSVImporter.parse("   \n").entryCount, 0)
        let r = CSVImporter.parse("Title\n\"never closed")
        XCTAssertEqual(r.entryCount, 1)
        XCTAssertEqual(r.skipped.count, 1)
    }

    func testFileReading() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rbA11-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("Title,Year\nCaf\u{E9},2001\n".utf8).write(to: url)
        XCTAssertEqual(try CSVImporter.parse(fileAt: url).entries[0].item.title, "Café")
    }
}