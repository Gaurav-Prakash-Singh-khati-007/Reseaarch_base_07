//
//  PDFPreviewSyncViewTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 22/10/26.
//


//
//  PDFPreviewSyncViewTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 42 (tests for PDFPreviewSyncView.swift)
//  Pure SyncTeX parsing and path / coordinate handling. Output samples follow the real
//  `synctex view` and `synctex edit` text format.
//

import XCTest
@testable import ResearchBase

final class PDFPreviewSyncViewTests: XCTestCase {

    private let viewOutput = """
    This is SyncTeX command line utility, version 1.5
    SyncTeX result begin
    Output:/tmp/Draft/.build/main.pdf
    Page:1
    x:133.768356
    y:134.764618
    h:133.768356
    v:134.764618
    W:343.711060
    H:9.962640
    before:
    offset:0
    middle:
    after:
    Page:2
    x:100
    y:200
    h:100
    v:200
    W:50
    H:10
    SyncTeX result end
    """

    private let editOutput = """
    This is SyncTeX command line utility, version 1.5
    SyncTeX result begin
    Output:main.pdf
    Input:/tmp/Draft/./sections/intro.tex
    Line:42
    Column:-1
    Offset:0
    Context:
    Input:/tmp/Draft/main.tex
    Line:7
    Column:3
    SyncTeX result end
    """

    func testParseViewReadsEveryPage() {
        let rects = SyncTeX.parseView(viewOutput)
        XCTAssertEqual(rects.count, 2)
        XCTAssertEqual(rects[0].page, 1)
        XCTAssertEqual(rects[0].x, 133.768356, accuracy: 1e-6)
        XCTAssertEqual(rects[0].width, 343.711060, accuracy: 1e-6)
        XCTAssertEqual(rects[0].height, 9.962640, accuracy: 1e-6)
        // The box runs from baseline - height down to the baseline.
        XCTAssertEqual(rects[0].y, 134.764618 - 9.962640, accuracy: 1e-6)
        XCTAssertEqual(rects[1].page, 2)
    }

    func testParseViewWithNoResult() {
        XCTAssertTrue(SyncTeX.parseView("").isEmpty)
        XCTAssertTrue(SyncTeX.parseView("SyncTeX result begin\nSyncTeX result end").isEmpty)
        XCTAssertTrue(SyncTeX.parseView("Page:x\nh:1\nv:2").isEmpty)
    }

    func testParseEditTakesTheFirstRecordAndMapsUnknownColumnToNil() {
        let source = SyncTeX.parseEdit(editOutput)
        XCTAssertEqual(source?.file, "/tmp/Draft/./sections/intro.tex")
        XCTAssertEqual(source?.line, 42)
        XCTAssertNil(source?.column)
    }

    func testParseEditKeepsAValidColumnAndRejectsGarbage() {
        XCTAssertEqual(SyncTeX.parseEdit("Input:a.tex\nLine:3\nColumn:5")?.column, 5)
        XCTAssertNil(SyncTeX.parseEdit(""))
        XCTAssertNil(SyncTeX.parseEdit("Input:a.tex\nLine:0"))
        XCTAssertNil(SyncTeX.parseEdit("Line:3"))
    }

    func testDraftRelativePath() {
        let folder = URL(fileURLWithPath: "/tmp/Draft", isDirectory: true)
        XCTAssertEqual(SyncTeX.draftRelativePath("/tmp/Draft/./sections/intro.tex", draftFolder: folder), "sections/intro.tex")
        XCTAssertEqual(SyncTeX.draftRelativePath("/tmp/Draft/main.tex", draftFolder: folder), "main.tex")
        XCTAssertEqual(SyncTeX.draftRelativePath("./main.tex", draftFolder: folder), "main.tex")
        XCTAssertEqual(SyncTeX.draftRelativePath("././a/b.tex", draftFolder: nil), "a/b.tex")
        XCTAssertEqual(SyncTeX.draftRelativePath("/elsewhere/x.sty", draftFolder: folder), "/elsewhere/x.sty")
        XCTAssertEqual(SyncTeX.draftRelativePath("/tmp/Draft2/x.tex", draftFolder: folder), "/tmp/Draft2/x.tex",
                       "a folder that only starts with the same letters is not inside the draft")
    }

    func testPDFKitRectFlipsTheVerticalAxis() {
        let rect = SyncTeXRect(page: 1, x: 100, y: 50, width: 200, height: 10)
        let box = SyncTeX.pdfKitRect(for: rect, pageHeight: 800)
        XCTAssertEqual(box, CGRect(x: 100, y: 740, width: 200, height: 10))
    }

    func testForwardRequestsAreDistinct() {
        XCTAssertNotEqual(PDFForwardRequest(file: "main.tex", line: 3), PDFForwardRequest(file: "main.tex", line: 3))
    }

    /// Runs the real tool when it is installed; skipped otherwise.
    func testRealSyncTeXRoundTripWhenInstalled() async throws {
        let install = LatexCompiler.locateInstallation()
        guard let latexmk = install.latexmk, let synctex = install.synctex else {
            throw XCTSkip("No TeX installation with synctex")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rbA42-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try "\\documentclass{article}\n\\begin{document}\nHello sync world.\n\\end{document}\n"
            .write(to: root.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)

        let built = await LatexCompiler.runCommand(
            executable: latexmk, arguments: ["-pdf", "-interaction=nonstopmode", "-synctex=1", "main.tex"],
            workingDirectory: root, timeout: 120)
        guard built.exitCode == 0 else { throw XCTSkip("latexmk could not build the sample") }

        let client = SyncTeXClient(executable: synctex, pdfURL: root.appendingPathComponent("main.pdf"), draftFolder: root)
        let rects = await client.forward(file: "main.tex", line: 3)
        let first = try XCTUnwrap(rects.first)
        XCTAssertEqual(first.page, 1)

        let back = await client.reverse(page: first.page, x: first.x + 2, y: first.y + first.height / 2)
        XCTAssertEqual(back?.file, "main.tex")
        XCTAssertEqual(back?.line, 3)
    }
}