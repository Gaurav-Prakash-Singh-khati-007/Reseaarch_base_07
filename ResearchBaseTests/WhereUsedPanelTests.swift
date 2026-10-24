//
//  WhereUsedPanelTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 22/10/26.
//


//
//  WhereUsedPanelTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 45 · Features: F-45
//
//  Tests the logic behind WhereUsedPanel (WhereUsedLogic): grouping, titles,
//  link direction, Trash handling and removing links. The SwiftUI panel
//  itself is not tested.
//

import XCTest
@testable import ResearchBase

@MainActor
final class WhereUsedPanelTests: XCTestCase {

    // MARK: Helpers

    private func makeModel() throws -> LibraryModel {
        try ModelTestSupport.makeModel(self)
    }

    private func insertTask(_ model: LibraryModel, title: String = "Rerun FedProx") throws -> String {
        let id = UUID().uuidString
        let now = Library.nowISO()
        try model.database.run(
            "INSERT INTO tasks (id, title, created_at, updated_at) VALUES (?, ?, ?, ?)",
            [.text(id), .text(title), .text(now), .text(now)]
        )
        return id
    }

    private func paperEnd(_ item: ModelItem) -> LinkEnd { LinkEnd(.item, item.id) }

    // MARK: Nothing linked

    func testARecordWithNoLinksHasNoGroups() throws {
        let model = try makeModel()
        defer { model.library.close() }
        let paper = try ModelTestSupport.item(model)

        let result = try WhereUsedLogic.load(for: paperEnd(paper), model: model)

        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertEqual(result.hiddenCount, 0)
        XCTAssertEqual(result.totalCount, 0)
    }

    // MARK: Grouping and titles

    func testGroupsFollowTheFixedOrderAndShowRealTitles() throws {
        let model = try makeModel()
        defer { model.library.close() }
        let paper = try ModelTestSupport.item(model)
        let other = try ModelTestSupport.item(model, title: "SCAFFOLD", author: "Karimireddy", given: "Sai")

        let draftID = try ModelTestSupport.insertDraft(model)
        let projectID = try ModelTestSupport.insertProject(model)
        let taskID = try insertTask(model)
        let experimentID = try ModelTestSupport.insertExperiment(model)
        let thought = try ThoughtStore(model: model).create(NewThought(kind: .note, title: "Drift note"))

        // Added in a different order than the groups are shown.
        try model.links.add(from: LinkEnd(.thought, thought.id), to: paperEnd(paper), rel: .related)
        try model.links.add(from: paperEnd(paper), to: paperEnd(other), rel: .extends)
        try model.links.add(from: LinkEnd(.experiment, experimentID), to: paperEnd(paper), rel: .derivedFrom)
        try model.links.add(from: LinkEnd(.task, taskID), to: paperEnd(paper), rel: .uses)
        try model.links.add(from: LinkEnd(.project, projectID), to: paperEnd(paper), rel: .uses)
        try model.links.add(from: LinkEnd(.draft, draftID), to: paperEnd(paper), rel: .cites)

        let result = try WhereUsedLogic.load(for: paperEnd(paper), model: model)

        XCTAssertEqual(result.groups.map(\.kind), [.drafts, .projects, .tasks, .experiments, .papers, .notes])
        XCTAssertEqual(result.totalCount, 6)

        func title(_ kind: WhereUsedGroupKind) -> String? {
            result.groups.first { $0.kind == kind }?.entries.first?.title
        }
        XCTAssertEqual(title(.drafts), "My paper")
        XCTAssertEqual(title(.projects), "Thesis")
        XCTAssertEqual(title(.tasks), "Rerun FedProx")
        XCTAssertEqual(title(.experiments), "Run it")
        XCTAssertEqual(title(.papers), "SCAFFOLD")
        XCTAssertEqual(title(.notes), "Drift note")
    }

