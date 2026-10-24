//
//  DraftCommentStore.swift
//  ResearchBase
//
//  Owner: Agent 22 · Features: F-37
//
//  Margin comments and TODO markers in a draft (`draft_comments` table).
//  A comment sits on a line of one file of the draft; a TODO is the same
//  row with kind = 'todo'. The "unresolved list" is `unresolved(draftID:)`.
//
//  PUBLIC API
//    init(model: LibraryModel)                 (not yet a lazy var on LibraryModel; create it directly)
//    enum DraftCommentKind { comment, todo }
//    struct DraftComment, struct DraftCommentCounts
//    add(draftID:file:line:anchorText:kind:body:) -> DraftComment
//    comment(id:) -> DraftComment?
//    comments(draftID:file:kind:includeResolved:) -> [DraftComment]   (file, line, created order)
//    unresolved(draftID:kind:) -> [DraftComment]
//    counts(draftID:) -> DraftCommentCounts
//    edit(id:body:) / setResolved(id:_:) / move(id:toLine:)
//    shiftLines(draftID:file:fromLine:by:)     keep comments attached when lines are inserted / removed
//    renameFile(draftID:from:to:)
//    remove(id:) / removeResolved(draftID:)
//    scanTodoMarkers(in:file:) -> [TodoMarker] (pure)    finds "% TODO ..." and \todo{...}
//    addMissingTodoMarkers(draftID:file:text:) -> [DraftComment]
//
//  Rules
//    * The draft must exist (a comment on nothing is refused).
//    * Text cannot be empty; line starts at 1; file is a path inside the draft folder.
//    * Every public write runs in one transaction and is reported to the change sink.
//    * Comments are deleted for good (the table has no deleted_at); the old row is
//      reported to the sink so Step 1C can put it back. They go with their draft
//      (ON DELETE CASCADE).
//

import Foundation

enum DraftCommentKind: String, CaseIterable, Equatable {
    case comment
    case todo
}

struct DraftComment: Equatable, Identifiable {
    let id: String
    let draftID: String
    var file: String
    var line: Int
    var anchorText: String
    var kind: DraftCommentKind
    var body: String
    var resolved: Bool
    let createdAt: String
}

struct DraftCommentCounts: Equatable {
    var openComments = 0
    var openTodos = 0
    var resolved = 0
    var openTotal: Int { openComments + openTodos }
}

/// A TODO found in source text. `line` starts at 1.
struct TodoMarker: Equatable {
    let file: String
    let line: Int
    let text: String
    let anchorText: String
}

final class DraftCommentStore {

    unowned let model: LibraryModel

    init(model: LibraryModel) {
        self.model = model
    }

    // MARK: Add

    @discardableResult
    func add(
        draftID: String,
        file: String,
        line: Int,
        anchorText: String = "",
        kind: DraftCommentKind = .comment,
        body: String
    ) throws -> DraftComment {

        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ModelError.invalidValue("the comment text is empty") }
        guard line >= 1 else { throw ModelError.invalidValue("line numbers start at 1") }
        let path = try Self.cleanPath(file)

