//
//  DraftCommentStoreTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 20/10/26.
//


//
//  DraftCommentStoreTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 22 · F-37: comments and TODOs in a draft.
//

import XCTest
@testable import ResearchBase

@MainActor
final class DraftCommentStoreTests: XCTestCase {

    private func make(sink: ChangeSink? = nil) throws -> (LibraryModel, DraftCommentStore, String) {
        let model = try ModelTestSupport.makeModel(self, sink: sink)
        let draft = try ModelTestSupport.insertDraft(model)
        return (model, DraftCommentStore(model: model), draft)
    }

    func testAddAndReadBack() throws {
        let (model, store, draft) = try make()
        defer { model.library.close() }

        let c = try store.add(draftID: draft, file: "main.tex", line: 12, anchorText: "We show", body: "  Cite a source  ")
        XCTAssertEqual(c.body, "Cite a source")
        XCTAssertEqual(c.kind, .comment)
        XCTAssertFalse(c.resolved)
        XCTAssertEqual(try store.comment(id: c.id), c)
    }

    func testRefusesBadInput() throws {
        let (model, store, draft) = try make()
        defer { model.library.close() }

        XCTAssertThrowsError(try store.add(draftID: draft, file: "main.tex", line: 1, body: "   "))
        XCTAssertThrowsError(try store.add(draftID: draft, file: "main.tex", line: 0, body: "x"))
        XCTAssertThrowsError(try store.add(draftID: draft, file: "../x.tex", line: 1, body: "x"))
        XCTAssertThrowsError(try store.add(draftID: draft, file: "/abs.tex", line: 1, body: "x"))
        XCTAssertThrowsError(try store.add(draftID: "nope", file: "main.tex", line: 1, body: "x")) {
            XCTAssertEqual($0 as? ModelError, .notFound(kind: "draft", id: "nope"))
        }
        XCTAssertEqual(try ModelTestSupport.count(model, "draft_comments"), 0)
    }

    func testOrderingFiltersAndUnresolvedList() throws {
        let (model, store, draft) = try make()
        defer { model.library.close() }

        let b = try store.add(draftID: draft, file: "main.tex", line: 30, body: "b")
        let a = try store.add(draftID: draft, file: "main.tex", line: 5, kind: .todo, body: "a")
        let c = try store.add(draftID: draft, file: "chapters/one.tex", line: 1, body: "c")
        try store.setResolved(id: b.id)

        XCTAssertEqual(try store.comments(draftID: draft).map(\.id), [c.id, a.id, b.id])
        XCTAssertEqual(try store.comments(draftID: draft, file: "main.tex").map(\.id), [a.id, b.id])
        XCTAssertEqual(try store.comments(draftID: draft, kind: .todo).map(\.id), [a.id])
        XCTAssertEqual(try store.unresolved(draftID: draft).map(\.id), [c.id, a.id])
        XCTAssertEqual(try store.counts(draftID: draft), DraftCommentCounts(openComments: 1, openTodos: 1, resolved: 1))
    }

    func testEditResolveReopenMove() throws {
        let sink = RecordingChangeSink()
        let (model, store, draft) = try make(sink: sink)
        defer { model.library.close() }

        let c = try store.add(draftID: draft, file: "main.tex", line: 3, body: "old")
        sink.clear()

        XCTAssertEqual(try store.edit(id: c.id, body: "new").body, "new")
        XCTAssertTrue(try store.setResolved(id: c.id).resolved)
        XCTAssertFalse(try store.setResolved(id: c.id, false).resolved)
        XCTAssertEqual(try store.move(id: c.id, toLine: 9).line, 9)
        XCTAssertEqual(sink.entries(type: "draft_comment", action: .update).map(\.field), ["body", "resolved", "resolved", "line"])

        sink.clear()
        try store.edit(id: c.id, body: "new")            // no change, nothing reported
        XCTAssertTrue(sink.entries.isEmpty)

        XCTAssertThrowsError(try store.edit(id: c.id, body: " "))
        XCTAssertThrowsError(try store.edit(id: "missing", body: "x"))
    }

