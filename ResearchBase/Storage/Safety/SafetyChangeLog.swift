//
//  SafetyChangeLog.swift
//  ResearchBase
//
//  Phase 1, Step 1C-1 (F-12)
//
//  Read-only view of the `changes` table. Step 1C-3 (undo, history per item)
//  builds on it. It never writes.
//

import Foundation

struct SafetyChangeEntry: Equatable {
    let id: Int64
    let at: String
    let entityType: String
    let entityID: String
    let action: ChangeAction
    let field: String?
    let oldValue: String?
    let newValue: String?
    let batchID: String?
}

final class SafetyChangeLog {

    private let database: LibraryDatabase

    init(database: LibraryDatabase) {
        self.database = database
    }

    convenience init(model: LibraryModel) {
        self.init(database: model.database)
    }

    private static let columns =
        "id, at, entity_type, entity_id, action, field, old_value, new_value, batch_id"

    /// All rows of one batch, in the order they were written.
    func entries(inBatch batchID: String) throws -> [SafetyChangeEntry] {
        try database.rows(
            "SELECT \(Self.columns) FROM changes WHERE batch_id = ? ORDER BY id ASC",
            [.text(batchID)]
        ).map { try Self.entry(from: $0) }
    }

    /// History of one record, newest first.
    func entries(entityType: String, entityID: String, limit: Int = 200) throws -> [SafetyChangeEntry] {
        try database.rows(
            "SELECT \(Self.columns) FROM changes WHERE entity_type = ? AND entity_id = ? ORDER BY id DESC LIMIT ?",
            [.text(entityType), .text(entityID), .int(Int64(max(1, limit)))]
        ).map { try Self.entry(from: $0) }
    }

    /// The batch id of the most recent change, if any.
    func latestBatchID() throws -> String? {
        try database.scalarText("SELECT batch_id FROM changes ORDER BY id DESC LIMIT 1")
    }

    func count() throws -> Int {
        Int(try database.scalarInt("SELECT COUNT(*) FROM changes") ?? 0)
    }

    static func entry(from row: SQLRow) throws -> SafetyChangeEntry {
        guard let id = row.int("id"),
              let at = row.text("at"),
              let type = row.text("entity_type"),
              let entityID = row.text("entity_id"),
              let rawAction = row.text("action"),
              let action = ChangeAction(rawValue: rawAction) else {
            throw ModelError.invalidValue("changes row")
        }
        return SafetyChangeEntry(
            id: id, at: at, entityType: type, entityID: entityID, action: action,
            field: row.text("field"), oldValue: row.text("old_value"),
            newValue: row.text("new_value"), batchID: row.text("batch_id")
        )
    }
}
