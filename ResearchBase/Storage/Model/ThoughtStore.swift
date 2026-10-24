//
//  ThoughtStore.swift
//  ResearchBase
//
//  Owner: Agent 17 · Features: F-44 (one kind of thought item)
//
//  Notes, findings, gaps, problems and ideas are ONE record type in the
//  `thoughts` table, told apart by a `kind` label. Changing the kind keeps
//  every field (a gap's `evidence` and a problem's `question` are kept even
//  if the kind changes, nothing is dropped).
//
//  Rules (same as the other stores):
//    * Every change is reported to the change sink field by field, inside
//      the same transaction.
//    * Removing a thought only sets `deleted_at` (Trash). `restore` undoes it.
//      Nothing is hard-deleted here.
//    * Links to papers, experiments, drafts and other thoughts live in the
//      one link table; this store only offers shortcuts over `LinkStore`.
//    * The full-text index (`fts_thought`) belongs to `SearchService`. After
//      `create` or `update`, the caller refreshes it with
//      `SearchService.indexThought(id:)`. Trashed thoughts are hidden by search itself.
//    * Not on `LibraryModel` (frozen). Create it with `ThoughtStore(model: model)`.
//
//  PUBLIC API
//    ThoughtKind        note | finding | gap | problem | idea
//    ThoughtStatus      open | exploring | done | dropped
//    Thought, NewThought, ThoughtSort
//    ThoughtStore(model:)
//      create(_:)                                   -> Thought
//      fetch(id:includeDeleted:)                    -> Thought?
//      list(kind:status:sort:limit:offset:)         -> [Thought]
//      count(kind:status:) / countsByKind()         -> Int / [ThoughtKind: Int]
//      update(id:_:)                                -> Thought
//      trash(id:) / restore(id:)
//      link(thoughtID:to:rel:note:)                 -> ModelLink
//      thoughts(linkedTo:)                          -> [Thought]   both directions, live thoughts only
//

import Foundation

// MARK: - Types

enum ThoughtKind: String, CaseIterable, Equatable {
    case note, finding, gap, problem, idea
}

enum ThoughtStatus: String, CaseIterable, Equatable {
    case open, exploring, done, dropped
}

enum ThoughtSort: Equatable {
    /// Last edited first.
    case recent
    /// Highest priority first, then last edited.
    case priority
}

struct Thought: Equatable {
    var id: String
    var kind: ThoughtKind
    var title: String
    /// Markdown.
    var body: String
    var status: ThoughtStatus
    var priority: Int
    /// What shows the gap (used by gaps).
    var evidence: String
    /// The research question (used by problems).
    var question: String
    var createdAt: String
    var updatedAt: String
    var deletedAt: String?
}

struct NewThought {
    var kind: ThoughtKind = .note
    var title: String
    var body: String = ""
    var status: ThoughtStatus = .open
    var priority: Int = 0
    var evidence: String = ""
    var question: String = ""
}

// MARK: - Store

final class ThoughtStore {

    unowned let model: LibraryModel

    init(model: LibraryModel) {
        self.model = model
    }

    private var db: LibraryDatabase { model.database }

    // MARK: Create

    @discardableResult
    func create(_ new: NewThought) throws -> Thought {

        let title = new.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ModelError.emptyName }
        guard new.priority >= 0 else { throw ModelError.invalidValue("priority") }

