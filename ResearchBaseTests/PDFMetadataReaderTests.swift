//
//  PDFMetadataReaderTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 6 · Features: F-16
//
//  Pure-parsing tests need no PDF. The end-to-end tests draw small real PDFs
//  into a temporary folder that is removed afterwards.
//

import XCTest
import CoreGraphics
import CoreText
import PDFKit
@testable import ResearchBase

@MainActor
final class PDFMetadataReaderTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFMetadataReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: DOI

    func testDOIFromURLAndLabelAndPlainText() {
        XCTAssertEqual(PDFMetadataReader.extractDOI(from: "https://doi.org/10.1109/CVPR.2016.90"), "10.1109/cvpr.2016.90")
        XCTAssertEqual(PDFMetadataReader.extractDOI(from: "DOI: 10.1145/3292500.3330701"), "10.1145/3292500.3330701")
        XCTAssertEqual(PDFMetadataReader.extractDOI(from: "see 10.1000/xyz123 for details"), "10.1000/xyz123")
    }

    func testDOITrailingPunctuationAndBracketsAreTrimmed() {
        XCTAssertEqual(PDFMetadataReader.extractDOI(from: "(doi:10.1000/abc.def)."), "10.1000/abc.def")
        XCTAssertEqual(PDFMetadataReader.extractDOI(from: "doi 10.1000/abc.def,"), "10.1000/abc.def")
        XCTAssertEqual(PDFMetadataReader.extractDOI(from: "10.1002/(SICI)1097-4571(199806)49:8"), "10.1002/(sici)1097-4571(199806)49:8")
    }

    func testLabelledDOIWinsOverAnEarlierCitedOne() {
        let text = "Cites 10.1111/other.2001.5 in passing.\nDOI: 10.2222/this.paper.9"
        XCTAssertEqual(PDFMetadataReader.extractDOI(from: text), "10.2222/this.paper.9")
    }

    func testNoDOI() {
        XCTAssertNil(PDFMetadataReader.extractDOI(from: ""))
        XCTAssertNil(PDFMetadataReader.extractDOI(from: "Version 10.5 released in 2020"))
    }

    // MARK: arXiv

    func testArXivIDsAndYear() {
        XCTAssertEqual(PDFMetadataReader.extractArXivID(from: "arXiv:2101.12345v2 [cs.LG] 5 Jan 2021"), "2101.12345")
        XCTAssertEqual(PDFMetadataReader.extractArXivID(from: "arXiv:hep-th/9901001v1"), "hep-th/9901001")
        XCTAssertEqual(PDFMetadataReader.extractArXivID(from: "https://arxiv.org/abs/1706.03762"), "1706.03762")
        XCTAssertNil(PDFMetadataReader.extractArXivID(from: "no identifier here"))

        XCTAssertEqual(PDFMetadataReader.year(fromArXivID: "1706.03762"), 2017)
        XCTAssertEqual(PDFMetadataReader.year(fromArXivID: "hep-th/9901001"), 1999)
        XCTAssertNil(PDFMetadataReader.year(fromArXivID: "0001.00001"), "new-style IDs start in 2007")
        XCTAssertNil(PDFMetadataReader.year(fromArXivID: "2113.00001"), "month 13 is not a month")
    }

    // MARK: Title

    func testInfoTitleRejectsJunk() {
        XCTAssertNil(PDFMetadataReader.cleanedInfoTitle(nil))
        XCTAssertNil(PDFMetadataReader.cleanedInfoTitle("   "))
        XCTAssertNil(PDFMetadataReader.cleanedInfoTitle("Untitled"))
        XCTAssertNil(PDFMetadataReader.cleanedInfoTitle("Microsoft Word - paper_final.doc"))
        XCTAssertNil(PDFMetadataReader.cleanedInfoTitle("final_paper_v3.pdf"))
        XCTAssertNil(PDFMetadataReader.cleanedInfoTitle("draft_notes_v2"))
        XCTAssertNil(PDFMetadataReader.cleanedInfoTitle("arXiv:2101.12345v2"))
        XCTAssertNil(PDFMetadataReader.cleanedInfoTitle("Abstract"))
        XCTAssertEqual(
            PDFMetadataReader.cleanedInfoTitle("  Deep   Residual Learning\nfor Image Recognition "),
            "Deep Residual Learning for Image Recognition"
        )
    }

    func testLargestFontTitleJoinsWrappedLines() {
        let runs = [
            PDFTextRun(text: "Communication-Efficient Learning\n", fontSize: 18),
            PDFTextRun(text: "of Deep Networks\n", fontSize: 18),
            PDFTextRun(text: "H. Brendan McMahan, Eider Moore\n", fontSize: 11),
            PDFTextRun(text: String(repeating: "Body text goes here and runs on. ", count: 20), fontSize: 10)
        ]
        XCTAssertEqual(
            PDFMetadataReader.largestFontTitle(from: runs),
            "Communication-Efficient Learning of Deep Networks"
        )
    }

    func testLargestFontTitleNeedsAClearlyBiggerSize() {
        let runs = [
            PDFTextRun(text: "Looks like a heading but is barely larger\n", fontSize: 10.5),
            PDFTextRun(text: String(repeating: "Body text goes here and runs on. ", count: 20), fontSize: 10)
        ]
        XCTAssertNil(PDFMetadataReader.largestFontTitle(from: runs))
        XCTAssertNil(PDFMetadataReader.largestFontTitle(from: []))
    }

    func testInfoTitleConfirmedByPageBeatsBiggestFont() {
        let runs = [
            PDFTextRun(text: "JOURNAL OF EXAMPLES\n", fontSize: 24),
            PDFTextRun(text: String(repeating: "Body text goes here and runs on. ", count: 20), fontSize: 10)
        ]
        let info = PDFInfoRecord(title: "A Study of Small Things")
        let result = PDFMetadataReader.parse(
            pageText: "JOURNAL OF EXAMPLES\nA Study of\nSmall Things\nBody text",
            runs: runs, info: info, pageCount: 3
        )
        XCTAssertEqual(result.title, "A Study of Small Things")
    }

    func testPageFontTitleBeatsAnInfoTitleThePageDoesNotShow() {
        let runs = [
            PDFTextRun(text: "Real Title On The Page\n", fontSize: 20),
            PDFTextRun(text: String(repeating: "Body text goes here and runs on. ", count: 20), fontSize: 10)
        ]
        let info = PDFInfoRecord(title: "Some Other Metadata Title")
        let result = PDFMetadataReader.parse(
            pageText: "Real Title On The Page\nBody text", runs: runs, info: info, pageCount: 1
        )
        XCTAssertEqual(result.title, "Real Title On The Page")
    }

    func testNoTitleWhenNothingTrustworthy() {
        let result = PDFMetadataReader.parse(
            pageText: String(repeating: "plain body text ", count: 10),
            runs: [], info: PDFInfoRecord(title: "Untitled"), pageCount: 1
        )
        XCTAssertNil(result.title)
    }

    // MARK: Authors

    func testSplitAuthors() {
        XCTAssertEqual(PDFMetadataReader.splitAuthors("Kaiming He; Xiangyu Zhang"), ["Kaiming He", "Xiangyu Zhang"])
        XCTAssertEqual(PDFMetadataReader.splitAuthors("Kaiming He, Xiangyu Zhang, and Shaoqing Ren"),
                       ["Kaiming He", "Xiangyu Zhang", "Shaoqing Ren"])
        XCTAssertEqual(PDFMetadataReader.splitAuthors("He, Kaiming; Zhang, Xiangyu"), ["He, Kaiming", "Zhang, Xiangyu"],
                       "semicolons mean each part is already one name; nothing is reordered")
        XCTAssertEqual(PDFMetadataReader.splitAuthors("Ada Lovelace & Charles Babbage"), ["Ada Lovelace", "Charles Babbage"])
    }

    func testSplitAuthorsDropsJunk() {
        XCTAssertEqual(PDFMetadataReader.splitAuthors("admin"), [])
        XCTAssertEqual(PDFMetadataReader.splitAuthors("jsmith"), [])
        XCTAssertEqual(PDFMetadataReader.splitAuthors("Windows User"), [])
        XCTAssertEqual(PDFMetadataReader.splitAuthors("a@b.org"), [])
        XCTAssertEqual(PDFMetadataReader.splitAuthors(nil), [])
    }

    // MARK: Info record fills gaps

    func testDOIAndArXivFromInfoRecordWhenPageHasNone() {
        let info = PDFInfoRecord(subject: "J. Examples, doi:10.1234/info.sub.7", keywords: ["arXiv:2101.00001"])
        let result = PDFMetadataReader.parse(pageText: String(repeating: "text ", count: 30), runs: [], info: info, pageCount: 2)
        XCTAssertEqual(result.doi, "10.1234/info.sub.7")
        XCTAssertEqual(result.arxivID, "2101.00001")
        XCTAssertEqual(result.year, 2021)
    }

    func testPageDOIBeatsInfoDOI() {
        let info = PDFInfoRecord(subject: "doi:10.9999/from.info.1")
        let result = PDFMetadataReader.parse(pageText: "doi:10.1111/from.page.2", runs: [], info: info, pageCount: 1)
        XCTAssertEqual(result.doi, "10.1111/from.page.2")
    }

    func testNeedsOCRThreshold() {
        XCTAssertTrue(PDFMetadataReader.parse(pageText: "", runs: [], info: PDFInfoRecord(), pageCount: 4).needsOCR)
        XCTAssertTrue(PDFMetadataReader.parse(pageText: "  \n ", runs: [], info: PDFInfoRecord(), pageCount: 4).needsOCR)
        XCTAssertFalse(PDFMetadataReader.parse(pageText: "", runs: [], info: PDFInfoRecord(), pageCount: 4,
                                               visibleCharacters: 500).needsOCR,
                       "text on a later sampled page means it is not a scan")
    }

    // MARK: Real PDFs

    func testReadsTitleAndDOIFromARealPDF() throws {
        let url = try makePDF(lines: [
            ("Deep Residual Learning for Image Recognition", 20),
            ("Kaiming He, Xiangyu Zhang, Shaoqing Ren, Jian Sun", 11),
            ("Deeper neural networks are more difficult to train. We present a residual", 10),
            ("learning framework to ease the training of networks that are substantially", 10),
            ("deeper than those used previously. We explicitly reformulate the layers.", 10),
            ("https://doi.org/10.1109/CVPR.2016.90", 9)
        ], info: [kCGPDFContextAuthor: "Kaiming He; Xiangyu Zhang"])

        let result = PDFMetadataReader.read(url: url)

        XCTAssertNil(result.problem)
        XCTAssertEqual(result.pageCount, 1)
        XCTAssertFalse(result.needsOCR)
        XCTAssertEqual(result.doi, "10.1109/cvpr.2016.90")
        XCTAssertEqual(result.title, "Deep Residual Learning for Image Recognition")
        XCTAssertEqual(result.authors, ["Kaiming He", "Xiangyu Zhang"])
        XCTAssertTrue(result.hasUsefulResult)
    }

    func testBlankPDFIsFlaggedForOCR() throws {
        let url = try makePDF(lines: [])
        let result = PDFMetadataReader.read(url: url)

        XCTAssertNil(result.problem)
        XCTAssertEqual(result.pageCount, 1)
        XCTAssertTrue(result.needsOCR)
        XCTAssertFalse(result.hasUsefulResult)
    }

    func testPasswordProtectedPDF() throws {
        let url = try makePDF(lines: [("Secret", 12)], info: [
            kCGPDFContextUserPassword: "pw", kCGPDFContextOwnerPassword: "pw"
        ])
        XCTAssertEqual(PDFMetadataReader.read(url: url).problem, .passwordProtected)
    }

    func testFileThatIsNotAPDFAndMissingFile() throws {
        let text = folder.appendingPathComponent("notes.pdf")
        try "just text".write(to: text, atomically: true, encoding: .utf8)
        XCTAssertEqual(PDFMetadataReader.read(url: text).problem, .cannotOpen)

        let missing = folder.appendingPathComponent("missing.pdf")
        XCTAssertEqual(PDFMetadataReader.read(url: missing).problem, .cannotOpen)
    }

    // MARK: PDF drawing helper

    /// One A4-ish page. Each line is (text, font size), drawn top to bottom as real text.
    private func makePDF(lines: [(String, Double)], info: [CFString: Any] = [:]) throws -> URL {
        let url = folder.appendingPathComponent("\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)

        guard let context = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else {
            throw NSError(domain: "PDFMetadataReaderTests", code: 1)
        }
        context.beginPDFPage(nil)

        var y = 720.0
        for (text, size) in lines {
            let font = CTFontCreateWithName("Helvetica" as CFString, CGFloat(size), nil)
            let attributed = NSAttributedString(
                string: text,
                attributes: [NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font]
            )
            context.textPosition = CGPoint(x: 72, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            y -= size * 2
        }

        context.endPDFPage()
        context.closePDF()
        return url
    }
}
