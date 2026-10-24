//
//  SafetyChangeSinkTests.swift
//  ResearchBaseTests
//
//  Phase 1, Step 1C-1 (F-12): the SQL change sink and batches.
//  Every test uses its own temporary library.
//

import XCTest
@testable import ResearchBase

@MainActor
final class SafetyChangeSinkTests: XCTestCase {

    private struct Boom: Error {}

    private func makeModel() throws -> (LibraryModel, SafetySQLChangeSink, SafetyChangeLog) {
        let folder = try TestSupport.makeTempDirectory(self)
            .appendingPathComponent(Library.folderName, isDirectory: true)
        let library = try Library.open(at: folder)
        let model = SafetySQLChangeSink.makeModel(for: library)
        let sink = try XCTUnwrap(model.changeSink as? SafetySQLChangeSink)
        return (model, sink, SafetyChangeLog(model: model))
    }

    // MARK: Rows are written

    func testCreatingAnItemWritesAChangeRowWithABatchId() throws {
        let (model, _, log) = try makeModel()
        defer { model.library.close() }

        let item = try ModelTestSupport.item(model)

        let rows = try log.entries(entityType: "item", entityID: item.id)
        let created = rows.filter { $0.action == .create }
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created.first?.field, "title")
        XCTAssertEqual(created.first?.newValue, item.title)
        XCTAssertNotNil(created.first?.batchID)
        XCTAssertFalse(created.first?.at.isEmpty ?? true)
    }

    func testEveryRowHasABatchId() throws {
        let (model, _, _) = try makeModel()
        defer { model.library.close() }

        try ModelTestSupport.item(model)
        _ = try model.tags.create(name: "federated")

        XCTAssertGreaterThan(try ModelTestSupport.count(model, "changes"), 0)
        XCTAssertEqual(try ModelTestSupport.count(model, "changes", where: "batch_id IS NULL OR batch_id = ''"), 0)
    }

    func testOldAndNewValuesAreKept() throws {
        let (model, _, log) = try makeModel()
        defer { model.library.close() }

        let tag = try model.tags.create(name: "old name")
        _ = try model.tags.rename(id: tag.id, to: "new name")

        let rename = try log.entries(entityType: "tag", entityID: tag.id).first { $0.action == .update }
        XCTAssertEqual(rename?.field, "name")
        XCTAssertEqual(rename?.oldValue, "old name")
        XCTAssertEqual(rename?.newValue, "new name")
    }

    func testImportActionIsStoredAsImport() throws {
        let (model, sink, log) = try makeModel()
        defer { model.library.close() }

        try sink.record(
            entityType: "item", entityID: "x", action: .importRecord,
            field: nil, oldValue: nil, newValue: nil
        )

        XCTAssertEqual(try log.entries(entityType: "item", entityID: "x").first?.action, .importRecord)
        XCTAssertEqual(try ModelTestSupport.count(model, "changes", where: "action = 'import'"), 1)
    }

    // MARK: Batches

    func testSeparateActionsGetSeparateBatches() throws {
        let (model, _, log) = try makeModel()
        defer { model.library.close() }

        let first = try ModelTestSupport.item(model, title: "First paper")
        let firstBatch = try XCTUnwrap(try log.latestBatchID())
        let second = try ModelTestSupport.item(model, title: "Second paper")
        let secondBatch = try XCTUnwrap(try log.latestBatchID())

        XCTAssertNotEqual(firstBatch, secondBatch)
        XCTAssertTrue(try log.entries(inBatch: firstBatch).allSatisfy { $0.entityID != second.id })
        XCTAssertFalse(try log.entries(inBatch: firstBatch).isEmpty)
        XCTAssertTrue(try log.entries(inBatch: secondBatch).allSatisfy { $0.entityID != first.id })
    }

    func testOneBatchGroupsSeveralChanges() throws {
        let (model, _, log) = try makeModel()
        defer { model.library.close() }

        let item = try ModelTestSupport.item(model)
        let tag = try model.tags.create(name: "grouped")
        let before = try log.count()

        try model.inSafetyBatch {
            _ = try model.tags.rename(id: tag.id, to: "grouped again")
            try model.tags.assign(tagID: tag.id, to: item.id)
        }

        let newRows = try log.count() - before
        XCTAssertGreaterThanOrEqual(newRows, 2)
        let batchID = try XCTUnwrap(try log.latestBatchID())
        XCTAssertEqual(try log.entries(inBatch: batchID).count, newRows)
    }

    func testNestedBatchJoinsTheOuterOne() throws {
        let (model, _, log) = try makeModel()
        defer { model.library.close() }

        let tag = try model.tags.create(name: "nested")
        let before = try log.count()

        try model.inSafetyBatch {
            _ = try model.tags.rename(id: tag.id, to: "nested one")
            try model.inSafetyBatch {
                _ = try model.tags.rename(id: tag.id, to: "nested two")
            }
            _ = try model.tags.rename(id: tag.id, to: "nested three")
        }

        let batchID = try XCTUnwrap(try log.latestBatchID())
        XCTAssertEqual(try log.entries(inBatch: batchID).count, try log.count() - before)
    }

    func testBatchIsClosedAfterItEnds() throws {
        let (model, sink, _) = try makeModel()
        defer { model.library.close() }

        XCTAssertFalse(sink.batches.isOpen)
        try model.inSafetyBatch { XCTAssertTrue(sink.batches.isOpen) }
        XCTAssertFalse(sink.batches.isOpen)
        XCTAssertNil(sink.batches.currentID)
    }

    func testExtraEndBatchDoesNothing() throws {
        let (model, sink, _) = try makeModel()
        defer { model.library.close() }

        sink.endBatch()
        XCTAssertFalse(sink.batches.isOpen)

        let id = sink.beginBatch()
        XCTAssertEqual(sink.batches.currentID, id)
        sink.endBatch()
        XCTAssertNil(sink.batches.currentID)
    }

    // MARK: Failure leaves nothing behind

    func testThrowInsideBatchRollsBackDataAndHistory() throws {
        let (model, sink, log) = try makeModel()
        defer { model.library.close() }

        let itemsBefore = try ModelTestSupport.count(model, "items")
        let changesBefore = try log.count()

        XCTAssertThrowsError(try model.inSafetyBatch {
            try ModelTestSupport.item(model, title: "Will not survive")
            throw Boom()
        })

        XCTAssertEqual(try ModelTestSupport.count(model, "items"), itemsBefore)
        XCTAssertEqual(try log.count(), changesBefore)
        XCTAssertFalse(sink.batches.isOpen)
    }

    func testRolledBackBatchDoesNotLeakItsIdToTheNextChange() throws {
        let (model, _, log) = try makeModel()
        defer { model.library.close() }

        var failedBatch: String?
        XCTAssertThrowsError(try model.inSafetyBatch {
            try ModelTestSupport.item(model, title: "Gone")
            failedBatch = try log.latestBatchID()
            throw Boom()
        })

        try ModelTestSupport.item(model, title: "Kept")
        let keptBatch = try XCTUnwrap(try log.latestBatchID())
        XCTAssertNotEqual(keptBatch, failedBatch)
    }

    func testSinkFailureUndoesTheWholeChange() throws {
        let (model, _, _) = try makeModel()
        defer { model.library.close() }

        // Break the table the sink writes to; the item must not be created either.
        try model.database.exec("ALTER TABLE changes RENAME TO changes_broken")
        let itemsBefore = try ModelTestSupport.count(model, "items")

        XCTAssertThrowsError(try ModelTestSupport.item(model, title: "No history, no change"))
        XCTAssertEqual(try ModelTestSupport.count(model, "items"), itemsBefore)
    }

    // MARK: Fallback

    func testInSafetyBatchWorksWithAnotherSink() throws {
        let model = try ModelTestSupport.makeModel(self, sink: RecordingChangeSink())
        defer { model.library.close() }

        let item = try model.inSafetyBatch { try ModelTestSupport.item(model) }
        XCTAssertNotNil(try model.items.fetch(id: item.id))
    }
}
