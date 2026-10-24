//
//  AnnotationStoreTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 20/10/26.
//


//
//  AnnotationStoreTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 15 · Feature: F-26
//

import XCTest
@testable import ResearchBase

@MainActor
final class AnnotationStoreTests: XCTestCase {

    private func makeFixture(sink: ChangeSink? = nil) throws -> (LibraryModel, AnnotationStore, ModelItem, Attachment) {
        let model = try ModelTestSupport.makeModel(self, sink: sink)
        let item = try ModelTestSupport.item(model)
        let file = try ModelTestSupport.makeFile(self, name: "paper.pdf", content: "pdf bytes \(UUID())")
        let attachment = try model.attachments.add(fileAt: file, to: item.id)
        return (model, AnnotationStore(model: model), item, attachment)
    }

    private let box = [AnnotationRect(x: 72, y: 600, width: 200, height: 12)]

    func testCreateAndReadBackWithRects() throws {
        let (model, store, _, att) = try makeFixture()
        defer { model.library.close() }

        let made = try store.create(NewAnnotation(
            attachmentID: att.id, kind: .highlight, color: "green", page: 4,
            rects: box + [AnnotationRect(x: 72, y: 588, width: 90.5, height: 12)],
            quote: "Accuracy dropped to 85%", comment: "compare with Table 2"))

        let read = try XCTUnwrap(try store.fetch(id: made.id))
        XCTAssertEqual(read, made)
        XCTAssertEqual(read.rects.count, 2)
        XCTAssertEqual(read.rects[1].width, 90.5)
        XCTAssertEqual(read.color, "green")
    }

    func testListsAreInReadingOrderAndFilterable() throws {
        let (model, store, item, att) = try makeFixture()
        defer { model.library.close() }

        try store.create(NewAnnotation(attachmentID: att.id, page: 9, rects: box, quote: "late"))
        try store.create(NewAnnotation(attachmentID: att.id, page: 2, rects: box, quote: "early"))
        try store.create(NewAnnotation(attachmentID: att.id, kind: .note, page: 2, comment: "page note"))

        XCTAssertEqual(try store.list(attachmentID: att.id).map(\.page), [2, 2, 9])
        XCTAssertEqual(try store.list(attachmentID: att.id, page: 2).count, 2)
        XCTAssertEqual(try store.list(attachmentID: att.id, kind: .note).map(\.comment), ["page note"])
        XCTAssertEqual(try store.list(itemID: item.id).count, 3)
        XCTAssertEqual(try store.count(itemID: item.id), 3)
        XCTAssertEqual(try store.count(attachmentID: att.id), 3)
    }

    func testBadInputIsRefusedAndNothingIsSaved() throws {
        let (model, store, _, att) = try makeFixture()
        defer { model.library.close() }

        XCTAssertThrowsError(try store.create(NewAnnotation(attachmentID: att.id, page: 0, rects: box)))
        XCTAssertThrowsError(try store.create(NewAnnotation(attachmentID: att.id, page: 1, rects: [])), "highlight needs a box")
        XCTAssertThrowsError(try store.create(NewAnnotation(attachmentID: att.id, color: " ", page: 1, rects: box)))
        XCTAssertThrowsError(try store.create(NewAnnotation(attachmentID: att.id, page: 1,
            rects: [AnnotationRect(x: .nan, y: 0, width: 1, height: 1)])))
        XCTAssertThrowsError(try store.create(NewAnnotation(attachmentID: "missing", page: 1, rects: box)))
        XCTAssertEqual(try ModelTestSupport.count(model, "annotations"), 0)
    }

    func testUpdateReportsEachChangedField() throws {
        let sink = RecordingChangeSink()
        let (model, store, _, att) = try makeFixture(sink: sink)
        defer { model.library.close() }

        let made = try store.create(NewAnnotation(attachmentID: att.id, page: 1, rects: box, quote: "q"))
        sink.clear()

        let updated = try store.update(id: made.id) { $0.color = "pink"; $0.comment = "check this" }
        XCTAssertEqual(updated.color, "pink")
        XCTAssertEqual(updated.comment, "check this")
        XCTAssertEqual(Set(sink.entries(type: "annotation", action: .update).compactMap(\.field)), ["color", "comment"])

        sink.clear()
        _ = try store.update(id: made.id) { _ in }
        XCTAssertTrue(sink.entries.isEmpty, "no change, no report")

        XCTAssertThrowsError(try store.update(id: made.id) { $0.kind = .area })
        XCTAssertThrowsError(try store.update(id: made.id) { $0.page = 0 })
        XCTAssertEqual(try store.fetch(id: made.id)?.page, 1)
    }

    func testTrashHidesAndRestoreBringsBack() throws {
        let sink = RecordingChangeSink()
        let (model, store, _, att) = try makeFixture(sink: sink)
        defer { model.library.close() }

        let made = try store.create(NewAnnotation(attachmentID: att.id, page: 1, rects: box))
        try store.trash(id: made.id)

        XCTAssertNil(try store.fetch(id: made.id))
        XCTAssertNotNil(try store.fetch(id: made.id, includeDeleted: true)?.deletedAt)
        XCTAssertEqual(try store.count(attachmentID: att.id), 0)
        XCTAssertEqual(try ModelTestSupport.count(model, "annotations"), 1, "never hard-deleted")

        try store.restore(id: made.id)
        XCTAssertEqual(try store.count(attachmentID: att.id), 1)
        XCTAssertEqual(sink.entries(type: "annotation", action: .delete).count, 1)
        XCTAssertEqual(sink.entries(type: "annotation", action: .restore).count, 1)
    }

    func testTrashedFileHidesItsAnnotations() throws {
        let (model, store, item, att) = try makeFixture()
        defer { model.library.close() }

        try store.create(NewAnnotation(attachmentID: att.id, page: 1, rects: box))
        try model.database.run("UPDATE attachments SET deleted_at = ? WHERE id = ?", [.text(Library.nowISO()), .text(att.id)])

        XCTAssertEqual(try store.list(itemID: item.id).count, 0)
        XCTAssertThrowsError(try store.create(NewAnnotation(attachmentID: att.id, page: 2, rects: box)))
    }

    func testMarkdownForSendToNote() throws {
        let (model, store, _, att) = try makeFixture()
        defer { model.library.close() }

        try store.create(NewAnnotation(attachmentID: att.id, page: 3, rects: box, quote: "line one\nline two", comment: "why?"))
        try store.create(NewAnnotation(attachmentID: att.id, kind: .area, page: 1, rects: box, comment: "Figure 2"))

        XCTAssertEqual(try store.markdown(attachmentID: att.id),
                       "- p. 1 (area): Figure 2\n- p. 3: “line one line two”\n  - why?")
    }

    func testRectJSONRoundTripsAndToleratesJunk() {
        let rects = [AnnotationRect(x: 1.5, y: 2, width: 3, height: 4)]
        XCTAssertEqual(AnnotationStore.rects(from: AnnotationStore.encode(rects: rects)), rects)
        XCTAssertEqual(AnnotationStore.encode(rects: []), "[]")
        XCTAssertTrue(AnnotationStore.rects(from: "not json").isEmpty)
        XCTAssertTrue(AnnotationStore.rects(from: "[[1,2,3]]").isEmpty)
    }
}