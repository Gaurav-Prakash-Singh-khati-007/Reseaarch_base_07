//
//  HomeViewTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 71 · Features: F-28, F-46
//

import XCTest
@testable import ResearchBase

private final class RBA71FakeCenter: ReminderNotificationCenter {
    func requestAuthorization() async -> Bool { true }
    func isAuthorized() async -> Bool { true }
    func pendingIdentifiers() async -> [String] { [] }
    func add(_ notice: ReminderNotice) async throws {}
    func remove(identifiers: [String]) async {}
}

@MainActor
final class HomeViewTests: XCTestCase {

    func testDueLabels() {
        XCTAssertEqual(RBA71HomeLogic.dueLabel(daysLeft: 0), "Today")
        XCTAssertEqual(RBA71HomeLogic.dueLabel(daysLeft: 1), "Tomorrow")
        XCTAssertEqual(RBA71HomeLogic.dueLabel(daysLeft: 5), "in 5 days")
        XCTAssertEqual(RBA71HomeLogic.dueLabel(daysLeft: -1), "1 day overdue")
        XCTAssertEqual(RBA71HomeLogic.dueLabel(daysLeft: -3), "3 days overdue")
    }

    func testHoursText() {
        XCTAssertEqual(RBA71HomeLogic.hoursText(seconds: 10), "0 min")
        XCTAssertEqual(RBA71HomeLogic.hoursText(seconds: 600), "10 min")
        XCTAssertEqual(RBA71HomeLogic.hoursText(seconds: 3600), "1 h")
        XCTAssertEqual(RBA71HomeLogic.hoursText(seconds: 5400), "1.5 h")
    }

    func testSnapshotOfEmptyLibraryIsZeroNotAnError() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let scheduler = ReminderScheduler(model: model, center: RBA71FakeCenter())
        let snap = RBA71HomeLogic.snapshot(model: model, scheduler: scheduler)

        XCTAssertEqual(snap.stats.total, 0)
        XCTAssertTrue(snap.queueTop.isEmpty)
        XCTAssertTrue(snap.deadlines.isEmpty)
        XCTAssertEqual(snap.readThisWeek, 0)
    }

    func testSnapshotShowsStatsAndTopThreeOfTheQueue() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let queue = ReadingQueueStore(model: model)
        var ids: [String] = []
        for i in 0..<5 {
            let item = try ModelTestSupport.item(model, title: "Paper \(i)")
            ids.append(item.id)
            try queue.add(itemID: item.id)
        }
        _ = try queue.setStatus(itemID: ids[4], .reading, keepInQueue: true)

        let scheduler = ReminderScheduler(model: model, center: RBA71FakeCenter())
        let snap = RBA71HomeLogic.snapshot(model: model, scheduler: scheduler)

        XCTAssertEqual(snap.stats.queued, 5)
        XCTAssertEqual(snap.stats.reading, 1)
        XCTAssertEqual(snap.stats.unread, 4)
        XCTAssertEqual(snap.queueTop.count, 3)
        XCTAssertEqual(snap.queueTop.map { $0.id }, Array(ids.prefix(3)))
    }

    // MARK: - Overview counts and lists from SQLite

    func testSnapshotCountsPapersAndThoughtsFromSQLite() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        _ = try ModelTestSupport.item(model, title: "One")
        _ = try ModelTestSupport.item(model, title: "Two")
        let thoughts = ThoughtStore(model: model)
        _ = try thoughts.create(NewThought(kind: .finding, title: "F1"))
        _ = try thoughts.create(NewThought(kind: .gap, title: "G1"))
        _ = try thoughts.create(NewThought(kind: .gap, title: "G2"))

        let scheduler = ReminderScheduler(model: model, center: RBA71FakeCenter())
        let snap = RBA71HomeLogic.snapshot(model: model, scheduler: scheduler)

        XCTAssertEqual(snap.paperCount, 2)
        XCTAssertEqual(snap.findingCount, 1)
        XCTAssertEqual(snap.gapCount, 2)
        XCTAssertEqual(snap.writingCount, 0)
        XCTAssertEqual(snap.recentPapers.count, 2)
        XCTAssertEqual(Set(snap.activity.map { $0.title }), ["One", "Two", "F1", "G1", "G2"])
    }

    func testEmptyLibraryHasNoRecentPapersOrActivity() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let scheduler = ReminderScheduler(model: model, center: RBA71FakeCenter())
        let snap = RBA71HomeLogic.snapshot(model: model, scheduler: scheduler)

        XCTAssertEqual(snap.paperCount, 0)
        XCTAssertTrue(snap.recentPapers.isEmpty)
        XCTAssertTrue(snap.activity.isEmpty)
        XCTAssertTrue(snap.writingInProgress.isEmpty)
    }

    func testRecentPapersAreCappedAtThree() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        for i in 0..<5 { _ = try ModelTestSupport.item(model, title: "P\(i)") }

        let scheduler = ReminderScheduler(model: model, center: RBA71FakeCenter())
        let snap = RBA71HomeLogic.snapshot(model: model, scheduler: scheduler)

        XCTAssertEqual(snap.paperCount, 5)
        XCTAssertEqual(snap.recentPapers.count, 3)
    }

    func testParseDateHandlesFractionalPlainAndBadText() {
        let a = RBA71HomeLogic.parseDate("2026-10-18T09:30:00.123Z")
        let b = RBA71HomeLogic.parseDate("2026-10-18T09:30:00Z")
        XCTAssertEqual(a.timeIntervalSince1970, b.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(RBA71HomeLogic.parseDate("not a date"), .distantPast)
    }
}
