//
//  AnnotationStore.swift
//  ResearchBase
//
//  Owner: Agent 15 · Features: F-26 (highlights stay in the database), F-27 (store side)
//
//  Highlights, underlines, area boxes and page notes for a PDF attachment,
//  kept in the `annotations` table. The PDF file is never rewritten.
//  A marked-up PDF copy is made only on request, by the reader, from
//  what this store returns.
//
//  Rules (same as the other stores):
//    * Every change is reported to the change sink field by field, inside
//      the same transaction.
//    * Removing an annotation only sets `deleted_at` (Trash). Nothing is
//      hard-deleted here. `restore` brings it back.
//    * Rectangles are PDF points, stored as [[x, y, width, height], ...].
//    * The store is not on `LibraryModel` (that file is frozen). Create it
//      with `AnnotationStore(model: model)`.
//
//  PUBLIC API
//    AnnotationKind               highlight | underline | area | note
//    AnnotationRect               x, y, width, height (PDF points)
//    Annotation, NewAnnotation    value types
//    AnnotationStore(model:)
//      create(_:)                                     -> Annotation
//      fetch(id:includeDeleted:)                      -> Annotation?
//      list(attachmentID:page:kind:)                  -> [Annotation]   one PDF, page order
//      list(itemID:)                                  -> [Annotation]   every PDF of a paper (F-10 + F-26 tab)
//      count(attachmentID:) / count(itemID:)          -> Int
//      update(id:_:)                                  -> Annotation     color, comment, quote, page, rects
//      trash(id:) / restore(id:)
//      markdown(attachmentID:)                        -> String         for "send to note" (F-27)
//      static rects(from:) / encode(rects:)           helpers for the reader
//

import Foundation

// MARK: - Types

enum AnnotationKind: String, CaseIterable, Equatable {
    case highlight, underline, area, note
}

/// A box on a PDF page, in PDF points.
struct AnnotationRect: Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct Annotation: Equatable {
    var id: String
    var attachmentID: String
    var kind: AnnotationKind
    var color: String
    var page: Int
    var rects: [AnnotationRect]
    var quote: String
    var comment: String
    var createdAt: String
    var updatedAt: String
    var deletedAt: String?
}

struct NewAnnotation {
    var attachmentID: String
    var kind: AnnotationKind = .highlight
    var color: String = "yellow"
    var page: Int
    var rects: [AnnotationRect] = []
    var quote: String = ""
    var comment: String = ""
}

// MARK: - Store

final class AnnotationStore {

    unowned let model: LibraryModel

    init(model: LibraryModel) {
        self.model = model
    }

    private var db: LibraryDatabase { model.database }

    // MARK: Create

