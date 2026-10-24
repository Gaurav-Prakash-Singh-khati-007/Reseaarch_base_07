//
//  LinkStore.swift
//  ResearchBase
//
//  Phase 1, Step 1B (F-06)
//
//  The ONE place links live (AGENTS.md rule 4). Any record can link to any
//  other with a relation. One row is stored; it is seen from both sides:
//  `links(for:)` returns it for the "from" record as outgoing and for the
//  "to" record as incoming.
//
//    * A record cannot link to itself.
//    * Both ends must exist (a link to nothing is refused).
//    * Adding the same link twice returns the first one.
//    * "related" is symmetric: if B -> A (related) exists, A -> B (related)
//      is the same link and is not stored again.
//

import Foundation

final class LinkStore {

    unowned let model: LibraryModel

    init(model: LibraryModel) {
        self.model = model
    }

    // MARK: Add

    @discardableResult
    func add(from: LinkEnd, to: LinkEnd, rel: LinkRel = .related, note: String = "") throws -> ModelLink {

        guard from != to else { throw ModelError.linkToSelf }

        return try model.atomically {

            try requireExists(from)
            try requireExists(to)

            if let existing = try find(from: from, to: to, rel: rel) { return existing }
            if rel == .related, let reverse = try find(from: to, to: from, rel: rel) { return reverse }

            let id = model.newID()
            let now = model.now()

            try model.database.run(
                "INSERT INTO links (id, from_type, from_id, to_type, to_id, rel, note, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                [.text(id), .text(from.type.rawValue), .text(from.id), .text(to.type.rawValue), .text(to.id),
                 .text(rel.rawValue), .text(note), .text(now)]
            )

            let link = ModelLink(id: id, from: from, to: to, rel: rel, note: note, createdAt: now)
            try model.record("link", id, .create, field: "link", new: Self.snapshot(link))
            return link
        }
    }

    // MARK: Read

    /// Every link that touches `end`, from both sides, oldest first.
    /// Optionally only one relation.
    func links(for end: LinkEnd, rel: LinkRel? = nil) throws -> [LinkedEntry] {

        var sql = "SELECT * FROM links WHERE ((from_type = ? AND from_id = ?) OR (to_type = ? AND to_id = ?))"
        var params: [SQLValue] = [.text(end.type.rawValue), .text(end.id), .text(end.type.rawValue), .text(end.id)]
        if let rel {
            sql += " AND rel = ?"
            params.append(.text(rel.rawValue))
        }
        sql += " ORDER BY created_at, id"

        return try model.database.rows(sql, params).map { row in
            let link = try Self.link(from: row)
            if link.from == end {
                return LinkedEntry(link: link, other: link.to, direction: .outgoing)
            }
            return LinkedEntry(link: link, other: link.from, direction: .incoming)
        }
    }

    /// "Where is this used?": the records that link TO `end` (one indexed lookup).
    func usedBy(_ end: LinkEnd) throws -> [LinkEnd] {
        let rows = try model.database.rows(
            "SELECT * FROM links WHERE to_type = ? AND to_id = ? ORDER BY created_at, id",
            [.text(end.type.rawValue), .text(end.id)]
        )
        return try rows.map { try Self.link(from: $0).from }
    }

    func link(id: String) throws -> ModelLink? {
        guard let row = try model.database.rows("SELECT * FROM links WHERE id = ?", [.text(id)]).first else { return nil }
        return try Self.link(from: row)
    }

    func count(for end: LinkEnd) throws -> Int {
        Int(try model.database.scalarInt(
            "SELECT COUNT(*) FROM links WHERE (from_type = ? AND from_id = ?) OR (to_type = ? AND to_id = ?)",
            [.text(end.type.rawValue), .text(end.id), .text(end.type.rawValue), .text(end.id)]
        ) ?? 0)
    }

    // MARK: Edit and remove

    /// Changes the note on a link.
    @discardableResult
    func setNote(linkID: String, to note: String) throws -> ModelLink {
        try model.atomically {
            guard let existing = try link(id: linkID) else { throw ModelError.notFound(kind: "link", id: linkID) }
            if existing.note == note { return existing }

            try model.database.run("UPDATE links SET note = ? WHERE id = ?", [.text(note), .text(linkID)])
            try model.record("link", linkID, .update, field: "note", old: existing.note, new: note)

            return ModelLink(id: existing.id, from: existing.from, to: existing.to, rel: existing.rel,
                               note: note, createdAt: existing.createdAt)
        }
    }

    /// Removes a link. The schema has no deleted_at for links, so the full link is reported
    /// to the change sink; Step 1C can put it back.
    func remove(linkID: String) throws {
        try model.atomically {
            guard let existing = try link(id: linkID) else { throw ModelError.notFound(kind: "link", id: linkID) }
            try model.database.run("DELETE FROM links WHERE id = ?", [.text(linkID)])
            try model.record("link", linkID, .delete, field: "link", old: Self.snapshot(existing), new: nil)
        }
    }

    // MARK: Helpers

    private func find(from: LinkEnd, to: LinkEnd, rel: LinkRel) throws -> ModelLink? {
        guard let row = try model.database.rows(
            "SELECT * FROM links WHERE from_type = ? AND from_id = ? AND to_type = ? AND to_id = ? AND rel = ?",
            [.text(from.type.rawValue), .text(from.id), .text(to.type.rawValue), .text(to.id), .text(rel.rawValue)]
        ).first else { return nil }
        return try Self.link(from: row)
    }

    private func requireExists(_ end: LinkEnd) throws {
        // `end.type.table` comes from a fixed list in LinkEntity, never from user text.
        let found = try model.database.scalarInt(
            "SELECT 1 FROM \(end.type.table) WHERE id = ?", [.text(end.id)]
        )
        if found == nil {
            throw ModelError.linkTargetMissing(type: end.type.rawValue, id: end.id)
        }
    }

    static func link(from row: SQLRow) throws -> ModelLink {
        guard let id = row.text("id"),
              let fromTypeText = row.text("from_type"), let fromType = LinkEntity(rawValue: fromTypeText),
              let fromID = row.text("from_id"),
              let toTypeText = row.text("to_type"), let toType = LinkEntity(rawValue: toTypeText),
              let toID = row.text("to_id"),
              let relText = row.text("rel"), let rel = LinkRel(rawValue: relText) else {
            throw ModelError.invalidValue("link row")
        }
        return ModelLink(
            id: id,
            from: LinkEnd(fromType, fromID),
            to: LinkEnd(toType, toID),
            rel: rel,
            note: row.text("note") ?? "",
            createdAt: row.text("created_at") ?? ""
        )
    }

    private static func snapshot(_ link: ModelLink) -> String {
        LibraryModel.json([
            "id": link.id,
            "from_type": link.from.type.rawValue, "from_id": link.from.id,
            "to_type": link.to.type.rawValue, "to_id": link.to.id,
            "rel": link.rel.rawValue, "note": link.note, "created_at": link.createdAt
        ] as [String: Any])
    }
}
