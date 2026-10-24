//
//  PaperReaderViewTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 23/10/26.
//


//
//  PaperReaderViewTests.swift
//  Owner: Agent 66 (tests for PaperReaderView.swift: RBA66Logic)
//

import XCTest
import PDFKit
@testable import ResearchBase

@MainActor
final class PaperReaderViewTests: XCTestCase {

    // MARK: Outline

    private func makeDocument(pages: Int) -> PDFDocument {
        let document = PDFDocument()
        for index in 0..<pages {
            document.insert(PDFPage(), at: index)
        }
        return document
    }

    private func node(_ title: String, page: Int, in document: PDFDocument) -> PDFOutline {
        let outline = PDFOutline()
        outline.label = title
        outline.destination = PDFDestination(page: document.page(at: page)!, at: .zero)
        return outline
    }

    func testFlattenOutlineKeepsOrderPagesAndDepth() {
        let document = makeDocument(pages: 6)
        let root = PDFOutline()

        let intro = node("Introduction", page: 0, in: document)
        let method = node("Method", page: 2, in: document)
        let detail = node("The algorithm", page: 3, in: document)
        root.insertChild(intro, at: 0)
        root.insertChild(method, at: 1)
        method.insertChild(detail, at: 0)
        document.outlineRoot = root

        let entries = RBA66Logic.flattenOutline(root: document.outlineRoot, document: document)

        XCTAssertEqual(entries.map(\.title), ["Introduction", "Method", "The algorithm"])
        XCTAssertEqual(entries.map(\.page), [1, 3, 4])
        XCTAssertEqual(entries.map(\.depth), [0, 0, 1])
    }

    func testNoOutlineGivesEmptyList() {
        let document = makeDocument(pages: 2)
        XCTAssertTrue(RBA66Logic.flattenOutline(root: nil, document: document).isEmpty)
    }

    func testCurrentEntryIsTheLastOneAtOrBeforeThePage() {
        let entries = [
            RBA66OutlineEntry(id: 0, title: "A", page: 1, depth: 0),
            RBA66OutlineEntry(id: 1, title: "B", page: 4, depth: 0),
            RBA66OutlineEntry(id: 2, title: "B.1", page: 6, depth: 1)
        ]
        XCTAssertEqual(RBA66Logic.currentEntryID(entries, page: 1), 0)
        XCTAssertEqual(RBA66Logic.currentEntryID(entries, page: 5), 1)
        XCTAssertEqual(RBA66Logic.currentEntryID(entries, page: 9), 2)
        XCTAssertNil(RBA66Logic.currentEntryID([], page: 3))
    }

    // MARK: Resume offer

    func testResumeOfferOnlyForARealLaterPage() {
        XCTAssertEqual(RBA66Logic.resumeOffer(saved: 4, total: 12), 4)
        XCTAssertNil(RBA66Logic.resumeOffer(saved: 1, total: 12))
        XCTAssertNil(RBA66Logic.resumeOffer(saved: 40, total: 12))
        XCTAssertNil(RBA66Logic.resumeOffer(saved: 4, total: 0))
        XCTAssertNil(RBA66Logic.resumeOffer(saved: 2, total: 1))
    }

    func testReaderPositionRoundTrip() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rb66-\(UUID().uuidString).pdf")
        defer {
            UserDefaults.standard.removeObject(
                forKey: "rb.lastReadPage." + url.standardizedFileURL.path
            )
        }

        XCTAssertEqual(ReaderPositionStore.page(for: url), 1)
        ReaderPositionStore.save(page: 5, for: url)
        XCTAssertEqual(ReaderPositionStore.page(for: url), 5)
        ReaderPositionStore.save(page: 1, for: url)
        XCTAssertEqual(ReaderPositionStore.page(for: url), 1)
    }

    // MARK: Colours

    func testColourNamesFallBackToYellow() {
        XCTAssertEqual(RBA66Logic.normalizedColorName(" Pink "), "pink")
        XCTAssertEqual(RBA66Logic.normalizedColorName("green"), "green")
        XCTAssertEqual(RBA66Logic.normalizedColorName("purple"), "yellow")
        XCTAssertEqual(RBA66Logic.normalizedColorName(""), "yellow")
    }

    // MARK: Stored highlights (F-26)

    func testLoadAnnotationsIsEmptyWhenNotLinked() {
        XCTAssertTrue(RBA66Logic.loadAnnotations(store: nil, attachmentID: nil).isEmpty)
        XCTAssertTrue(RBA66Logic.loadAnnotations(store: nil, attachmentID: "x").isEmpty)
    }

    func testLoadAnnotationsReadsFromTheLibraryAndHidesTrashed() throws {
        let model = try ModelTestSupport.makeModel(self, sink: nil)
        defer { model.library.close() }

        let item = try ModelTestSupport.item(model)
        let file = try ModelTestSupport.makeFile(self, name: "paper.pdf", content: "pdf bytes \(UUID())")
        let attachment = try model.attachments.add(fileAt: file, to: item.id)
        let store = AnnotationStore(model: model)

        let box = [AnnotationRect(x: 72, y: 600, width: 200, height: 12)]
        let keep = try store.create(NewAnnotation(
            attachmentID: attachment.id, color: "green", page: 4, rects: box, quote: "kept"))
        let drop = try store.create(NewAnnotation(
            attachmentID: attachment.id, page: 2, rects: box, quote: "dropped"))

        XCTAssertEqual(
            RBA66Logic.loadAnnotations(store: store, attachmentID: attachment.id).map(\.quote),
            ["dropped", "kept"]
        )

        try store.trash(id: drop.id)

        let remaining = RBA66Logic.loadAnnotations(store: store, attachmentID: attachment.id)
        XCTAssertEqual(remaining.map(\.id), [keep.id])
    }
}