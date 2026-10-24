//
//  ItemStore.swift
//  ResearchBase
//
//  Phase 1, Step 1B (F-07, F-14)
//
//  Creating, reading and editing items (papers, books, web pages ...).
//  Every edit is reported to the change sink field by field.
//  Nothing here deletes an item; the Trash is Step 1C.
//

import Foundation

final class ItemStore {

    unowned let model: LibraryModel

    init(model: LibraryModel) {
        self.model = model
    }

    // MARK: Create

    /// Creates an item, its creator list and its citation key in one transaction.
    /// F-14: it records where the item came from (source kind and URL), when (captured_at) and its inbox state.
    @discardableResult
    func create(_ new: NewItem) throws -> ModelItem {

        let title = new.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ModelError.emptyName }

        if let year = new.year, !(0...9999).contains(year) {
            throw ModelError.invalidValue("year")
        }

        return try model.atomically {

            let id = model.newID()
            let now = model.now()

            let firstAuthor = new.creators.first(where: { $0.role == .author }) ?? new.creators.first
            let key = try model.citationKeys.generate(firstCreator: firstAuthor, year: new.year, title: title)

            try model.database.run(
                """
                INSERT INTO items (
                    id, item_type, title, abstract, venue, year, volume, issue, pages, publisher,
                    doi, arxiv_id, url, citation_key, source_url, source_kind, captured_at,
                    review_state, added_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(id), .text(new.type.rawValue), .text(title), .text(new.abstract), .text(new.venue),
                    LibraryModel.int(new.year), .text(new.volume), .text(new.issue), .text(new.pages),
                    .text(new.publisher),
                    LibraryModel.text(TextNormalizer.doi(new.doi)),
                    LibraryModel.text(TextNormalizer.arxivID(new.arxivID)),
                    .text(new.url), .text(key), .text(new.sourceURL), .text(new.sourceKind.rawValue),
                    .text(now), .text(new.reviewState.rawValue), .text(now), .text(now)
                ]
            )

            try model.creators.setCreators(itemID: id, new.creators)
            try model.record("item", id, .create, field: "title", new: title)

            guard let created = try fetch(id: id) else {
                throw ModelError.notFound(kind: "paper", id: id)
            }
            return created
        }
    }

    // MARK: Read

    /// One item. Items in the Trash are only returned with `includeDeleted: true`.
    func fetch(id: String, includeDeleted: Bool = false) throws -> ModelItem? {
        let sql = "SELECT * FROM items WHERE id = ?" + (includeDeleted ? "" : " AND deleted_at IS NULL")
        guard let row = try model.database.rows(sql, [.text(id)]).first else { return nil }
        return try Self.item(from: row)
    }

    /// Newest first. Items in the Trash are never listed here.
    func list(reviewState: ReviewState? = nil, limit: Int = 200, offset: Int = 0) throws -> [ModelItem] {
        var sql = "SELECT * FROM items WHERE deleted_at IS NULL"
        var params: [SQLValue] = []
        if let reviewState {
            sql += " AND review_state = ?"
            params.append(.text(reviewState.rawValue))
        }
        sql += " ORDER BY added_at DESC, id LIMIT ? OFFSET ?"
        params.append(.int(Int64(limit)))
        params.append(.int(Int64(offset)))
        return try model.database.rows(sql, params).map { try Self.item(from: $0) }
    }

    func count(reviewState: ReviewState? = nil) throws -> Int {
        if let reviewState {
            return Int(try model.database.scalarInt(
                "SELECT COUNT(*) FROM items WHERE deleted_at IS NULL AND review_state = ?",
                [.text(reviewState.rawValue)]) ?? 0)
        }
        return Int(try model.database.scalarInt("SELECT COUNT(*) FROM items WHERE deleted_at IS NULL") ?? 0)
    }

    // MARK: Edit

    /// Edits an item. `change` receives a copy; whatever it changes is saved, field by field,
    /// and each changed field is reported to the change sink with old and new value.
    ///
    /// Not editable here: id, citation key and its lock (use `CitationKeyStore`), added date,
    /// deleted date. Changing the item type keeps every field's value (nothing is dropped).
    @discardableResult
    func update(id: String, _ change: (inout ModelItem) -> Void) throws -> ModelItem {

        try model.atomically {

            guard let before = try fetch(id: id) else {
                throw ModelError.notFound(kind: "paper", id: id)
            }

            var after = before
            change(&after)

            if after.id != before.id
                || after.citationKey != before.citationKey
                || after.keyLocked != before.keyLocked
                || after.addedAt != before.addedAt
                || after.deletedAt != before.deletedAt {
                throw ModelError.invalidValue("id, citation key, lock, added date and deleted date cannot be edited here")
            }

            after.title = after.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !after.title.isEmpty else { throw ModelError.emptyName }
            guard (0...5).contains(after.rating) else { throw ModelError.invalidValue("rating") }
            if let year = after.year, !(0...9999).contains(year) { throw ModelError.invalidValue("year") }

            after.doi = TextNormalizer.doi(after.doi)
            after.arxivID = TextNormalizer.arxivID(after.arxivID)

            let oldValues = Self.editableValues(before)
            let newValues = Self.editableValues(after)

            var changed: [(column: String, old: SQLValue, new: SQLValue)] = []
            for (old, new) in zip(oldValues, newValues) where old.value != new.value {
                changed.append((old.column, old.value, new.value))
            }

            if changed.isEmpty { return before }

            let assignments = changed.map { "\($0.column) = ?" }.joined(separator: ", ")
            let now = model.now()
            try model.database.run(
                "UPDATE items SET \(assignments), updated_at = ? WHERE id = ?",
                changed.map { $0.new } + [.text(now), .text(id)]
            )

            for entry in changed {
                try model.record(
                    "item", id, .update,
                    field: entry.column,
                    old: Self.display(entry.old),
                    new: Self.display(entry.new)
                )
            }

            after.updatedAt = now
            return after
        }
    }

    // MARK: Row mapping

    static func item(from row: SQLRow) throws -> ModelItem {

        func requiredText(_ name: String) throws -> String {
            guard let value = row.text(name) else { throw ModelError.invalidValue("missing \(name)") }
            return value
        }

        let typeText = try requiredText("item_type")
        guard let type = ItemType(rawValue: typeText) else { throw ModelError.invalidValue("item type \(typeText)") }

        let sourceText = try requiredText("source_kind")
        guard let source = SourceKind(rawValue: sourceText) else { throw ModelError.invalidValue("source \(sourceText)") }

        let reviewText = try requiredText("review_state")
        guard let review = ReviewState(rawValue: reviewText) else { throw ModelError.invalidValue("review state \(reviewText)") }

        let statusText = try requiredText("reading_status")
        guard let status = ItemReadingStatus(rawValue: statusText) else { throw ModelError.invalidValue("reading status \(statusText)") }

        return ModelItem(
            id: try requiredText("id"),
            type: type,
            title: try requiredText("title"),
            abstract: row.text("abstract") ?? "",
            venue: row.text("venue") ?? "",
            year: row.int("year").map { Int($0) },
            month: row.text("month") ?? "",
            volume: row.text("volume") ?? "",
            issue: row.text("issue") ?? "",
            pages: row.text("pages") ?? "",
            publisher: row.text("publisher") ?? "",
            edition: row.text("edition") ?? "",
            doi: row.text("doi"),
            arxivID: row.text("arxiv_id"),
            url: row.text("url") ?? "",
            citationKey: try requiredText("citation_key"),
            keyLocked: (row.int("key_locked") ?? 0) != 0,
            readingStatus: status,
            inQueue: (row.int("in_queue") ?? 0) != 0,
            rating: Int(row.int("rating") ?? 0),
            language: row.text("language") ?? "",
            sourceURL: row.text("source_url") ?? "",
            sourceKind: source,
            capturedAt: row.text("captured_at"),
            reviewState: review,
            addedAt: try requiredText("added_at"),
            updatedAt: try requiredText("updated_at"),
            deletedAt: row.text("deleted_at")
        )
    }

    /// The columns `update` may write, in a fixed order.
    private static func editableValues(_ item: ModelItem) -> [(column: String, value: SQLValue)] {
        [
            ("item_type", .text(item.type.rawValue)),
            ("title", .text(item.title)),
            ("abstract", .text(item.abstract)),
            ("venue", .text(item.venue)),
            ("year", LibraryModel.int(item.year)),
            ("month", .text(item.month)),
            ("volume", .text(item.volume)),
            ("issue", .text(item.issue)),
            ("pages", .text(item.pages)),
            ("publisher", .text(item.publisher)),
            ("edition", .text(item.edition)),
            ("doi", LibraryModel.text(item.doi)),
            ("arxiv_id", LibraryModel.text(item.arxivID)),
            ("url", .text(item.url)),
            ("reading_status", .text(item.readingStatus.rawValue)),
            ("in_queue", LibraryModel.bool(item.inQueue)),
            ("rating", .int(Int64(item.rating))),
            ("language", .text(item.language)),
            ("source_url", .text(item.sourceURL)),
            ("source_kind", .text(item.sourceKind.rawValue)),
            ("captured_at", LibraryModel.text(item.capturedAt)),
            ("review_state", .text(item.reviewState.rawValue))
        ]
    }

    private static func display(_ value: SQLValue) -> String? {
        switch value {
        case .null: return nil
        case .int(let number): return String(number)
        case .double(let number): return String(number)
        case .text(let text): return text
        case .blob: return nil
        }
    }
}