        return try model.atomically {

            let id = model.newID()
            let now = model.now()

            try db.run(
                """
                INSERT INTO thoughts (id, kind, title, body, status, priority, evidence, question, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [.text(id), .text(new.kind.rawValue), .text(title), .text(new.body), .text(new.status.rawValue),
                 .int(Int64(new.priority)), .text(new.evidence), .text(new.question), .text(now), .text(now)]
            )

            try model.record("thought", id, .create, field: "title", new: title)

            guard let created = try fetch(id: id) else { throw ModelError.notFound(kind: "note", id: id) }
            return created
        }
    }

    // MARK: Read

    /// Thoughts in the Trash are only returned with `includeDeleted: true`.
    func fetch(id: String, includeDeleted: Bool = false) throws -> Thought? {
        let sql = "SELECT * FROM thoughts WHERE id = ?" + (includeDeleted ? "" : " AND deleted_at IS NULL")
        guard let row = try db.rows(sql, [.text(id)]).first else { return nil }
        return try Self.thought(from: row)
    }

    func list(
        kind: ThoughtKind? = nil,
        status: ThoughtStatus? = nil,
        sort: ThoughtSort = .recent,
        limit: Int = 200,
        offset: Int = 0
    ) throws -> [Thought] {

        var sql = "SELECT * FROM thoughts WHERE deleted_at IS NULL"
        var params: [SQLValue] = []

        if let kind {
            sql += " AND kind = ?"
            params.append(.text(kind.rawValue))
        }
        if let status {
            sql += " AND status = ?"
            params.append(.text(status.rawValue))
        }
        sql += sort == .priority ? " ORDER BY priority DESC, updated_at DESC, id" : " ORDER BY updated_at DESC, id"
        sql += " LIMIT ? OFFSET ?"
        params.append(.int(Int64(max(limit, 0))))
        params.append(.int(Int64(max(offset, 0))))

        return try db.rows(sql, params).map { try Self.thought(from: $0) }
    }

    func count(kind: ThoughtKind? = nil, status: ThoughtStatus? = nil) throws -> Int {

        var sql = "SELECT COUNT(*) FROM thoughts WHERE deleted_at IS NULL"
        var params: [SQLValue] = []

        if let kind {
            sql += " AND kind = ?"
            params.append(.text(kind.rawValue))
        }
        if let status {
            sql += " AND status = ?"
            params.append(.text(status.rawValue))
        }
        return Int(try db.scalarInt(sql, params) ?? 0)
    }

    /// For the filter chips: every kind is present, with 0 when empty.
    func countsByKind() throws -> [ThoughtKind: Int] {
        var result = Dictionary(uniqueKeysWithValues: ThoughtKind.allCases.map { ($0, 0) })
        for row in try db.rows("SELECT kind, COUNT(*) AS n FROM thoughts WHERE deleted_at IS NULL GROUP BY kind") {
            if let text = row.text("kind"), let kind = ThoughtKind(rawValue: text) {
                result[kind] = Int(row.int("n") ?? 0)
            }
        }
        return result
    }

    // MARK: Edit

    /// Edits a thought. `change` receives a copy; whatever it changes is saved, field by field,
    /// and each changed field is reported to the change sink with old and new value.
    /// Not editable here: id, created date, deleted date (use `trash` / `restore`).
    @discardableResult
    func update(id: String, _ change: (inout Thought) -> Void) throws -> Thought {

        try model.atomically {

            guard let before = try fetch(id: id) else {
                throw ModelError.notFound(kind: "note", id: id)
            }

            var after = before
            change(&after)

            if after.id != before.id || after.createdAt != before.createdAt || after.deletedAt != before.deletedAt {
                throw ModelError.invalidValue("id, created date and deleted date cannot be edited here")
            }

            after.title = after.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !after.title.isEmpty else { throw ModelError.emptyName }
            guard after.priority >= 0 else { throw ModelError.invalidValue("priority") }

            let fields: [(name: String, old: String, new: String)] = [
                ("kind", before.kind.rawValue, after.kind.rawValue),
                ("title", before.title, after.title),
                ("body", before.body, after.body),
                ("status", before.status.rawValue, after.status.rawValue),
                ("priority", String(before.priority), String(after.priority)),
                ("evidence", before.evidence, after.evidence),
                ("question", before.question, after.question)
            ].filter { $0.old != $0.new }

            if fields.isEmpty { return before }

            after.updatedAt = model.now()

            try db.run(
                """
                UPDATE thoughts SET kind = ?, title = ?, body = ?, status = ?, priority = ?,
                       evidence = ?, question = ?, updated_at = ? WHERE id = ?
                """,
                [.text(after.kind.rawValue), .text(after.title), .text(after.body), .text(after.status.rawValue),
                 .int(Int64(after.priority)), .text(after.evidence), .text(after.question),
                 .text(after.updatedAt), .text(id)]
            )

            for field in fields {
                try model.record("thought", id, .update, field: field.name, old: field.old, new: field.new)
            }
            return after
        }
    }

    // MARK: Trash

    func trash(id: String) throws {
        try model.atomically {
            guard try fetch(id: id) != nil else { throw ModelError.notFound(kind: "note", id: id) }
            let now = model.now()
            try db.run("UPDATE thoughts SET deleted_at = ?, updated_at = ? WHERE id = ?", [.text(now), .text(now), .text(id)])
            try model.record("thought", id, .delete, field: "deleted_at", old: nil, new: now)
        }
    }

    func restore(id: String) throws {
        try model.atomically {
            guard let current = try fetch(id: id, includeDeleted: true) else {
                throw ModelError.notFound(kind: "note", id: id)
            }
            guard let deletedAt = current.deletedAt else { return }
            try db.run("UPDATE thoughts SET deleted_at = NULL, updated_at = ? WHERE id = ?", [.text(model.now()), .text(id)])
            try model.record("thought", id, .restore, field: "deleted_at", old: deletedAt, new: nil)
        }
    }

    // MARK: Links (shortcuts over LinkStore)

    /// Links this thought to a paper, experiment, draft, project, task, review, collection or another thought.
    @discardableResult
    func link(thoughtID: String, to end: LinkEnd, rel: LinkRel = .related, note: String = "") throws -> ModelLink {
        guard try fetch(id: thoughtID) != nil else { throw ModelError.notFound(kind: "note", id: thoughtID) }
        return try model.links.add(from: LinkEnd(.thought, thoughtID), to: end, rel: rel, note: note)
    }

    /// The live thoughts linked to a record, from either side, oldest link first
    /// (for the paper's Notes tab and for "where is this used?").
    func thoughts(linkedTo end: LinkEnd) throws -> [Thought] {

        var seen = Set<String>()
        var result: [Thought] = []

        for entry in try model.links.links(for: end) where entry.other.type == .thought {
            guard seen.insert(entry.other.id).inserted, let thought = try fetch(id: entry.other.id) else { continue }
            result.append(thought)
        }
        return result
    }

    // MARK: Row mapping

    static func thought(from row: SQLRow) throws -> Thought {
        guard let id = row.text("id"),
              let kindText = row.text("kind"), let kind = ThoughtKind(rawValue: kindText),
              let title = row.text("title"),
              let statusText = row.text("status"), let status = ThoughtStatus(rawValue: statusText) else {
            throw ModelError.invalidValue("thought row")
        }
        return Thought(
            id: id,
            kind: kind,
            title: title,
            body: row.text("body") ?? "",
            status: status,
            priority: Int(row.int("priority") ?? 0),
            evidence: row.text("evidence") ?? "",
            question: row.text("question") ?? "",
            createdAt: row.text("created_at") ?? "",
            updatedAt: row.text("updated_at") ?? "",
            deletedAt: row.text("deleted_at")
        )
    }
}
