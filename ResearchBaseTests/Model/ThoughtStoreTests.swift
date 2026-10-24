//
//  ThoughtStoreTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 20/10/26.
//


//
//  ThoughtStoreTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 17 · Feature: F-44
//

import XCTest
@testable import ResearchBase

@MainActor
final class ThoughtStoreTests: XCTestCase {

    func testCreateAllFiveKindsInOneTable() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let store = ThoughtStore(model: model)

        for kind in ThoughtKind.allCases {
            try store.create(NewThought(kind: kind, title: "A \(kind.rawValue)", body: "text"))
        }
        XCTAssertEqual(try ModelTestSupport.count(model, "thoughts"), 5)
        XCTAssertEqual(try store.countsByKind(), Dictionary(uniqueKeysWithValues: ThoughtKind.allCases.map { ($0, 1) }))

        let gap = try store.create(NewThought(kind: .gap, title: "  Drift never compared  ", evidence: "3 papers"))
        XCTAssertEqual(gap.title, "Drift never compared")
        XCTAssertEqual(gap.evidence, "3 papers")
        XCTAssertEqual(gap.status, .open)
    }

    func testBadInputIsRefused() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let store = ThoughtStore(model: model)

        XCTAssertThrowsError(try store.create(NewThought(title: "   ")))
        XCTAssertThrowsError(try store.create(NewThought(title: "x", priority: -1)))
        XCTAssertEqual(try ModelTestSupport.count(model, "thoughts"), 0)

        let t = try store.create(NewThought(title: "ok"))
        XCTAssertThrowsError(try store.update(id: t.id) { $0.title = "" })
        XCTAssertThrowsError(try store.update(id: t.id) { $0.createdAt = "x" })
        XCTAssertEqual(try store.fetch(id: t.id)?.title, "ok")
        XCTAssertThrowsError(try store.update(id: "missing") { $0.title = "y" })
    }

    func testChangingKindKeepsEveryField() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let store = ThoughtStore(model: model)

        let gap = try store.create(NewThought(kind: .gap, title: "G", evidence: "evidence text", question: "q?"))
        let idea = try store.update(id: gap.id) { $0.kind = .idea }

        XCTAssertEqual(idea.kind, .idea)
        XCTAssertEqual(idea.evidence, "evidence text")
        XCTAssertEqual(idea.question, "q?")
    }

    func testUpdateReportsOnlyChangedFields() throws {
        let sink = RecordingChangeSink()
        let model = try ModelTestSupport.makeModel(self, sink: sink)
        defer { model.library.close() }
        let store = ThoughtStore(model: model)

        let t = try store.create(NewThought(title: "T"))
        sink.clear()

        let updated = try store.update(id: t.id) { $0.status = .exploring; $0.priority = 2 }
        XCTAssertEqual(updated.status, .exploring)
        XCTAssertEqual(Set(sink.entries(type: "thought", action: .update).compactMap(\.field)), ["status", "priority"])

        sink.clear()
        _ = try store.update(id: t.id) { _ in }
        XCTAssertTrue(sink.entries.isEmpty)
    }

    func testListFiltersAndSorts() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let store = ThoughtStore(model: model)

        let low = try store.create(NewThought(kind: .idea, title: "Low", priority: 1))
        let high = try store.create(NewThought(kind: .idea, title: "High", priority: 5))
        let done = try store.create(NewThought(kind: .note, title: "Done", status: .done))

        XCTAssertEqual(Set(try store.list(kind: .idea).map(\.id)), [low.id, high.id])
        XCTAssertEqual(try store.list(status: .done).map(\.id), [done.id])
        XCTAssertEqual(try store.list(kind: .idea, sort: .priority).map(\.id), [high.id, low.id])
        XCTAssertEqual(try store.count(kind: .idea), 2)
        XCTAssertEqual(try store.count(status: .open), 2)
        XCTAssertEqual(try store.list(limit: 1, offset: 2).count, 1)
    }

    func testTrashHidesAndRestoreBringsBack() throws {
        let sink = RecordingChangeSink()
        let model = try ModelTestSupport.makeModel(self, sink: sink)
        defer { model.library.close() }
        let store = ThoughtStore(model: model)

        let t = try store.create(NewThought(title: "Gone soon"))
        try store.trash(id: t.id)

        XCTAssertNil(try store.fetch(id: t.id))
        XCTAssertNotNil(try store.fetch(id: t.id, includeDeleted: true)?.deletedAt)
        XCTAssertTrue(try store.list().isEmpty)
        XCTAssertEqual(try ModelTestSupport.count(model, "thoughts"), 1, "never hard-deleted")
        XCTAssertThrowsError(try store.trash(id: t.id), "already in the Trash")

        try store.restore(id: t.id)
        XCTAssertEqual(try store.list().map(\.id), [t.id])
        XCTAssertEqual(sink.entries(type: "thought", action: .delete).count, 1)
        XCTAssertEqual(sink.entries(type: "thought", action: .restore).count, 1)
    }

    func testLinksToPapersAndOtherThoughtsFromBothSides() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let store = ThoughtStore(model: model)

        let paper = try ModelTestSupport.item(model)
        let gap = try store.create(NewThought(kind: .gap, title: "Gap"))
        let idea = try store.create(NewThought(kind: .idea, title: "Idea"))

        try store.link(thoughtID: gap.id, to: LinkEnd(.item, paper.id), rel: .supports)
        try store.link(thoughtID: idea.id, to: LinkEnd(.item, paper.id))
        try store.link(thoughtID: idea.id, to: LinkEnd(.thought, gap.id), rel: .extends)

        XCTAssertEqual(Set(try store.thoughts(linkedTo: LinkEnd(.item, paper.id)).map(\.id)), [gap.id, idea.id])
        XCTAssertEqual(Set(try store.thoughts(linkedTo: LinkEnd(.thought, gap.id)).map(\.id)), [idea.id])

        try store.trash(id: gap.id)
        XCTAssertEqual(try store.thoughts(linkedTo: LinkEnd(.item, paper.id)).map(\.id), [idea.id], "trashed thoughts are not listed")

        XCTAssertThrowsError(try store.link(thoughtID: "missing", to: LinkEnd(.item, paper.id)))
    }
}