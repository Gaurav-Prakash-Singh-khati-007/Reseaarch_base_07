//
//  ResearchIdeasViewTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 23/10/26.
//


//
//  ResearchIdeasViewTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 72 · Features: F-44, F-45
//

import XCTest
@testable import ResearchBase

@MainActor
final class ResearchIdeasViewTests: XCTestCase {

    func testCreateIndexesAndSearchFindsIt() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let thought = try RBA72ThoughtsLogic.create(model: model, kind: .idea, title: "Cluster clients by data drift")
        _ = try RBA72ThoughtsLogic.create(model: model, kind: .note, title: "Unrelated reading note")

        let found = try RBA72ThoughtsLogic.load(model: model, kind: nil, status: nil, byPriority: false, query: "drift")
        XCTAssertEqual(found.map { $0.id }, [thought.id])
    }

    func testKindAndStatusFilters() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        _ = try RBA72ThoughtsLogic.create(model: model, kind: .gap, title: "Gap A")
        let idea = try RBA72ThoughtsLogic.create(model: model, kind: .idea, title: "Idea A")
        var draft = RBA72ThoughtDraft(idea)
        draft.status = .exploring
        try RBA72ThoughtsLogic.save(model: model, id: idea.id, draft: draft)

        let gaps = try RBA72ThoughtsLogic.load(model: model, kind: .gap, status: nil, byPriority: false, query: "")
        XCTAssertEqual(gaps.map { $0.title }, ["Gap A"])

        let exploring = try RBA72ThoughtsLogic.load(model: model, kind: nil, status: .exploring, byPriority: false, query: "")
        XCTAssertEqual(exploring.map { $0.title }, ["Idea A"])

        let counts = RBA72ThoughtsLogic.counts(model: model)
        XCTAssertEqual(counts[.gap], 1)
        XCTAssertEqual(counts[.idea], 1)
    }

    func testChangingKindKeepsEvidenceAndQuestion() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let gap = try RBA72ThoughtsLogic.create(model: model, kind: .gap, title: "Missing baseline")
        var draft = RBA72ThoughtDraft(gap)
        draft.evidence = "No paper compares against X"
        draft.question = "Does X hold under drift?"
        try RBA72ThoughtsLogic.save(model: model, id: gap.id, draft: draft)

        draft.kind = .problem
        let saved = try RBA72ThoughtsLogic.save(model: model, id: gap.id, draft: draft)

        XCTAssertEqual(saved.kind, .problem)
        XCTAssertEqual(saved.evidence, "No paper compares against X")
        XCTAssertEqual(saved.question, "Does X hold under drift?")
    }

    func testPriorityOrdering() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let low = try RBA72ThoughtsLogic.create(model: model, kind: .note, title: "Low")
        let high = try RBA72ThoughtsLogic.create(model: model, kind: .note, title: "High")
        var draft = RBA72ThoughtDraft(high)
        draft.priority = 4
        try RBA72ThoughtsLogic.save(model: model, id: high.id, draft: draft)
        _ = low

        let sorted = try RBA72ThoughtsLogic.load(model: model, kind: nil, status: nil, byPriority: true, query: "")
        XCTAssertEqual(sorted.first?.title, "High")
    }

    func testTrashHidesAndRestoreBringsBack() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let thought = try RBA72ThoughtsLogic.create(model: model, kind: .note, title: "Temporary")
        try RBA72ThoughtsLogic.trash(model: model, id: thought.id)
        XCTAssertTrue(try RBA72ThoughtsLogic.load(model: model, kind: nil, status: nil, byPriority: false, query: "").isEmpty)
        XCTAssertTrue(try RBA72ThoughtsLogic.load(model: model, kind: nil, status: nil, byPriority: false, query: "temporary").isEmpty)

        try RBA72ThoughtsLogic.restore(model: model, id: thought.id)
        XCTAssertEqual(try RBA72ThoughtsLogic.load(model: model, kind: nil, status: nil, byPriority: false, query: "").count, 1)
    }

    func testLinkPaperShowsInWhereUsed() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let paper = try ModelTestSupport.item(model, title: "FedAvg")
        let thought = try RBA72ThoughtsLogic.create(model: model, kind: .note, title: "Notes on FedAvg")
        try RBA72ThoughtsLogic.linkPaper(model: model, thoughtID: thought.id, itemID: paper.id)

        let result = try WhereUsedLogic.load(for: LinkEnd(.item, paper.id), model: model)
        XCTAssertEqual(result.totalCount, 1)
        XCTAssertEqual(RBA72ThoughtsLogic.paperChoices(model: model, query: "").map { $0.id }, [paper.id])
    }
}