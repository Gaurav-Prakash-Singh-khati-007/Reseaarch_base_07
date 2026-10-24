//
//  CollectionStore.swift
//  ResearchBase
//
//  Phase 1, Step 1B (F-09)
//
//  Nested folders for papers. A folder can hold folders to any depth.
//  A folder can never be moved inside itself or its own subfolders.
//  Removing a folder (Trash) is Step 1C: here only `deleted_at` is read,
//  and trashed folders are left out of every list.
//

import Foundation

final class CollectionStore {

    unowned let model: LibraryModel

    init(model: LibraryModel) {
        self.model = model
    }

    // MARK: Create and read

    /// New folder at the end of its parent (or at the top when `parentID` is nil).
    @discardableResult
    func create(name rawName: String, parentID: String? = nil) throws -> ModelCollection {

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ModelError.emptyName }

        return try model.atomically {

            if let parentID, try collection(id: parentID) == nil {
                throw ModelError.collectionMissing(parentID)
            }

            let id = model.newID()
            let position = try nextPosition(under: parentID)

            try model.database.run(
                "INSERT INTO collections (id, parent_id, name, position) VALUES (?, ?, ?, ?)",
                [.text(id), LibraryModel.text(parentID), .text(name), .int(Int64(position))]
            )
            try model.record("collection", id, .create, field: "name", new: name)

            return ModelCollection(id: id, parentID: parentID, name: name, position: position, deletedAt: nil)
        }
    }

    /// One folder. Trashed folders are not returned.
    func collection(id: String) throws -> ModelCollection? {
        try model.database.rows(
            "SELECT * FROM collections WHERE id = ? AND deleted_at IS NULL", [.text(id)]
        ).first.map { Self.collection(from: $0) }
    }

    /// The folders directly inside `parentID` (nil = top level), in their order.
    func children(of parentID: String?) throws -> [ModelCollection] {
        let rows: [SQLRow]
        if let parentID {
            rows = try model.database.rows(
                "SELECT * FROM collections WHERE parent_id = ? AND deleted_at IS NULL ORDER BY position, name COLLATE NOCASE, id",
                [.text(parentID)]
            )
        } else {
            rows = try model.database.rows(
                "SELECT * FROM collections WHERE parent_id IS NULL AND deleted_at IS NULL ORDER BY position, name COLLATE NOCASE, id"
            )
        }
        return rows.map { Self.collection(from: $0) }
    }

    /// Every folder, parents before children is NOT guaranteed; use `children(of:)` to build a tree.
    func all() throws -> [ModelCollection] {
        try model.database.rows(
            "SELECT * FROM collections WHERE deleted_at IS NULL ORDER BY parent_id, position, name COLLATE NOCASE, id"
        ).map { Self.collection(from: $0) }
    }

    /// From the top-level folder down to this folder, for a breadcrumb.
    func path(of id: String) throws -> [ModelCollection] {
        var result: [ModelCollection] = []
        var current = try collection(id: id)
        var guardCount = 0
        while let folder = current, guardCount < 1000 {
            result.insert(folder, at: 0)
            current = try folder.parentID.flatMap { try collection(id: $0) }
            guardCount += 1
        }
        return result
    }

    /// The folder and every folder below it, at any depth.
    func subtreeIDs(of id: String) throws -> [String] {
        try model.database.rows(
            """
            WITH RECURSIVE sub(id) AS (
                SELECT id FROM collections WHERE id = ? AND deleted_at IS NULL
                UNION
                SELECT c.id FROM collections c JOIN sub ON c.parent_id = sub.id WHERE c.deleted_at IS NULL
            )
            SELECT id FROM sub ORDER BY id
            """,
            [.text(id)]
        ).compactMap { $0.text("id") }
    }

    // MARK: Rename, move, reorder

    @discardableResult
    func rename(id: String, to rawName: String) throws -> ModelCollection {

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ModelError.emptyName }

        return try model.atomically {
            guard var folder = try collection(id: id) else { throw ModelError.collectionMissing(id) }
            if folder.name == name { return folder }

            try model.database.run("UPDATE collections SET name = ? WHERE id = ?", [.text(name), .text(id)])
            try model.record("collection", id, .update, field: "name", old: folder.name, new: name)

            folder.name = name
            return folder
        }
    }

    /// Moves a folder under another one (nil = top level), to the end of that list.
    /// Throws `.collectionCycle` when the new parent is the folder itself or one of its subfolders.
    @discardableResult
    func move(id: String, toParent newParentID: String?) throws -> ModelCollection {

        try model.atomically {

            guard var folder = try collection(id: id) else { throw ModelError.collectionMissing(id) }
            if folder.parentID == newParentID { return folder }

            if let newParentID {
                guard try collection(id: newParentID) != nil else { throw ModelError.collectionMissing(newParentID) }
                // Is `id` the new parent or one of its ancestors?
                let hits = try model.database.scalarInt(
                    """
                    WITH RECURSIVE up(id, parent_id) AS (
                        SELECT id, parent_id FROM collections WHERE id = ?
                        UNION
                        SELECT c.id, c.parent_id FROM collections c JOIN up ON c.id = up.parent_id
                    )
                    SELECT COUNT(*) FROM up WHERE id = ?
                    """,
                    [.text(newParentID), .text(id)]
                ) ?? 0
                if hits > 0 { throw ModelError.collectionCycle }
            }

            let position = try nextPosition(under: newParentID)
            try model.database.run(
                "UPDATE collections SET parent_id = ?, position = ? WHERE id = ?",
                [LibraryModel.text(newParentID), .int(Int64(position)), .text(id)]
            )
            try model.record("collection", id, .update, field: "parent_id", old: folder.parentID, new: newParentID)

            folder.parentID = newParentID
            folder.position = position
            return folder
        }
    }

    /// Sets the order of the folders inside `parentID` to match `orderedIDs`.
    /// Folders not listed keep their relative order after the listed ones.
    func reorder(parentID: String?, orderedIDs: [String]) throws {
        try model.atomically {
            let current = try children(of: parentID).map { $0.id }
            let listed = orderedIDs.filter { current.contains($0) }
            let rest = current.filter { !listed.contains($0) }

            for (position, id) in (listed + rest).enumerated() {
                let changed = try model.database.run(
                    "UPDATE collections SET position = ? WHERE id = ? AND position != ?",
                    [.int(Int64(position)), .text(id), .int(Int64(position))]
                )
                if changed > 0 {
                    try model.record("collection", id, .update, field: "position", old: nil, new: String(position))
                }
            }
        }
    }

    // MARK: Items in folders

    /// Puts an item in a folder. An item can be in many folders. Doing it twice changes nothing.
    func addItem(_ itemID: String, to collectionID: String) throws {
        try model.atomically {
            guard try collection(id: collectionID) != nil else { throw ModelError.collectionMissing(collectionID) }
            guard try model.items.fetch(id: itemID) != nil else { throw ModelError.notFound(kind: "paper", id: itemID) }

            let changed = try model.database.run(
                "INSERT OR IGNORE INTO collection_items (collection_id, item_id) VALUES (?, ?)",
                [.text(collectionID), .text(itemID)]
            )
            if changed > 0 {
                try model.record("collection", collectionID, .update, field: "item", old: nil, new: itemID)
            }
        }
    }

    /// Takes an item out of a folder (the item itself stays in the library).
    func removeItem(_ itemID: String, from collectionID: String) throws {
        try model.atomically {
            let changed = try model.database.run(
                "DELETE FROM collection_items WHERE collection_id = ? AND item_id = ?",
                [.text(collectionID), .text(itemID)]
            )
            if changed > 0 {
                try model.record("collection", collectionID, .update, field: "item", old: itemID, new: nil)
            }
        }
    }

    /// Items in a folder (and, with `includeSubfolders`, in every folder below it). Trashed items are left out.
    func items(in collectionID: String, includeSubfolders: Bool = false, limit: Int = 500, offset: Int = 0) throws -> [ModelItem] {

        let ids = try includeSubfolders ? subtreeIDs(of: collectionID) : [collectionID]
        guard !ids.isEmpty else { return [] }

        let marks = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let rows = try model.database.rows(
            """
            SELECT DISTINCT i.* FROM items i
            JOIN collection_items ci ON ci.item_id = i.id
            WHERE ci.collection_id IN (\(marks)) AND i.deleted_at IS NULL
            ORDER BY i.added_at DESC, i.id
            LIMIT ? OFFSET ?
            """,
            ids.map { SQLValue.text($0) } + [.int(Int64(limit)), .int(Int64(offset))]
        )
        return try rows.map { try ItemStore.item(from: $0) }
    }

    func collections(containing itemID: String) throws -> [ModelCollection] {
        try model.database.rows(
            """
            SELECT c.* FROM collections c JOIN collection_items ci ON ci.collection_id = c.id
            WHERE ci.item_id = ? AND c.deleted_at IS NULL ORDER BY c.name COLLATE NOCASE
            """,
            [.text(itemID)]
        ).map { Self.collection(from: $0) }
    }

    // MARK: Helpers

    private func nextPosition(under parentID: String?) throws -> Int {
        let value: Int64?
        if let parentID {
            value = try model.database.scalarInt(
                "SELECT COALESCE(MAX(position) + 1, 0) FROM collections WHERE parent_id = ?", [.text(parentID)]
            )
        } else {
            value = try model.database.scalarInt(
                "SELECT COALESCE(MAX(position) + 1, 0) FROM collections WHERE parent_id IS NULL"
            )
        }
        return Int(value ?? 0)
    }

    static func collection(from row: SQLRow) -> ModelCollection {
        ModelCollection(
            id: row.text("id") ?? "",
            parentID: row.text("parent_id"),
            name: row.text("name") ?? "",
            position: Int(row.int("position") ?? 0),
            deletedAt: row.text("deleted_at")
        )
    }
}