    @discardableResult
    func create(_ new: NewAnnotation) throws -> Annotation {

        let color = new.color.trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.validate(kind: new.kind, color: color, page: new.page, rects: new.rects)

        return try model.atomically {

            guard try db.scalarInt(
                "SELECT COUNT(*) FROM attachments WHERE id = ? AND deleted_at IS NULL", [.text(new.attachmentID)]
            ) == 1 else {
                throw ModelError.notFound(kind: "file", id: new.attachmentID)
            }

            let id = model.newID()
            let now = model.now()

            try db.run(
                """
                INSERT INTO annotations (id, attachment_id, kind, color, page, rects_json, quote, comment, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [.text(id), .text(new.attachmentID), .text(new.kind.rawValue), .text(color), .int(Int64(new.page)),
                 .text(Self.encode(rects: new.rects)), .text(new.quote), .text(new.comment), .text(now), .text(now)]
            )

            try model.record("annotation", id, .create, field: new.kind.rawValue, new: "page \(new.page)")

            guard let created = try fetch(id: id) else { throw ModelError.notFound(kind: "annotation", id: id) }
            return created
        }
    }

    // MARK: Read

    func fetch(id: String, includeDeleted: Bool = false) throws -> Annotation? {
        let sql = "SELECT * FROM annotations WHERE id = ?" + (includeDeleted ? "" : " AND deleted_at IS NULL")
        guard let row = try db.rows(sql, [.text(id)]).first else { return nil }
        return try Self.annotation(from: row)
    }

    /// One PDF, in reading order (page, then creation time). Trash is never listed.
    func list(attachmentID: String, page: Int? = nil, kind: AnnotationKind? = nil) throws -> [Annotation] {

        var sql = "SELECT * FROM annotations WHERE attachment_id = ? AND deleted_at IS NULL"
        var params: [SQLValue] = [.text(attachmentID)]

        if let page {
            sql += " AND page = ?"
            params.append(.int(Int64(page)))
        }
        if let kind {
            sql += " AND kind = ?"
            params.append(.text(kind.rawValue))
        }
        sql += " ORDER BY page, created_at, id"

        return try db.rows(sql, params).map { try Self.annotation(from: $0) }
    }

    /// Every annotation on every file of a paper: the primary file first, then by page.
    func list(itemID: String) throws -> [Annotation] {
        try db.rows(
            """
            SELECT n.* FROM annotations n JOIN attachments a ON a.id = n.attachment_id
            WHERE a.item_id = ? AND a.deleted_at IS NULL AND n.deleted_at IS NULL
            ORDER BY a.is_primary DESC, a.added_at, a.id, n.page, n.created_at, n.id
            """, [.text(itemID)]
        ).map { try Self.annotation(from: $0) }
    }

    func count(attachmentID: String) throws -> Int {
        Int(try db.scalarInt(
            "SELECT COUNT(*) FROM annotations WHERE attachment_id = ? AND deleted_at IS NULL", [.text(attachmentID)]) ?? 0)
    }

    func count(itemID: String) throws -> Int {
        Int(try db.scalarInt(
            """
            SELECT COUNT(*) FROM annotations n JOIN attachments a ON a.id = n.attachment_id
            WHERE a.item_id = ? AND a.deleted_at IS NULL AND n.deleted_at IS NULL
            """, [.text(itemID)]) ?? 0)
    }

    // MARK: Edit

    /// Changes color, comment, quote, page or rectangles. Kind and attachment cannot change.
    /// Each changed field is reported to the change sink with old and new value.
    @discardableResult
    func update(id: String, _ change: (inout Annotation) -> Void) throws -> Annotation {

        try model.atomically {

            guard let before = try fetch(id: id) else {
                throw ModelError.notFound(kind: "annotation", id: id)
            }

            var after = before
            change(&after)

            if after.id != before.id || after.attachmentID != before.attachmentID || after.kind != before.kind
                || after.createdAt != before.createdAt || after.deletedAt != before.deletedAt {
                throw ModelError.invalidValue("id, file, kind, created date and deleted date cannot be edited here")
            }

            after.color = after.color.trimmingCharacters(in: .whitespacesAndNewlines)
            try Self.validate(kind: after.kind, color: after.color, page: after.page, rects: after.rects)

            guard after != before else { return before }

            after.updatedAt = model.now()

            try db.run(
                "UPDATE annotations SET color = ?, page = ?, rects_json = ?, quote = ?, comment = ?, updated_at = ? WHERE id = ?",
                [.text(after.color), .int(Int64(after.page)), .text(Self.encode(rects: after.rects)),
                 .text(after.quote), .text(after.comment), .text(after.updatedAt), .text(id)]
            )

            if before.color != after.color { try model.record("annotation", id, .update, field: "color", old: before.color, new: after.color) }
            if before.page != after.page { try model.record("annotation", id, .update, field: "page", old: String(before.page), new: String(after.page)) }
            if before.rects != after.rects { try model.record("annotation", id, .update, field: "rects", old: Self.encode(rects: before.rects), new: Self.encode(rects: after.rects)) }
            if before.quote != after.quote { try model.record("annotation", id, .update, field: "quote", old: before.quote, new: after.quote) }
            if before.comment != after.comment { try model.record("annotation", id, .update, field: "comment", old: before.comment, new: after.comment) }

            return after
        }
    }

    // MARK: Trash

    /// Moves an annotation to the Trash (sets `deleted_at`). Nothing is erased.
    func trash(id: String) throws {
        try model.atomically {
            guard try fetch(id: id) != nil else { throw ModelError.notFound(kind: "annotation", id: id) }
            let now = model.now()
            try db.run("UPDATE annotations SET deleted_at = ?, updated_at = ? WHERE id = ?", [.text(now), .text(now), .text(id)])
            try model.record("annotation", id, .delete, field: "deleted_at", old: nil, new: now)
        }
    }

    func restore(id: String) throws {
        try model.atomically {
            guard let current = try fetch(id: id, includeDeleted: true) else {
                throw ModelError.notFound(kind: "annotation", id: id)
            }
            guard let deletedAt = current.deletedAt else { return }
            try db.run("UPDATE annotations SET deleted_at = NULL, updated_at = ? WHERE id = ?", [.text(model.now()), .text(id)])
            try model.record("annotation", id, .restore, field: "deleted_at", old: deletedAt, new: nil)
        }
    }

    // MARK: Send to note (F-27)

    /// Quotes and comments of one PDF as Markdown, in page order, ready to paste into a note.
    func markdown(attachmentID: String) throws -> String {

        var lines: [String] = []

        for annotation in try list(attachmentID: attachmentID) {
            var entry = "- p. \(annotation.page)"
            if annotation.kind == .area { entry += " (area)" }
            if !annotation.quote.isEmpty {
                let quote = annotation.quote.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
                entry += ": “\(quote)”"
            }
            if !annotation.comment.isEmpty {
                let comment = annotation.comment.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
                entry += annotation.quote.isEmpty ? ": \(comment)" : "\n  - \(comment)"
            }
            lines.append(entry)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Rectangle helpers (public so the reader uses the same format)

    static func encode(rects: [AnnotationRect]) -> String {
        let array = rects.map { [$0.x, $0.y, $0.width, $0.height] }
        guard let data = try? JSONSerialization.data(withJSONObject: array, options: []),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    /// Reads `[[x,y,w,h], ...]`. Anything malformed gives an empty list.
    static func rects(from json: String) -> [AnnotationRect] {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[NSNumber]] else { return [] }
        return array.compactMap { numbers in
            guard numbers.count == 4 else { return nil }
            let values = numbers.map { $0.doubleValue }
            return AnnotationRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
    }

    // MARK: Private

    private static func validate(kind: AnnotationKind, color: String, page: Int, rects: [AnnotationRect]) throws {

        guard page >= 1 else { throw ModelError.invalidValue("page") }
        guard !color.isEmpty else { throw ModelError.invalidValue("color") }

        for rect in rects {
            let values = [rect.x, rect.y, rect.width, rect.height]
            guard values.allSatisfy({ $0.isFinite }), rect.width >= 0, rect.height >= 0 else {
                throw ModelError.invalidValue("rectangle")
            }
        }
        // Marks that cover text or an area need a box; a page note may have none.
        if kind != .note, rects.isEmpty {
            throw ModelError.invalidValue("rectangle")
        }
    }

    static func annotation(from row: SQLRow) throws -> Annotation {
        guard let id = row.text("id"),
              let attachmentID = row.text("attachment_id"),
              let kindText = row.text("kind"),
              let kind = AnnotationKind(rawValue: kindText),
              let page = row.int("page") else {
            throw ModelError.invalidValue("annotation row")
        }
        return Annotation(
            id: id,
            attachmentID: attachmentID,
            kind: kind,
            color: row.text("color") ?? "yellow",
            page: Int(page),
            rects: rects(from: row.text("rects_json") ?? "[]"),
            quote: row.text("quote") ?? "",
            comment: row.text("comment") ?? "",
            createdAt: row.text("created_at") ?? "",
            updatedAt: row.text("updated_at") ?? "",
            deletedAt: row.text("deleted_at")
        )
    }
}
