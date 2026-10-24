//
//  BibTeXImporterTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 20/10/26.
//


//
//  BibTeXImporterTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 9 · F-19
//

import XCTest
@testable import ResearchBase

final class BibTeXImporterTests: XCTestCase {

    func testBasicArticle() {
        let bib = """
        @article{smith2020deep,
          author = {Smith, Jane and Doe, John},
          title = {Deep {Learning} for Science},
          journal = {Nature},
          year = {2020}, volume = {5}, number = {2}, pages = {10--20},
          doi = {https://doi.org/10.1000/ABC}
        }
        """
        let r = BibTeXImporter.parse(bib)
        XCTAssertEqual(r.entryCount, 1)
        let e = r.entries[0]
        XCTAssertEqual(e.originalKey, "smith2020deep")
        XCTAssertEqual(e.item.type, .article)
        XCTAssertEqual(e.item.title, "Deep Learning for Science")
        XCTAssertEqual(e.item.year, 2020)
        XCTAssertEqual(e.item.venue, "Nature")
        XCTAssertEqual(e.item.issue, "2")
        XCTAssertEqual(e.item.pages, "10–20")
        XCTAssertEqual(e.item.doi, "10.1000/abc")
        XCTAssertEqual(e.item.sourceKind, .import)
        XCTAssertEqual(e.item.reviewState, .inbox)
        XCTAssertEqual(e.item.creators.map(\.family), ["Smith", "Doe"])
        XCTAssertEqual(e.item.creators.map(\.given), ["Jane", "John"])
        XCTAssertTrue(e.warnings.isEmpty)
    }

    func testNamesGivenFamilyAndParticles() {
        let r = BibTeXImporter.parse("@book{k, title={T}, year=2001, author={Ludwig van Beethoven and {World Health Organization}}}")
        let c = r.entries[0].item.creators
        XCTAssertEqual(c[0].family, "van Beethoven")
        XCTAssertEqual(c[0].given, "Ludwig")
        XCTAssertTrue(c[1].isOrganisation)
        XCTAssertEqual(c[1].family, "World Health Organization")
    }

    func testAccentsAndQuotedValuesAndMacros() {
        let bib = """
        @string{nips = "Neural Information Processing"}
        @inproceedings{m,
          author = "M{\\"u}ller, Fran{\\c c}ois",
          title = "On " # {Caf\\'e} # " Systems",
          booktitle = nips,
          year = 2019, month = jan
        }
        """
        let r = BibTeXImporter.parse(bib)
        let e = r.entries[0]
        XCTAssertEqual(e.item.type, .conference)
        XCTAssertEqual(e.item.creators[0].family, "Müller")
        XCTAssertEqual(e.item.creators[0].given, "François")
        XCTAssertEqual(e.item.title, "On Café Systems")
        XCTAssertEqual(e.item.venue, "Neural Information Processing")
    }

    func testPreprintFromEprint() {
        let r = BibTeXImporter.parse("@misc{a, title={X}, author={A, B}, year={2023}, eprint={2301.12345}, archivePrefix={arXiv}}")
        XCTAssertEqual(r.entries[0].item.type, .preprint)
        XCTAssertEqual(r.entries[0].item.arxivID, "2301.12345")
    }

    func testThesisReportAndEditors() {
        let r = BibTeXImporter.parse("""
        @phdthesis{t, title={A}, author={X, Y}, school={MIT}, year=2010}
        @techreport{r, title={B}, author={X, Y}, institution={CERN}, year=2011}
        @incollection{c, title={C}, author={X, Y}, editor={E, F}, booktitle={Book}, year=2012}
        """)
        XCTAssertEqual(r.entries.map(\.item.type), [.thesis, .report, .chapter])
        XCTAssertEqual(r.entries[0].item.publisher, "MIT")
        XCTAssertEqual(r.entries[1].item.publisher, "CERN")
        XCTAssertEqual(r.entries[2].item.creators.last?.role, .editor)
    }

    func testIgnoresCommentsPreambleAndSkipsBrokenEntries() {
        let r = BibTeXImporter.parse("""
        % a comment
        @comment{ignored @article{x, title={no}} }
        @preamble{"\\newcommand{\\foo}{bar}"}
        @article{notitle, author={A, B}, year=2000}
        @article{ok, title={Fine}, author={A, B}, year=2000, journal={J}, doi={10.1/x}}
        @article{broken, title={Unclosed
        """)
        XCTAssertEqual(r.entries.map(\.originalKey), ["ok"])
        XCTAssertEqual(r.skipped.count, 2)
        XCTAssertTrue(r.summary.contains("1 entry"))
    }

    func testWarningsAndEmptyInput() {
        let r = BibTeXImporter.parse("@article{w, title={T}}")
        XCTAssertGreaterThanOrEqual(r.entries[0].warnings.count, 3)
        XCTAssertEqual(BibTeXImporter.parse("").entryCount, 0)
        XCTAssertEqual(BibTeXImporter.parse("just text, no entries").entryCount, 0)
    }

    func testAuthorsOthersWarning() {
        let r = BibTeXImporter.parse("@article{o, title={T}, author={A, B and others}, year=2000, journal={J}, doi={10.1/y}}")
        XCTAssertEqual(r.entries[0].item.creators.count, 1)
        XCTAssertEqual(r.entries[0].warnings.count, 1)
    }

    func testFileReadingFallsBackToLatin1() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rbA9-\(UUID().uuidString).bib")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("@article{l, title={Caf\u{E9}}, year=2001}".utf8).write(to: url)
        XCTAssertEqual(try BibTeXImporter.parse(fileAt: url).entries[0].item.title, "Café")
    }
}