    func testShiftLinesKeepsCommentsOnTheirText() throws {
        let (model, store, draft) = try make()
        defer { model.library.close() }

        let above = try store.add(draftID: draft, file: "main.tex", line: 2, body: "above")
        let below = try store.add(draftID: draft, file: "main.tex", line: 10, body: "below")
        let other = try store.add(draftID: draft, file: "refs.bib", line: 10, body: "other file")

        XCTAssertEqual(try store.shiftLines(draftID: draft, file: "main.tex", fromLine: 5, by: 3), 1)
        XCTAssertEqual(try store.comment(id: above.id)?.line, 2)
        XCTAssertEqual(try store.comment(id: below.id)?.line, 13)
        XCTAssertEqual(try store.comment(id: other.id)?.line, 10)

        try store.shiftLines(draftID: draft, file: "main.tex", fromLine: 1, by: -100)
        XCTAssertEqual(try store.comment(id: above.id)?.line, 1)    // never above line 1
    }

    func testRenameFileMovesItsComments() throws {
        let (model, store, draft) = try make()
        defer { model.library.close() }

        let c = try store.add(draftID: draft, file: "intro.tex", line: 1, body: "x")
        XCTAssertEqual(try store.renameFile(draftID: draft, from: "intro.tex", to: "chapters/intro.tex"), 1)
        XCTAssertEqual(try store.comment(id: c.id)?.file, "chapters/intro.tex")
    }

    func testRemoveReportsOldRowAndClearResolved() throws {
        let sink = RecordingChangeSink()
        let (model, store, draft) = try make(sink: sink)
        defer { model.library.close() }

        let a = try store.add(draftID: draft, file: "main.tex", line: 1, body: "a")
        let b = try store.add(draftID: draft, file: "main.tex", line: 2, body: "b")
        try store.setResolved(id: b.id)
        sink.clear()

        XCTAssertEqual(try store.removeResolved(draftID: draft), 1)
        XCTAssertNil(try store.comment(id: b.id))
        XCTAssertNotNil(try store.comment(id: a.id))
        XCTAssertNotNil(sink.entries(type: "draft_comment", action: .delete).first?.oldValue)

        try store.remove(id: a.id)
        XCTAssertThrowsError(try store.remove(id: a.id))
    }

    func testCommentsGoWithTheirDraft() throws {
        let (model, store, draft) = try make()
        defer { model.library.close() }

        try store.add(draftID: draft, file: "main.tex", line: 1, body: "x")
        try model.database.run("DELETE FROM drafts WHERE id = ?", [.text(draft)])
        XCTAssertEqual(try ModelTestSupport.count(model, "draft_comments"), 0)
    }

    func testFailedWriteChangesNothing() throws {
        let (model, store, draft) = try make(sink: FailingChangeSink(failOnCall: 0))
        defer { model.library.close() }

        XCTAssertThrowsError(try store.add(draftID: draft, file: "main.tex", line: 1, body: "x"))
        XCTAssertEqual(try ModelTestSupport.count(model, "draft_comments"), 0)
    }

    func testScanTodoMarkers() {
        let text = """
        \\section{Intro}
        % TODO: add related work
        Text with 50\\% growth \\todo{check number}
        %TODO
        \\todo[inline]{fix figure}
        % just a comment
        """
        let found = DraftCommentStore.scanTodoMarkers(in: text, file: "main.tex")
        XCTAssertEqual(found.map(\.line), [2, 3, 4, 5])
        XCTAssertEqual(found.map(\.text), ["add related work", "check number", "TODO", "fix figure"])
    }

    func testAddMissingTodoMarkersIsRepeatable() throws {
        let (model, store, draft) = try make()
        defer { model.library.close() }

        let text = "a\n% TODO: one\nb\n\\todo{two}\n"
        XCTAssertEqual(try store.addMissingTodoMarkers(draftID: draft, file: "main.tex", text: text).count, 2)
        XCTAssertEqual(try store.addMissingTodoMarkers(draftID: draft, file: "main.tex", text: text).count, 0)
        XCTAssertEqual(try store.comments(draftID: draft, kind: .todo).map(\.body), ["one", "two"])
    }
}