    func testEveryKindOfRecordHasItsOwnGroupWithATitleAndSymbol() {
        let kinds = LinkEntity.allCases.map { WhereUsedGroupKind($0) }

        XCTAssertEqual(Set(kinds).count, LinkEntity.allCases.count, "no two record types share a group")
        for kind in WhereUsedGroupKind.allCases {
            XCTAssertFalse(kind.title.isEmpty)
            XCTAssertFalse(kind.symbol.isEmpty)
        }
    }

    // MARK: Direction and relation text

    func testTheSameLinkReadsDifferentlyFromEachSide() throws {
        let model = try makeModel()
        defer { model.library.close() }
        let paper = try ModelTestSupport.item(model)
        let draftID = try ModelTestSupport.insertDraft(model)
        try model.links.add(from: LinkEnd(.draft, draftID), to: paperEnd(paper), rel: .cites)

        let fromPaper = try WhereUsedLogic.load(for: paperEnd(paper), model: model)
        let fromDraft = try WhereUsedLogic.load(for: LinkEnd(.draft, draftID), model: model)

        let seenByPaper = try XCTUnwrap(fromPaper.groups.first?.entries.first)
        XCTAssertEqual(seenByPaper.direction, .incoming)
        XCTAssertEqual(seenByPaper.relationText, "Cited by")
        XCTAssertEqual(seenByPaper.other, LinkEnd(.draft, draftID))

        let seenByDraft = try XCTUnwrap(fromDraft.groups.first?.entries.first)
        XCTAssertEqual(seenByDraft.direction, .outgoing)
        XCTAssertEqual(seenByDraft.relationText, "Cites")
        XCTAssertEqual(seenByDraft.other, paperEnd(paper))
    }

    func testRelationTextCoversEveryRelationInBothDirections() {
        for rel in LinkRel.allCases {
            let outgoing = WhereUsedLogic.relationText(rel, direction: .outgoing)
            let incoming = WhereUsedLogic.relationText(rel, direction: .incoming)
            XCTAssertFalse(outgoing.isEmpty)
            XCTAssertFalse(incoming.isEmpty)
            if rel == .related {
                XCTAssertEqual(outgoing, incoming, "related reads the same from both sides")
            } else {
                XCTAssertNotEqual(outgoing, incoming, "\(rel) should read differently from each side")
            }
        }
        XCTAssertEqual(WhereUsedLogic.relationText(.uses, direction: .incoming), "Used by")
        XCTAssertEqual(WhereUsedLogic.relationText(.partOf, direction: .incoming), "Contains")
    }