        return try model.atomically {

            try requireDraft(draftID)

            let comment = DraftComment(
                id: model.newID(), draftID: draftID, file: path, line: line,
                anchorText: anchorText, kind: kind, body: text,
                resolved: false, createdAt: model.now()
            )

            try model.database.run(
                "INSERT INTO draft_comments (id, draft_id, file, line, anchor_text, kind, body, resolved, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?)",
                [.text(comment.id), .text(draftID), .text(path), .int(Int64(line)), .text(anchorText),
                 .text(kind.rawValue), .text(text), .text(comment.createdAt)]
            )
            try model.record("draft_comment", comment.id, .create, field: "comment", new: Self.snapshot(comment))
            return comment
        }
    }

    // MARK: Read

    func comment(id: String) throws -> DraftComment? {
        guard let row = try model.database.rows("SELECT * FROM draft_comments WHERE id = ?", [.text(id)]).first else {
            return nil
        }
        return try Self.comment(from: row)
    }

    /// Comments of a draft in reading order: file, then line, then oldest first.
    func comments(
        draftID: String,
        file: String? = nil,
        kind: DraftCommentKind? = nil,
        includeResolved: Bool = true
    ) throws -> [DraftComment] {

        var sql = "SELECT * FROM draft_comments WHERE draft_id = ?"
        var params: [SQLValue] = [.text(draftID)]
        if let file {
            sql += " AND file = ?"
            params.append(.text(file))
        }
        if let kind {
            sql += " AND kind = ?"
            params.append(.text(kind.rawValue))
        }
        if !includeResolved { sql += " AND resolved = 0" }
        sql += " ORDER BY file, line, created_at, id"

        return try model.database.rows(sql, params).map { try Self.comment(from: $0) }
    }

    /// The "unresolved" list of the Comments and TODOs tab.
    func unresolved(draftID: String, kind: DraftCommentKind? = nil) throws -> [DraftComment] {
        try comments(draftID: draftID, kind: kind, includeResolved: false)
    }

    func counts(draftID: String) throws -> DraftCommentCounts {
        let rows = try model.database.rows(
            "SELECT kind, resolved, COUNT(*) AS n FROM draft_comments WHERE draft_id = ? GROUP BY kind, resolved",
            [.text(draftID)]
        )
        var result = DraftCommentCounts()
        for row in rows {
            let n = Int(row.int("n") ?? 0)
            if (row.int("resolved") ?? 0) != 0 {
                result.resolved += n
            } else if row.text("kind") == DraftCommentKind.todo.rawValue {
                result.openTodos += n
            } else {
                result.openComments += n
            }
        }
        return result
    }

    // MARK: Edit

    @discardableResult
    func edit(id: String, body: String) throws -> DraftComment {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ModelError.invalidValue("the comment text is empty") }

        return try model.atomically {
            let existing = try require(id)
            if existing.body == text { return existing }
            try model.database.run("UPDATE draft_comments SET body = ? WHERE id = ?", [.text(text), .text(id)])
            try model.record("draft_comment", id, .update, field: "body", old: existing.body, new: text)
            var changed = existing
            changed.body = text
            return changed
        }
    }

    @discardableResult
    func setResolved(id: String, _ resolved: Bool = true) throws -> DraftComment {
        try model.atomically {
            let existing = try require(id)
            if existing.resolved == resolved { return existing }
            try model.database.run(
                "UPDATE draft_comments SET resolved = ? WHERE id = ?", [LibraryModel.bool(resolved), .text(id)]
            )
            try model.record("draft_comment", id, .update, field: "resolved",
                             old: existing.resolved ? "1" : "0", new: resolved ? "1" : "0")
            var changed = existing
            changed.resolved = resolved
            return changed
        }
    }

    @discardableResult
    func move(id: String, toLine line: Int) throws -> DraftComment {
        guard line >= 1 else { throw ModelError.invalidValue("line numbers start at 1") }
        return try model.atomically {
            let existing = try require(id)
            if existing.line == line { return existing }
            try model.database.run("UPDATE draft_comments SET line = ? WHERE id = ?", [.int(Int64(line)), .text(id)])
            try model.record("draft_comment", id, .update, field: "line", old: String(existing.line), new: String(line))
            var changed = existing
            changed.line = line
            return changed
        }
    }

    /// Keeps comments on their text when the file changes: every comment of `file`
    /// on `fromLine` or below moves by `delta` (negative = lines were removed).
    /// A comment cannot move above line 1. Returns how many comments moved.
    @discardableResult
    func shiftLines(draftID: String, file: String, fromLine: Int, by delta: Int) throws -> Int {
        guard delta != 0 else { return 0 }
        return try model.atomically {
            let rows = try model.database.rows(
                "SELECT * FROM draft_comments WHERE draft_id = ? AND file = ? AND line >= ? ORDER BY line, id",
                [.text(draftID), .text(file), .int(Int64(fromLine))]
            )
            var moved = 0
            for row in rows {
                let existing = try Self.comment(from: row)
                let newLine = max(1, existing.line + delta)
                if newLine == existing.line { continue }
                try model.database.run(
                    "UPDATE draft_comments SET line = ? WHERE id = ?", [.int(Int64(newLine)), .text(existing.id)]
                )
                try model.record("draft_comment", existing.id, .update, field: "line",
                                 old: String(existing.line), new: String(newLine))
                moved += 1
            }
            return moved
        }
    }

    /// A file of the draft was renamed or moved: its comments follow it.
    @discardableResult
    func renameFile(draftID: String, from oldPath: String, to newPath: String) throws -> Int {
        let target = try Self.cleanPath(newPath)
        return try model.atomically {
            let rows = try model.database.rows(
                "SELECT * FROM draft_comments WHERE draft_id = ? AND file = ?", [.text(draftID), .text(oldPath)]
            )
            if oldPath == target { return 0 }
            for row in rows {
                let existing = try Self.comment(from: row)
                try model.database.run("UPDATE draft_comments SET file = ? WHERE id = ?", [.text(target), .text(existing.id)])
                try model.record("draft_comment", existing.id, .update, field: "file", old: oldPath, new: target)
            }
            return rows.count
        }
    }

    // MARK: Remove

    func remove(id: String) throws {
        try model.atomically {
            let existing = try require(id)
            try model.database.run("DELETE FROM draft_comments WHERE id = ?", [.text(id)])
            try model.record("draft_comment", id, .delete, field: "comment", old: Self.snapshot(existing), new: nil)
        }
    }

    /// "Clear resolved": deletes every resolved comment and TODO of the draft. Returns how many.
    @discardableResult
    func removeResolved(draftID: String) throws -> Int {
        try model.atomically {
            let rows = try model.database.rows(
                "SELECT * FROM draft_comments WHERE draft_id = ? AND resolved = 1", [.text(draftID)]
            )
            for row in rows {
                let existing = try Self.comment(from: row)
                try model.database.run("DELETE FROM draft_comments WHERE id = ?", [.text(existing.id)])
                try model.record("draft_comment", existing.id, .delete, field: "comment",
                                 old: Self.snapshot(existing), new: nil)
            }
            return rows.count
        }
    }

    // MARK: TODO markers in the text

    /// Finds `% TODO: text` comments and `\todo{text}` commands. Pure: touches nothing.
    static func scanTodoMarkers(in text: String, file: String) -> [TodoMarker] {
        var found: [TodoMarker] = []
        let lines = text.components(separatedBy: "\n")
        for (index, raw) in lines.enumerated() {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw

            if let range = line.range(of: #"(?<!\\)%\s*TODO\b[:\s-]*(.*)$"#, options: .regularExpression) {
                let marker = String(line[range])
                let body = marker.replacingOccurrences(
                    of: #"^%\s*TODO\b[:\s-]*"#, with: "", options: .regularExpression
                ).trimmingCharacters(in: .whitespaces)
                found.append(TodoMarker(file: file, line: index + 1,
                                        text: body.isEmpty ? "TODO" : body, anchorText: marker))
                continue
            }
            if let range = line.range(of: #"\\todo(?:\[[^\]]*\])?\{([^}]*)\}"#, options: .regularExpression) {
                let marker = String(line[range])
                let body = marker.replacingOccurrences(
                    of: #"^\\todo(?:\[[^\]]*\])?\{"#, with: "", options: .regularExpression
                ).dropLast().trimmingCharacters(in: .whitespaces)
                found.append(TodoMarker(file: file, line: index + 1,
                                        text: body.isEmpty ? "TODO" : body, anchorText: marker))
            }
        }
        return found
    }

    /// Adds a TODO row for every marker in `text` that has none yet (same file, line and text).
    /// Existing rows, resolved or not, are left alone. Returns the rows it added.
    @discardableResult
    func addMissingTodoMarkers(draftID: String, file: String, text: String) throws -> [DraftComment] {
        let markers = Self.scanTodoMarkers(in: text, file: file)
        return try model.atomically {
            let existing = try comments(draftID: draftID, file: file, kind: .todo)
            var added: [DraftComment] = []
            for marker in markers where !existing.contains(where: { $0.line == marker.line && $0.body == marker.text }) {
                added.append(try add(draftID: draftID, file: file, line: marker.line,
                                     anchorText: marker.anchorText, kind: .todo, body: marker.text))
            }
            return added
        }
    }

    // MARK: Helpers

    private func require(_ id: String) throws -> DraftComment {
        guard let found = try comment(id: id) else { throw ModelError.notFound(kind: "comment", id: id) }
        return found
    }

    private func requireDraft(_ draftID: String) throws {
        if try model.database.scalarInt("SELECT 1 FROM drafts WHERE id = ?", [.text(draftID)]) == nil {
            throw ModelError.notFound(kind: "draft", id: draftID)
        }
    }

    /// A relative path inside the draft folder: no leading slash, no "..".
    private static func cleanPath(_ file: String) throws -> String {
        let path = file.trimmingCharacters(in: .whitespaces)
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !path.isEmpty, !path.hasPrefix("/"), !parts.contains("..") else {
            throw ModelError.invalidValue("the file must be a path inside the draft")
        }
        return path
    }

    private static func comment(from row: SQLRow) throws -> DraftComment {
        guard let id = row.text("id"),
              let draftID = row.text("draft_id"),
              let file = row.text("file"),
              let line = row.int("line"),
              let kindText = row.text("kind"), let kind = DraftCommentKind(rawValue: kindText),
              let body = row.text("body") else {
            throw ModelError.invalidValue("comment row")
        }
        return DraftComment(
            id: id, draftID: draftID, file: file, line: Int(line),
            anchorText: row.text("anchor_text") ?? "", kind: kind, body: body,
            resolved: (row.int("resolved") ?? 0) != 0, createdAt: row.text("created_at") ?? ""
        )
    }

    private static func snapshot(_ c: DraftComment) -> String {
        LibraryModel.json([
            "id": c.id, "draft_id": c.draftID, "file": c.file, "line": c.line,
            "anchor_text": c.anchorText, "kind": c.kind.rawValue, "body": c.body,
            "resolved": c.resolved ? 1 : 0, "created_at": c.createdAt
        ] as [String: Any])
    }
}
