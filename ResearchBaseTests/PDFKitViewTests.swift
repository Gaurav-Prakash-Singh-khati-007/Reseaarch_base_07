//
//  PDFKitViewTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 23/10/26.
//


//
//  PDFKitViewTests.swift
//  Owner: Agent 67 (tests for PDFKitView.swift: F-26 highlight helpers)
//

import XCTest
import PDFKit
@testable import ResearchBase

@MainActor
final class PDFKitViewTests: XCTestCase {

    private func makeDocument(pages: Int = 3) -> PDFDocument {
        let document = PDFDocument()
        for index in 0..<pages {
            document.insert(PDFPage(), at: index)
        }
        return document
    }

    private func tagged(_ document: PDFDocument) -> [PDFAnnotation] {
        (0..<document.pageCount).flatMap { index in
            (document.page(at: index)?.annotations ?? [])
                .filter { $0.userName?.hasPrefix(PDFHighlightDrawing.tagPrefix) == true }
        }
    }

    private let box = CGRect(x: 72, y: 600, width: 200, height: 12)

    // MARK: Drawing

    func testApplyDrawsOneAnnotationPerRectOnTheRightPage() {
        let document = makeDocument()
        let highlight = PDFStoredHighlight(
            id: "a1", page: 2, color: "green",
            rects: [box, box.offsetBy(dx: 0, dy: -14)]
        )

        PDFHighlightDrawing.apply([highlight], to: document)

        XCTAssertEqual(document.page(at: 0)?.annotations.count, 0)
        XCTAssertEqual(document.page(at: 1)?.annotations.count, 2)
        XCTAssertEqual(tagged(document).count, 2)
    }

    func testApplyReplacesInsteadOfStacking() {
        let document = makeDocument()
        let one = PDFStoredHighlight(id: "a1", page: 1, color: "yellow", rects: [box])
        let two = PDFStoredHighlight(id: "a2", page: 3, color: "pink", rects: [box])

        PDFHighlightDrawing.apply([one], to: document)
        PDFHighlightDrawing.apply([one, two], to: document)
        XCTAssertEqual(tagged(document).count, 2)

        PDFHighlightDrawing.apply([two], to: document)
        XCTAssertEqual(tagged(document).count, 1)
        XCTAssertEqual(document.page(at: 0)?.annotations.count, 0)

        PDFHighlightDrawing.apply([], to: document)
        XCTAssertTrue(tagged(document).isEmpty)
    }

    func testRemoveAllLeavesOtherAnnotationsAlone() {
        let document = makeDocument(pages: 1)
        let foreign = PDFAnnotation(bounds: box, forType: .highlight, withProperties: nil)
        foreign.userName = "someone-else"
        document.page(at: 0)?.addAnnotation(foreign)

        PDFHighlightDrawing.apply(
            [PDFStoredHighlight(id: "a1", page: 1, color: "blue", rects: [box])],
            to: document
        )
        PDFHighlightDrawing.removeAll(from: document)

        XCTAssertEqual(document.page(at: 0)?.annotations.count, 1)
    }

    func testBadPageOrEmptyRectIsIgnored() {
        let document = makeDocument(pages: 1)

        PDFHighlightDrawing.apply([
            PDFStoredHighlight(id: "x", page: 9, color: "yellow", rects: [box]),
            PDFStoredHighlight(id: "y", page: 0, color: "yellow", rects: [box]),
            PDFStoredHighlight(id: "z", page: 1, color: "yellow", rects: [.zero])
        ], to: document)

        XCTAssertTrue(tagged(document).isEmpty)
    }

    func testViewOnlyRedrawsWhenTheListChanges() {
        let view = ResearchPDFView()
        view.document = makeDocument(pages: 2)

        let one = PDFStoredHighlight(id: "a1", page: 1, color: "yellow", rects: [box])
        view.applyStoredHighlights([one])
        view.applyStoredHighlights([one])
        XCTAssertEqual(tagged(view.document!).count, 1)

        view.applyStoredHighlights([])
        XCTAssertTrue(tagged(view.document!).isEmpty)
    }

    // MARK: Export never touches the source

    func testExportMakesACopyAndLeavesTheSourceUntouched() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("rb67-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let source = folder.appendingPathComponent("paper.pdf")
        XCTAssertTrue(makeDocument().write(to: source))
        let before = try Data(contentsOf: source)

        let copy = folder.appendingPathComponent("paper-annotated.pdf")
        let ok = PDFHighlightExport.exportMarkedUp(
            source: source,
            highlights: [PDFStoredHighlight(id: "a1", page: 1, color: "green", rects: [box])],
            to: copy
        )

        XCTAssertTrue(ok)
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertEqual(PDFDocument(url: copy)?.page(at: 0)?.annotations.count, 1)
        XCTAssertEqual(PDFDocument(url: source)?.page(at: 0)?.annotations.count, 0)
    }

    func testExportRefusesToOverwriteTheSource() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("rb67-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: source) }
        XCTAssertTrue(makeDocument(pages: 1).write(to: source))
        let before = try Data(contentsOf: source)

        XCTAssertFalse(PDFHighlightExport.exportMarkedUp(source: source, highlights: [], to: source))
        XCTAssertEqual(try Data(contentsOf: source), before)
    }

    // MARK: Palette and library mapping

    func testPaletteNamesMatchWhatTheLibraryStores() {
        XCTAssertEqual(PDFHighlightPalette.names, ["yellow", "green", "blue", "pink"])
        XCTAssertEqual(PDFHighlightPalette.normalized(" Pink "), "pink")
        XCTAssertEqual(PDFHighlightPalette.normalized("purple"), "yellow")
    }

    func testOnlyHighlightsWithBoxesMapToDrawableHighlights() {
        func annotation(_ kind: AnnotationKind, rects: [AnnotationRect]) -> Annotation {
            Annotation(
                id: "id-\(kind.rawValue)", attachmentID: "att", kind: kind, color: "blue",
                page: 3, rects: rects, quote: "q", comment: "", createdAt: "", updatedAt: "", deletedAt: nil
            )
        }
        let rect = AnnotationRect(x: 72, y: 600, width: 200, height: 12)

        let made = PDFStoredHighlight(annotation(.highlight, rects: [rect]))
        XCTAssertEqual(made?.page, 3)
        XCTAssertEqual(made?.rects, [CGRect(x: 72, y: 600, width: 200, height: 12)])

        XCTAssertNil(PDFStoredHighlight(annotation(.note, rects: [])))
        XCTAssertNil(PDFStoredHighlight(annotation(.highlight, rects: [])))
        XCTAssertNil(PDFStoredHighlight(annotation(.area, rects: [rect])))
    }
}