    func testTwoRelationsToTheSameRecordAreTwoEntries() throws {
        let model = try makeModel()
        defer { model.library.close() }
        let paper = try ModelTestSupport.item(model)
        let draftID = try ModelTestSupport.insertDraft(model)
        try model.links.add(from: LinkEnd(.draft, draftID), to: paperEnd(paper), rel: .cites)
        try model.links.add(from: LinkEnd(.draft, draftID), to: paperEnd(paper), rel: .uses)

        let result = try WhereUsedLogic.load(for: paperEnd(paper), model: model)
        let entries = try XCTUnwrap(result.groups.first?.entries)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.map(\.rel)), [.cites, .uses])
    }

    // MARK: Notes and ideas

    func testNotesAndIdeasShowTheirKind() throws {
        let model = try makeModel()
        defer { model.library.close() }
        let paper = try ModelTestSupport.item(model)
        let gap = try ThoughtStore(model: model).create(NewThought(kind: .gap, title: "Drift gap"))
        let idea = try ThoughtStore(model: model).create(NewThought(kind: .idea, title: "Try momentum"))
        try model.links.add(from: LinkEnd(.thought, gap.id), to: paperEnd(paper), rel: .related)
        try model.links.add(from: LinkEnd(.thought, idea.id), to: paperEnd(paper), rel: .related)

        let result = try WhereUsedLogic.load(for: paperEnd(paper), model: model)
        let notes = try XCTUnwrap(result.groups.first { $0.kind == .notes })
        let byTitle = Dictionary(uniqueKeysWithValues: notes.entries.map { ($0.title, $0.subtitle) })

        XCTAssertEqual(byTitle["Drift gap"], "Gap")
        XCTAssertEqual(byTitle["Try momentum"], "Idea")
    }

    // MARK: Trash and missing records

    func testTrashedRecordsAreHiddenAndCounted() throws {
        let model = try makeModel()
        defer { model.library.close() }
        let paper = try ModelTestSupport.item(model)
        let kept = try ThoughtStore(model: model).create(NewThought(title: "Kept note"))
        let trashed = try ThoughtStore(model: model).create(NewThought(title: "Trashed note"))
        try model.links.add(from: LinkEnd(.thought, kept.id), to: paperEnd(paper), rel: .related)
        try model.links.add(from: LinkEnd(.thought, trashed.id), to: paperEnd(paper), rel: .related)
        try ThoughtStore(model: model).trash(id: trashed.id)

        let result = try WhereUsedLogic.load(for: paperEnd(paper), model: model)

        XCTAssertEqual(result.totalCount, 1)
        XCTAssertEqual(result.hiddenCount, 1)
        XCTAssertEqual(result.groups.first?.entries.first?.title, "Kept note")
    }

    func testIncludeTrashedShowsThemMarked() throws {
        let model = try makeModel()
        defer { model.library.close() }
        let paper = try ModelTestSupport.item(model)
        let trashed = try ThoughtStore(model: model).create(NewThought(title: "Trashed note"))
        try model.links.add(from: LinkEnd(.thought, trashed.id), to: paperEnd(paper), rel: .related)
        try ThoughtStore(model: model).trash(id: trashed.id)

        let result = try WhereUsedLogic.load(for: paperEnd(paper), model: model, includeTrashed: true)

        XCTAssertEqual(result.hiddenCount, 0)
        let entry = try XCTUnwrap(result.groups.first?.entries.first)
        XCTAssertEqual(entry.title, "Trashed note")
        XCTAssertTrue(entry.isTrashed)
    }

    func testATrashedPaperIsHiddenToo() throws {
        let model = try makeModel()
        defer { model.library.close() }
        let draftID = try ModelTestSupport.insertDraft(model)
        let paper = try ModelTestSupport.item(model)
        try model.links.add(from: LinkEnd(.draft, draftID), to: paperEnd(paper), rel: .cites)
        try ModelTestSupport.trash(model, itemID: paper.id)

        let result = try WhereUsedLogic.load(for: LinkEnd(.draft, draftID), model: model)

        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertEqual(result.hiddenCount, 1)
    }

    func testARecordThatNoLongerExistsIsHiddenAndShownAsMissingWhenAsked() throws {
        let model = try makeModel()
        defer { model.library.close() }
        let paper = try ModelTestSupport.item(model)
        let thoughtID = try ModelTestSupport.insertThought(model)
        try model.links.add(from: LinkEnd(.thought, thoughtID), to: paperEnd(paper), rel: .related)
        try model.database.run("DELETE FROM thoughts WHERE id = ?", [.text(thoughtID)])

        let hidden = try WhereUsedLogic.load(for: paperEnd(paper), model: model)
        XCTAssertEqual(hidden.hiddenCount, 1)
        XCTAssertTrue(hidden.groups.isEmpty)

        let shown = try WhereUsedLogic.load(for: paperEnd(paper), model: model, includeTrashed: true)
        XCTAssertEqual(shown.groups.first?.entries.first?.title, "Missing record")
    }

    // MARK: Removing a link

    func testRemovingALinkTakesItOutOfThePanelButKeepsBothRecords() throws {
        let model = try makeModel()
        defer { model.library.close() }
        let paper = try ModelTestSupport.item(model)
        let draftID = try ModelTestSupport.insertDraft(model)
        let link = try model.links.add(from: LinkEnd(.draft, draftID), to: paperEnd(paper), rel: .cites)

        try model.links.remove(linkID: link.id)
        let result = try WhereUsedLogic.load(for: paperEnd(paper), model: model)

        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertEqual(try ModelTestSupport.count(model, "drafts", where: "id = '\(draftID)'"), 1)
        XCTAssertEqual(try ModelTestSupport.count(model, "items", where: "id = '\(paper.id)'"), 1)
    }
}