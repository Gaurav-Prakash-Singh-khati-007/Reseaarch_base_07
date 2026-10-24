//
//  TagStore.swift
//  ResearchBase
//
//  Phase 1, Step 1B (F-08, X-03)
//
//  Tags can be created, renamed, recoloured, put on items and merged.
//  Names are unique ignoring case (the schema enforces it).
//

import Foundation

final class TagStore {

    unowned let model: LibraryModel

    init(model: LibraryModel) {
        self.model = model
    }

    // MARK: Create and read

    @discardableResult
    func create(name rawName: String, color: String = "") throws -> Tag {

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ModelError.emptyName }
        let color = try Self.checkedColor(color)

        return try model.atomically {

            if try tag(named: name) != nil { throw ModelError.tagNameTaken(name) }

            let id = model.newID()
            try model.database.run(
                "INSERT INTO tags (id, name, color) VALUES (?, ?, ?)",
                [.text(id), .text(name), .text(color)]
            )
            try model.record("tag", id, .create, field: "name", new: name)
            return Tag(id: id, name: name, color: color)
        }
    }

    /// The existing tag with this name (any capitalisation), or a new one.
    @discardableResult
    func findOrCreate(name rawName: String) throws -> Tag {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ModelError.emptyName }
        return try model.atomically {
            if let existing = try tag(named: name) { return existing }
            return try create(name: name)
        }
    }

    func tag(id: String) throws -> Tag? {
        try model.database.rows("SELECT * FROM tags WHERE id = ?", [.text(id)]).first.map { Self.tag(from: $0) }
    }

    func tag(named name: String) throws -> Tag? {
        try model.database.rows(
            "SELECT * FROM tags WHERE name = ? COLLATE NOCASE", [.text(name)]
        ).first.map { Self.tag(from: $0) }
    }

    func all() throws -> [Tag] {
        try model.database.rows("SELECT * FROM tags ORDER BY name COLLATE NOCASE").map { Self.tag(from: $0) }
    }

    /// Every tag with the number of non-trashed items that have it (the counts in the manager).
    func usage() throws -> [TagUsage] {
        let rows = try model.database.rows(
            """
            SELECT t.*, COUNT(i.id) AS item_count
            FROM tags t
            LEFT JOIN item_tags it ON it.tag_id = t.id
            LEFT JOIN items i ON i.id = it.item_id AND i.deleted_at IS NULL
            GROUP BY t.id
            ORDER BY t.name COLLATE NOCASE
            """
        )
        return rows.map { TagUsage(tag: Self.tag(from: $0), itemCount: Int($0.int("item_count") ?? 0)) }
    }

    func tags(of itemID: String) throws -> [Tag] {
        try model.database.rows(
            """
            SELECT t.* FROM tags t JOIN item_tags it ON it.tag_id = t.id
            WHERE it.item_id = ? ORDER BY t.name COLLATE NOCASE
            """,
            [.text(itemID)]
        ).map { Self.tag(from: $0) }
    }

    // MARK: Rename and recolour

    /// Renames a tag. Changing only the capitalisation of its own name is allowed.
    /// A name another tag already has is refused (use `merge`).
    @discardableResult
    func rename(id: String, to rawName: String) throws -> Tag {

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ModelError.emptyName }

        return try model.atomically {

            guard var existing = try tag(id: id) else { throw ModelError.notFound(kind: "tag", id: id) }

            if let other = try tag(named: name), other.id != id { throw ModelError.tagNameTaken(name) }
            if existing.name == name { return existing }

            try model.database.run("UPDATE tags SET name = ? WHERE id = ?", [.text(name), .text(id)])
            try model.record("tag", id, .update, field: "name", old: existing.name, new: name)

            existing.name = name
            return existing
        }
    }

    /// `color` is "" (none), "#RRGGBB", or a lower-case colour word.
    @discardableResult
    func setColor(id: String, to rawColor: String) throws -> Tag {

        let color = try Self.checkedColor(rawColor)

        return try model.atomically {

            guard var existing = try tag(id: id) else { throw ModelError.notFound(kind: "tag", id: id) }
            if existing.color == color { return existing }

            try model.database.run("UPDATE tags SET color = ? WHERE id = ?", [.text(color), .text(id)])
            try model.record("tag", id, .update, field: "color", old: existing.color, new: color)

            existing.color = color
            return existing
        }
    }

    // MARK: On items

    /// Puts a tag on an item. Doing it twice changes nothing the second time.
    func assign(tagID: String, to itemID: String) throws {
        try model.atomically {
            guard try tag(id: tagID) != nil else { throw ModelError.notFound(kind: "tag", id: tagID) }
            guard try model.items.fetch(id: itemID) != nil else { throw ModelError.notFound(kind: "paper", id: itemID) }

            let changed = try model.database.run(
                "INSERT OR IGNORE INTO item_tags (item_id, tag_id) VALUES (?, ?)",
                [.text(itemID), .text(tagID)]
            )
            if changed > 0 {
                try model.record("item", itemID, .update, field: "tag", old: nil, new: tagID)
            }
        }
    }

    /// Takes a tag off an item (the tag itself stays). The removed pair is reported
    /// to the change sink so it can be put back.
    func unassign(tagID: String, from itemID: String) throws {
        try model.atomically {
            let changed = try model.database.run(
                "DELETE FROM item_tags WHERE item_id = ? AND tag_id = ?",
                [.text(itemID), .text(tagID)]
            )
            if changed > 0 {
                try model.record("item", itemID, .update, field: "tag", old: tagID, new: nil)
            }
        }
    }

    // MARK: Merge (X-03)

    /// Moves every item from `source` to `target` (an item that had both keeps one),
    /// then removes the `source` tag. Returns how many items were moved.
    /// The `target` keeps its name and colour.
    ///
    /// The reported change holds a JSON snapshot of the removed tag and its items,
    /// so Step 1C can undo the merge.
    @discardableResult
    func merge(_ sourceID: String, into targetID: String) throws -> Int {

        guard sourceID != targetID else { throw ModelError.sameRecord }

        return try model.atomically {

            guard let source = try tag(id: sourceID) else { throw ModelError.notFound(kind: "tag", id: sourceID) }
            guard try tag(id: targetID) != nil else { throw ModelError.notFound(kind: "tag", id: targetID) }

            let itemIDs = try model.database.rows(
                "SELECT item_id FROM item_tags WHERE tag_id = ? ORDER BY item_id", [.text(sourceID)]
            ).compactMap { $0.text("item_id") }

            try model.database.run(
                "INSERT OR IGNORE INTO item_tags (item_id, tag_id) SELECT item_id, ? FROM item_tags WHERE tag_id = ?",
                [.text(targetID), .text(sourceID)]
            )
            try model.database.run("DELETE FROM item_tags WHERE tag_id = ?", [.text(sourceID)])

            // Needed: the schema has no deleted_at on tags. Fully described by the snapshot.
            try model.database.run("DELETE FROM tags WHERE id = ?", [.text(sourceID)])

            let snapshot = LibraryModel.json([
                "tag": ["id": source.id, "name": source.name, "color": source.color],
                "items": itemIDs
            ] as [String: Any])
            try model.record("tag", sourceID, .merge, field: "merged_into", old: snapshot, new: targetID)

            return itemIDs.count
        }
    }

    // MARK: Helpers

    static func tag(from row: SQLRow) -> Tag {
        Tag(id: row.text("id") ?? "", name: row.text("name") ?? "", color: row.text("color") ?? "")
    }

    /// "" or "#RRGGBB" or a lower-case colour word of at most 20 letters.
    static func checkedColor(_ raw: String) throws -> String {
        let color = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if color.isEmpty { return "" }

        if color.hasPrefix("#") {
            let digits = color.dropFirst()
            if digits.count == 6, digits.allSatisfy({ $0.isHexDigit }) { return color.uppercased() }
            throw ModelError.invalidValue("colour")
        }
        if color.count <= 20, color.allSatisfy({ $0.isASCII && $0.isLowercase && $0.isLetter }) { return color }
        throw ModelError.invalidValue("colour")
    }
}
