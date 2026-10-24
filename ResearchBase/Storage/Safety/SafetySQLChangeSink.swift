//
//  SafetySQLChangeSink.swift
//  ResearchBase
//
//  Phase 1, Step 1C-1 (F-12)
//
//  The real `ChangeSink`: every change the model reports becomes one row in
//  the `changes` table, with a `batch_id`.
//
//  * Inside a batch (`inSafetyBatch`) all rows share the batch id.
//  * Outside a batch each change gets its own new batch id, so it is still
//    one undoable action.
//  * `record` runs inside the model's own transaction. If the INSERT fails the
//    whole change is rolled back, and a rolled-back change leaves no row.
//  * Nothing here deletes or edits rows in `changes`. History is append-only.
//

import Foundation

final class SafetySQLChangeSink: ChangeSink {

    let database: LibraryDatabase
    let batches = SafetyBatchTracker()

    init(database: LibraryDatabase) {
        self.database = database
    }

    // MARK: ChangeSink

    func record(
        entityType: String,
        entityID: String,
        action: ChangeAction,
        field: String?,
        oldValue: String?,
        newValue: String?
    ) throws {
        let batchID = batches.currentID ?? UUID().uuidString
        try database.run(
            """
            INSERT INTO changes (at, entity_type, entity_id, action, field, old_value, new_value, batch_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(Library.nowISO()),
                .text(entityType),
                .text(entityID),
                .text(action.rawValue),
                LibraryModel.text(field),
                LibraryModel.text(oldValue),
                LibraryModel.text(newValue),
                .text(batchID)
            ]
        )
    }

    // MARK: Batches

    /// Opens a batch (or joins the open one). Pair every call with `endBatch()`.
    @discardableResult
    func beginBatch() -> String { batches.begin() }

    func endBatch() { batches.end() }

    /// Runs `body` with a batch open and always closes it, even on a throw.
    func inBatch<T>(_ body: () throws -> T) rethrows -> T {
        batches.begin()
        defer { batches.end() }
        return try body()
    }

    // MARK: Setup

    /// A `LibraryModel` on `library` whose changes are written to `changes`.
    static func makeModel(for library: Library) -> LibraryModel {
        LibraryModel(library: library, changeSink: SafetySQLChangeSink(database: library.database))
    }
}

extension LibraryModel {

    /// One user action = one transaction = one batch id.
    /// If anything inside throws, the data changes AND their history rows are
    /// rolled back together. With a sink that is not `SafetySQLChangeSink`
    /// it is just `atomically`.
    func inSafetyBatch<T>(_ body: () throws -> T) throws -> T {
        guard let sink = changeSink as? SafetySQLChangeSink else {
            return try atomically(body)
        }
        return try atomically { try sink.inBatch(body) }
    }
}
