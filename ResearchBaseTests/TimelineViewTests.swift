//
//  TimelineViewTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 24/10/26.
//


//
//  TimelineViewTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 78
//

import XCTest
@testable import ResearchBase

@MainActor
final class TimelineViewTests: XCTestCase {

    func testEmptyLibraryGivesNoEvents() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let loaded = RBA78TimelineLogic.load(model: model)
        XCTAssertTrue(loaded.events.isEmpty)
        XCTAssertTrue(loaded.recordIDs.isEmpty)
    }

    func testPapersAndThoughtsBecomeEventsWithTargets() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let item = try ModelTestSupport.item(model, title: "Federated")
        let thought = try ThoughtStore(model: model).create(NewThought(kind: .gap, title: "A gap"))

        let loaded = RBA78TimelineLogic.load(model: model)

        let paper = loaded.events.first { $0.kind == .paper }
        XCTAssertEqual(paper?.title, "Federated")
        XCTAssertEqual(paper?.action, "Paper added")
        XCTAssertEqual(paper?.target, UUID(uuidString: item.id).map { NavigationTarget.paper($0) })

        let gap = loaded.events.first { $0.kind == .gap }
        XCTAssertEqual(gap?.action, "Research gap created")
        XCTAssertEqual(gap?.target, UUID(uuidString: thought.id).map { NavigationTarget.researchGap($0) })

        XCTAssertTrue(loaded.recordIDs.contains(item.id.uppercased()))
        XCTAssertTrue(loaded.recordIDs.contains(thought.id.uppercased()))
    }

    func testTrashedItemsAreNotListed() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let item = try ModelTestSupport.item(model, title: "Gone")
        try ModelTestSupport.trash(model, itemID: item.id)

        XCTAssertTrue(RBA78TimelineLogic.load(model: model).events.isEmpty)
    }

    func testSortIsNewestFirstAndStable() {
        let now = Date()
        func ev(_ id: String, _ offset: TimeInterval) -> TimelineEvent {
            TimelineEvent(id: id, date: now.addingTimeInterval(offset), kind: .note,
                          action: "Note created", title: id, target: nil)
        }
        let sorted = RBA78TimelineLogic.sorted([ev("b", -10), ev("a", -10), ev("c", 5)])
        XCTAssertEqual(sorted.map { $0.id }, ["c", "a", "b"])
    }

    func testEntriesPutADayHeadingBeforeItsEvents() {
        let d = Calendar.current.startOfDay(for: Date())
        let e1 = TimelineEvent(id: "1", date: d, kind: .note, action: "x", title: "t", target: nil)
        let e2 = TimelineEvent(id: "2", date: d, kind: .note, action: "x", title: "t", target: nil)
        let entries = RBA78TimelineLogic.entries([TimelineDay(day: d, events: [e1, e2])])
        XCTAssertEqual(entries.count, 3)
        XCTAssertNotNil(entries[0].day)
        XCTAssertEqual(entries[1].event?.id, "1")
    }

    func testParseDate() {
        let a = RBA78TimelineLogic.parseDate("2026-10-18T09:30:00.123Z")
        let b = RBA78TimelineLogic.parseDate("2026-10-18T09:30:00Z")
        XCTAssertEqual(a.timeIntervalSince1970, b.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(RBA78TimelineLogic.parseDate("nope"), .distantPast)
    }
}