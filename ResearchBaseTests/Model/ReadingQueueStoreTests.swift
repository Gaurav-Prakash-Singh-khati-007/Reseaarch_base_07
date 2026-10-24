//
//  ReadingQueueStoreTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 20/10/26.
//


//
//  ReadingQueueStoreTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 16 · Feature: F-28
//

import XCTest
@testable import ResearchBase

@MainActor
final class ReadingQueueStoreTests: XCTestCase {

    private func fixture(sink: ChangeSink? = nil) throws -> (LibraryModel, ReadingQueueStore, [ModelItem]) {
        let model = try ModelTestSupport.makeModel(self, sink: sink)
        let items = try (1...3).map { try ModelTestSupport.item(model, title: "Paper \($0)", author: "Author\($0)", given: "A", year: 2020 + $0) }
        return (model, ReadingQueueStore(model: model), items)
    }

    func testQueueKeepsTheOrderItemsWereAdded() throws {
        let (model, queue, p) = try fixture()
        defer { model.library.close() }

        try queue.add(itemID: p[2].id)
        try queue.add(itemID: p[0].id)
        try queue.add(itemID: p[1].id)
        try queue.add(itemID: p[0].id)   // again: no duplicate, moves to the end

        XCTAssertEqual(try queue.queue().map(\.id), [p[2].id, p[1].id, p[0].id])
        XCTAssertEqual(try queue.queueCount(), 3)
        XCTAssertTrue(try queue.isQueued(itemID: p[1].id))
    }

    func testMoveAndRemove() throws {
        let (model, queue, p) = try fixture()
        defer { model.library.close() }

        for item in p { try queue.add(itemID: item.id) }
        try queue.move(itemID: p[2].id, toIndex: 0)
        XCTAssertEqual(try queue.queue().map(\.id), [p[2].id, p[0].id, p[1].id])

        try queue.move(itemID: p[2].id, toIndex: 99)
        XCTAssertEqual(try queue.queue().map(\.id), [p[0].id, p[1].id, p[2].id])

        try queue.remove(itemID: p[1].id)
        XCTAssertEqual(try queue.queue().map(\.id), [p[0].id, p[2].id])
        XCTAssertFalse(try queue.isQueued(itemID: p[1].id))
        XCTAssertThrowsError(try queue.move(itemID: p[1].id, toIndex: 0))
    }

    func testTrashAndInboxAreHiddenFromTheQueue() throws {
        let (model, queue, p) = try fixture()
        defer { model.library.close() }

        try queue.add(itemID: p[0].id)
        try queue.add(itemID: p[1].id)
        try ModelTestSupport.trash(model, itemID: p[0].id)

        XCTAssertEqual(try queue.queue().map(\.id), [p[1].id])
        XCTAssertEqual(try queue.queueCount(), 1)
        XCTAssertThrowsError(try queue.add(itemID: p[0].id), "a trashed paper cannot be queued")
        XCTAssertThrowsError(try queue.add(itemID: "missing"))
    }

    func testMarkingReadLeavesTheQueueUnlessKept() throws {
        let sink = RecordingChangeSink()
        let (model, queue, p) = try fixture(sink: sink)
        defer { model.library.close() }

        try queue.add(itemID: p[0].id)
        try queue.add(itemID: p[1].id)

        let done = try queue.setStatus(itemID: p[0].id, .read)
        XCTAssertEqual(done.readingStatus, .read)
        XCTAssertFalse(done.inQueue)
        XCTAssertEqual(try queue.queue().map(\.id), [p[1].id])

        try queue.setStatus(itemID: p[1].id, .read, keepInQueue: true)
        XCTAssertEqual(try queue.queue().map(\.id), [p[1].id])

        XCTAssertTrue(sink.entries(type: "item", field: "reading_status").contains { $0.newValue == "read" })
    }

    func testReadingTimeAddsUpAndRemembersThePage() throws {
        let sink = RecordingChangeSink()
        let (model, queue, p) = try fixture(sink: sink)
        defer { model.library.close() }

        sink.clear()
        XCTAssertEqual(try queue.lastPage(itemID: p[0].id), 1)

        try queue.recordReading(itemID: p[0].id, seconds: 120, page: 5)
        try queue.recordReading(itemID: p[0].id, seconds: 30)

        XCTAssertEqual(try queue.readingSeconds(itemID: p[0].id), 150)
        XCTAssertEqual(try queue.lastPage(itemID: p[0].id), 5, "no page given keeps the old one")
        XCTAssertEqual(try model.items.fetch(id: p[0].id)?.readingStatus, .reading, "unread becomes reading")

        // Time and page are not change-log noise.
        XCTAssertTrue(sink.entries(type: "item").allSatisfy { $0.field == "reading_status" || $0.field == nil })

        XCTAssertThrowsError(try queue.recordReading(itemID: p[0].id, seconds: -1))
        XCTAssertThrowsError(try queue.recordReading(itemID: p[0].id, seconds: 10, page: 0))
        XCTAssertThrowsError(try queue.recordReading(itemID: "missing", seconds: 10))
        XCTAssertEqual(try queue.readingSeconds(itemID: p[0].id), 150)
    }

    func testStatsCountLivePapersOnly() throws {
        let (model, queue, p) = try fixture()
        defer { model.library.close() }
        let inbox = try ModelTestSupport.item(model, title: "Waiting", author: "X", given: "Y", state: .inbox)
        _ = inbox

        try queue.add(itemID: p[0].id)
        try queue.recordReading(itemID: p[0].id, seconds: 600)
        try queue.setStatus(itemID: p[1].id, .read)
        try ModelTestSupport.trash(model, itemID: p[2].id)

        let stats = try queue.stats()
        XCTAssertEqual(stats, ReadingStats(unread: 0, reading: 1, read: 1, queued: 1, totalSeconds: 600))
        XCTAssertEqual(stats.total, 2)
    }

    func testReadCountSinceUsesTheChangeLog() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let item = try ModelTestSupport.item(model)
        let queue = ReadingQueueStore(model: model)

        // The null sink writes no log, so nothing is counted.
        try queue.setStatus(itemID: item.id, .read)
        XCTAssertEqual(try queue.readCount(since: Date(timeIntervalSinceNow: -3600)), 0)

        // A log row like the app's SQL sink writes.
        try model.database.run(
            "INSERT INTO changes (at, entity_type, entity_id, action, field, new_value) VALUES (?, 'item', ?, 'update', 'reading_status', 'read')",
            [.text(Library.nowISO()), .text(item.id)])
        XCTAssertEqual(try queue.readCount(since: Date(timeIntervalSinceNow: -3600)), 1)
        XCTAssertEqual(try queue.readCount(since: Date(timeIntervalSinceNow: 3600)), 0)
    }
}