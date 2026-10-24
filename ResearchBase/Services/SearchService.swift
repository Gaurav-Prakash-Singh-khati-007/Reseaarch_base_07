//
//  SearchService.swift
//  ResearchBase
//
//  Owner: Agent 14 · Features: F-22 (full-text search), F-24 (fast at scale)
//
//  Full-text search over the four FTS5 tables of the frozen schema:
//  fts_items, fts_pdf, fts_thought, fts_draft.
//
//  How the tables work (they are CONTENTLESS: content=''):
//  FTS5 stores only the search index, never the text, so column values
//  cannot be read back and `snippet()` / `highlight()` return NULL. Every
//  row is therefore tied to its real record by ROWID:
//
//      fts_items    rowid = items.rowid
//      fts_thought  rowid = thoughts.rowid
//      fts_pdf      rowid = attachments.rowid * 100_000 + page        (page 1...99_999)
//      fts_draft    rowid = drafts.rowid * 1_000_000 + file slot      (file slot = hash of the file name)
//
//  Deleting one row of a contentless table needs the exact old values, so for
//  items and thoughts this file keeps a small shadow copy of what it indexed
//  in the `meta` table (keys `fts_items.<rowid>` and `fts_thought.<rowid>`).
//  PDF and draft rows are add-only here (see `indexPDF`).
//
//  Rowids are stable unless someone runs VACUUM on the database; nothing in
//  the app does. If it ever happens, call `rebuildItems()` / `rebuildThoughts()`.
//
//  PUBLIC API
//    SearchService(model: LibraryModel)
//    SearchService.ftsQuery(_:columns:prefixLast:) -> ParsedQuery?   (pure, safe for any user text)
//    Query (all hide Trash; items hide Inbox unless `includeInbox`):
//      searchItems(_:options:)     -> SearchPage<ItemHit>     title, authors, abstract, tags, venue
//      searchPDF(_:options:)       -> SearchPage<PDFHit>      attachment + page
//      searchThoughts(_:options:)  -> SearchPage<ThoughtHit>
//      searchDrafts(_:options:)    -> SearchPage<DraftHit>    draft level (file is nil, see BLOCKED in report)
//      searchAll(_:limitPerKind:includeInbox:) -> SearchResults
//      suggestTitles(prefix:limit:) -> [ItemHit]               for the command palette, as-you-type
//      items(for:) -> [ModelItem]                             full records for a page of ItemHit
//    Indexing:
//      indexItem(id:) / removeItem(id:) / rebuildItems()
//      indexThought(id:) / removeThought(id:) / rebuildThoughts()
//      indexPDF(attachmentID:pages:) / resetPDFIndex()
//      indexDraftFile(draftID:file:text:) / resetDraftIndex()
//      static pdfRowID(attachmentRowID:page:), decodePDFRowID(_:), draftRowID(draftRowID:file:)
//

import Foundation

// MARK: - Result types

struct SearchOptions {
    var limit: Int = 50
    var offset: Int = 0
    /// Items still waiting in the Inbox are hidden unless this is true.
    var includeInbox: Bool = false
}

/// One page of hits. `total` is counted up to `SearchService.countCap` so a huge library stays fast.
struct SearchPage<Hit> {
    var hits: [Hit]
    var total: Int
    var totalIsCapped: Bool
}

struct ItemHit: Equatable {
    var itemID: String
    var title: String
    var year: Int?
    var snippet: String
    /// Lower is better (FTS5 bm25).
    var score: Double
}

struct PDFHit: Equatable {
    var attachmentID: String
    var itemID: String
    var itemTitle: String
    var page: Int
    var score: Double
}

struct ThoughtHit: Equatable {
    var thoughtID: String
    var kind: String
    var title: String
    var snippet: String
    var score: Double
}

struct DraftHit: Equatable {
    var draftID: String
    var title: String
    /// Always nil today: the schema cannot store the file name of a contentless row.
    var file: String?
    var score: Double
}

struct SearchResults {
    var items: [ItemHit]
    var pdf: [PDFHit]
    var thoughts: [ThoughtHit]
    var drafts: [DraftHit]

    var isEmpty: Bool { items.isEmpty && pdf.isEmpty && thoughts.isEmpty && drafts.isEmpty }
}

struct ParsedQuery: Equatable {
    /// Safe FTS5 MATCH expression.
    var match: String
    /// Plain words the user typed, used to cut snippets.
    var terms: [String]
}

// MARK: - Service

final class SearchService {

    /// Counting stops here, so "how many results" never scans a whole big library.
    static let countCap = 5_000

    private static let pdfPageSpan: Int64 = 100_000
    private static let draftFileSpan: Int64 = 1_000_000

    unowned let model: LibraryModel

    init(model: LibraryModel) {
        self.model = model
    }

    private var db: LibraryDatabase { model.database }

    // MARK: Query building

    static let itemColumns: [String: String] = [
        "title": "title", "author": "authors", "authors": "authors", "abstract": "abstract",
        "tag": "tags", "tags": "tags", "venue": "venue", "journal": "venue"
    ]
    static let thoughtColumns: [String: String] = ["title": "title", "body": "body"]

    /// Turns what a person typed into a safe FTS5 expression, or nil if there is nothing to search.
    /// - words are ANDed; "quoted words" are a phrase; the last word matches as a prefix ("feder" finds "federated")
    /// - `author:smith`, `title:graph` ... limit a word to one column (when `columns` knows it)
    /// - FTS5 operators typed by the user (AND, OR, NOT, NEAR, parentheses, `-`) can never break the query
    static func ftsQuery(_ raw: String, columns: [String: String] = [:], prefixLast: Bool = true) -> ParsedQuery? {

        struct Token { var column: String?; var text: String; var phrase: Bool }
        var tokens: [Token] = []

        var current = ""
        var inQuote = false

        func flush(asPhrase: Bool) {
            let text = current.replacingOccurrences(of: "\"", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            current = ""
            guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return }

            if !asPhrase {
                if ["AND", "OR", "NOT", "NEAR"].contains(text) { return }
                if let colon = text.firstIndex(of: ":"), colon != text.startIndex {
                    let name = text[..<colon].lowercased()
                    let rest = String(text[text.index(after: colon)...])
                    if let column = columns[name], rest.contains(where: { $0.isLetter || $0.isNumber }) {
                        tokens.append(Token(column: column, text: rest, phrase: false))
                        return
                    }
                }
            }
            tokens.append(Token(column: nil, text: text, phrase: asPhrase))
        }

        for character in raw {
            if character == "\"" {
                flush(asPhrase: inQuote)
                inQuote.toggle()
            } else if character.isWhitespace && !inQuote {
                flush(asPhrase: false)
            } else {
                current.append(character)
            }
        }
        flush(asPhrase: inQuote)

        guard !tokens.isEmpty else { return nil }

        var parts: [String] = []
        var terms: [String] = []

        for (index, token) in tokens.enumerated() {
            let quoted = "\"" + token.text + "\""
            let isLast = index == tokens.count - 1
            let star = (prefixLast && isLast && !token.phrase) ? "*" : ""
            let expression = quoted + star
            parts.append(token.column.map { "\($0) : \(expression)" } ?? expression)
            terms.append(contentsOf: token.text.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init))
        }

        return ParsedQuery(match: parts.joined(separator: " "), terms: terms)
    }

    // MARK: Items (F-22, F-24)

    func searchItems(_ query: String, options: SearchOptions = SearchOptions()) throws -> SearchPage<ItemHit> {

        guard let parsed = Self.ftsQuery(query, columns: Self.itemColumns) else {
            return SearchPage(hits: [], total: 0, totalIsCapped: false)
        }

        let filter = "i.deleted_at IS NULL" + (options.includeInbox ? "" : " AND i.review_state = 'accepted'")
        let from = "FROM fts_items JOIN items i ON i.rowid = fts_items.rowid WHERE fts_items MATCH ? AND \(filter)"

        let rows = try db.rows(
            """
            SELECT i.id AS id, i.title AS title, i.abstract AS abstract, i.year AS year,
                   bm25(fts_items, 10.0, 5.0, 2.0, 3.0, 1.0) AS score
            \(from)
            ORDER BY score, i.id
            LIMIT ? OFFSET ?
            """,
            [.text(parsed.match), .int(Int64(max(options.limit, 0))), .int(Int64(max(options.offset, 0)))]
        )

        let hits = rows.map { row in
            ItemHit(
                itemID: row.text("id") ?? "",
                title: row.text("title") ?? "",
                year: row.int("year").map { Int($0) },
                snippet: Self.snippet(from: row.text("abstract") ?? "", terms: parsed.terms),
                score: Self.score(row)
            )
        }

        let total = try cappedCount("SELECT 1 \(from)", [.text(parsed.match)])
        return SearchPage(hits: hits, total: total.count, totalIsCapped: total.capped)
    }

    /// Full records for a page of hits, in the same order. Items deleted in the meantime are skipped.
    func items(for hits: [ItemHit]) throws -> [ModelItem] {
        try hits.compactMap { try model.items.fetch(id: $0.itemID) }
    }

    /// As-you-type title matches for the command palette. Cheap: title column only, no counting, no snippets.
    func suggestTitles(prefix: String, limit: Int = 8) throws -> [ItemHit] {

        guard let parsed = Self.ftsQuery(prefix, columns: [:]) else { return [] }

        let rows = try db.rows(
            """
            SELECT i.id AS id, i.title AS title, i.year AS year, bm25(fts_items, 10.0, 5.0, 2.0, 3.0, 1.0) AS score
            FROM fts_items JOIN items i ON i.rowid = fts_items.rowid
            WHERE fts_items MATCH ? AND i.deleted_at IS NULL AND i.review_state = 'accepted'
            ORDER BY score, i.id
            LIMIT ?
            """,
            [.text("{title} : (" + parsed.match + ")"), .int(Int64(max(limit, 0)))]
        )

        return rows.map {
            ItemHit(itemID: $0.text("id") ?? "", title: $0.text("title") ?? "",
                    year: $0.int("year").map { Int($0) }, snippet: "", score: Self.score($0))
        }
    }

    // MARK: PDF text (F-22)

    func searchPDF(_ query: String, options: SearchOptions = SearchOptions()) throws -> SearchPage<PDFHit> {

        guard let parsed = Self.ftsQuery(query) else {
            return SearchPage(hits: [], total: 0, totalIsCapped: false)
        }

        let from = """
            FROM fts_pdf
            JOIN attachments a ON a.rowid = fts_pdf.rowid / \(Self.pdfPageSpan)
            JOIN items i ON i.id = a.item_id
            WHERE fts_pdf MATCH ? AND a.deleted_at IS NULL AND i.deleted_at IS NULL
            """

        let rows = try db.rows(
            """
            SELECT a.id AS attachment_id, i.id AS item_id, i.title AS title,
                   fts_pdf.rowid % \(Self.pdfPageSpan) AS page, bm25(fts_pdf) AS score
            \(from)
            ORDER BY score, a.id, page
            LIMIT ? OFFSET ?
            """,
            [.text(parsed.match), .int(Int64(max(options.limit, 0))), .int(Int64(max(options.offset, 0)))]
        )

        let hits = rows.map {
            PDFHit(attachmentID: $0.text("attachment_id") ?? "", itemID: $0.text("item_id") ?? "",
                   itemTitle: $0.text("title") ?? "", page: Int($0.int("page") ?? 1), score: Self.score($0))
        }

        let total = try cappedCount("SELECT 1 \(from)", [.text(parsed.match)])
        return SearchPage(hits: hits, total: total.count, totalIsCapped: total.capped)
    }

    // MARK: Thoughts (F-22)

    func searchThoughts(_ query: String, options: SearchOptions = SearchOptions()) throws -> SearchPage<ThoughtHit> {

        guard let parsed = Self.ftsQuery(query, columns: Self.thoughtColumns) else {
            return SearchPage(hits: [], total: 0, totalIsCapped: false)
        }

        let from = "FROM fts_thought JOIN thoughts t ON t.rowid = fts_thought.rowid WHERE fts_thought MATCH ? AND t.deleted_at IS NULL"

        let rows = try db.rows(
            """
            SELECT t.id AS id, t.kind AS kind, t.title AS title, t.body AS body,
                   bm25(fts_thought, 5.0, 1.0) AS score
            \(from)
            ORDER BY score, t.id
            LIMIT ? OFFSET ?
            """,
            [.text(parsed.match), .int(Int64(max(options.limit, 0))), .int(Int64(max(options.offset, 0)))]
        )

        let hits = rows.map {
            ThoughtHit(thoughtID: $0.text("id") ?? "", kind: $0.text("kind") ?? "note",
                       title: $0.text("title") ?? "",
                       snippet: Self.snippet(from: $0.text("body") ?? "", terms: parsed.terms),
                       score: Self.score($0))
        }

        let total = try cappedCount("SELECT 1 \(from)", [.text(parsed.match)])
        return SearchPage(hits: hits, total: total.count, totalIsCapped: total.capped)
    }

    // MARK: Drafts (F-22)

    func searchDrafts(_ query: String, options: SearchOptions = SearchOptions()) throws -> SearchPage<DraftHit> {

        guard let parsed = Self.ftsQuery(query) else {
            return SearchPage(hits: [], total: 0, totalIsCapped: false)
        }

        // One hit per draft (best file wins). bm25() cannot sit inside an aggregate, so use the `rank` column (same score) in a subquery.
        let rows = try db.rows(
            """
            SELECT id, title, MIN(score) AS score FROM (
                SELECT d.id AS id, d.title AS title, fts_draft.rank AS score
                FROM fts_draft JOIN drafts d ON d.rowid = fts_draft.rowid / \(Self.draftFileSpan)
                WHERE fts_draft MATCH ? AND d.deleted_at IS NULL
            )
            GROUP BY id
            ORDER BY score, id
            LIMIT ? OFFSET ?
            """,
            [.text(parsed.match), .int(Int64(max(options.limit, 0))), .int(Int64(max(options.offset, 0)))]
        )

        let hits = rows.map {
            DraftHit(draftID: $0.text("id") ?? "", title: $0.text("title") ?? "", file: nil, score: Self.score($0))
        }

        let total = try cappedCount(
            """
            SELECT DISTINCT d.id FROM fts_draft JOIN drafts d ON d.rowid = fts_draft.rowid / \(Self.draftFileSpan)
            WHERE fts_draft MATCH ? AND d.deleted_at IS NULL
            """, [.text(parsed.match)])
        return SearchPage(hits: hits, total: total.count, totalIsCapped: total.capped)
    }

    // MARK: Everything at once (global search, command palette)

    func searchAll(_ query: String, limitPerKind: Int = 10, includeInbox: Bool = false) throws -> SearchResults {
        let options = SearchOptions(limit: limitPerKind, offset: 0, includeInbox: includeInbox)
        return SearchResults(
            items: try searchItems(query, options: options).hits,
            pdf: try searchPDF(query, options: options).hits,
            thoughts: try searchThoughts(query, options: options).hits,
            drafts: try searchDrafts(query, options: options).hits
        )
    }

    // MARK: Indexing: items

    /// Adds or refreshes one item in the index (title, authors, abstract, tags, venue).
    /// Call after an item, its authors or its tags change. Trashed items stay indexed; queries hide them.
    func indexItem(id: String) throws {
        try model.atomically {
            guard let columns = try itemColumnValues(id: id) else { return }
            try replaceRow(table: "fts_items", names: ["title", "authors", "abstract", "tags", "venue"],
                           rowID: columns.rowID, values: columns.values)
        }
    }

    func removeItem(id: String) throws {
        try model.atomically {
            guard let rowID = try db.scalarInt("SELECT rowid FROM items WHERE id = ?", [.text(id)]) else { return }
            try replaceRow(table: "fts_items", names: ["title", "authors", "abstract", "tags", "venue"],
                           rowID: rowID, values: nil)
        }
    }

    /// Throws the item index away and builds it again from the items table. Safe to call any time.
    func rebuildItems() throws {
        try model.atomically {
            try db.exec("INSERT INTO fts_items(fts_items) VALUES('delete-all')")
            try db.run("DELETE FROM meta WHERE key >= 'fts_items.' AND key < 'fts_items/'")
            let ids = try db.rows("SELECT id FROM items").compactMap { $0.text("id") }
            for id in ids {
                guard let columns = try itemColumnValues(id: id) else { continue }
                try replaceRow(table: "fts_items", names: ["title", "authors", "abstract", "tags", "venue"],
                               rowID: columns.rowID, values: columns.values)
            }
        }
    }

    // MARK: Indexing: thoughts

    func indexThought(id: String) throws {
        try model.atomically {
            guard let row = try db.rows("SELECT rowid AS rid, title, body FROM thoughts WHERE id = ?", [.text(id)]).first,
                  let rowID = row.int("rid") else { return }
            try replaceRow(table: "fts_thought", names: ["title", "body"], rowID: rowID,
                           values: [row.text("title") ?? "", row.text("body") ?? ""])
        }
    }

    func removeThought(id: String) throws {
        try model.atomically {
            guard let rowID = try db.scalarInt("SELECT rowid FROM thoughts WHERE id = ?", [.text(id)]) else { return }
            try replaceRow(table: "fts_thought", names: ["title", "body"], rowID: rowID, values: nil)
        }
    }

    func rebuildThoughts() throws {
        try model.atomically {
            try db.exec("INSERT INTO fts_thought(fts_thought) VALUES('delete-all')")
            try db.run("DELETE FROM meta WHERE key >= 'fts_thought.' AND key < 'fts_thought/'")
            for row in try db.rows("SELECT rowid AS rid, title, body FROM thoughts") {
                guard let rowID = row.int("rid") else { continue }
                try replaceRow(table: "fts_thought", names: ["title", "body"], rowID: rowID,
                               values: [row.text("title") ?? "", row.text("body") ?? ""])
            }
        }
    }

    // MARK: Indexing: PDF pages and draft files (add-only)

    /// Adds the text of PDF pages (page numbers start at 1). ADD-ONLY: indexing the same
    /// attachment twice makes duplicate rows, so index an attachment once, and call
    /// `resetPDFIndex()` first when re-indexing everything. Does not touch `attachments.indexed_at`.
    func indexPDF(attachmentID: String, pages: [(page: Int, text: String)]) throws {
        try model.atomically {
            guard let attachmentRowID = try db.scalarInt("SELECT rowid FROM attachments WHERE id = ?", [.text(attachmentID)]) else {
                return
            }
            for entry in pages where entry.page >= 1 && entry.page < Int(Self.pdfPageSpan) {
                guard !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                try db.run(
                    "INSERT INTO fts_pdf(rowid, text, attachment_id, page) VALUES (?, ?, ?, ?)",
                    [.int(Self.pdfRowID(attachmentRowID: attachmentRowID, page: entry.page)),
                     .text(entry.text), .text(attachmentID), .int(Int64(entry.page))]
                )
            }
        }
    }

    func resetPDFIndex() throws {
        try db.exec("INSERT INTO fts_pdf(fts_pdf) VALUES('delete-all')")
    }

    /// Adds the text of one draft file. ADD-ONLY, same rule as `indexPDF`.
    func indexDraftFile(draftID: String, file: String, text: String) throws {
        try model.atomically {
            guard let draftRowID = try db.scalarInt("SELECT rowid FROM drafts WHERE id = ?", [.text(draftID)]) else { return }
            try db.run(
                "INSERT INTO fts_draft(rowid, text, draft_id, file) VALUES (?, ?, ?, ?)",
                [.int(Self.draftRowID(draftRowID: draftRowID, file: file)), .text(text), .text(draftID), .text(file)]
            )
        }
    }

    func resetDraftIndex() throws {
        try db.exec("INSERT INTO fts_draft(fts_draft) VALUES('delete-all')")
    }

    // MARK: Rowid encoding (public so the PDF indexer uses the same rule)

    static func pdfRowID(attachmentRowID: Int64, page: Int) -> Int64 {
        attachmentRowID * pdfPageSpan + Int64(page)
    }

    static func decodePDFRowID(_ rowID: Int64) -> (attachmentRowID: Int64, page: Int) {
        (rowID / pdfPageSpan, Int(rowID % pdfPageSpan))
    }

    static func draftRowID(draftRowID: Int64, file: String) -> Int64 {
        var hash: UInt64 = 1_469_598_103_934_665_603            // FNV-1a, stable across launches
        for byte in file.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return draftRowID * draftFileSpan + Int64(hash % UInt64(draftFileSpan))
    }

    // MARK: Private

    private static func score(_ row: SQLRow) -> Double {
        if case .double(let value) = row["score"] { return value }
        if case .int(let value) = row["score"] { return Double(value) }
        return 0
    }

    private func cappedCount(_ innerSQL: String, _ params: [SQLValue]) throws -> (count: Int, capped: Bool) {
        let count = Int(try db.scalarInt(
            "SELECT COUNT(*) FROM (\(innerSQL) LIMIT \(Self.countCap + 1))", params) ?? 0)
        return count > Self.countCap ? (Self.countCap, true) : (count, false)
    }

    private func itemColumnValues(id: String) throws -> (rowID: Int64, values: [String])? {
        let rows = try db.rows(
            """
            SELECT i.rowid AS rid, i.title AS title, i.abstract AS abstract, i.venue AS venue,
                   (SELECT group_concat(trim(c.given || ' ' || c.family), ' ')
                      FROM item_creators ic JOIN creators c ON c.id = ic.creator_id
                     WHERE ic.item_id = i.id) AS authors,
                   (SELECT group_concat(t.name, ' ')
                      FROM item_tags it JOIN tags t ON t.id = it.tag_id
                     WHERE it.item_id = i.id) AS tags
            FROM items i WHERE i.id = ?
            """, [.text(id)])

        guard let row = rows.first, let rowID = row.int("rid") else { return nil }
        return (rowID, [row.text("title") ?? "", row.text("authors") ?? "", row.text("abstract") ?? "",
                        row.text("tags") ?? "", row.text("venue") ?? ""])
    }

    /// Removes what this file indexed earlier for `rowID` (from the shadow copy in `meta`), then
    /// indexes `values` (nil = only remove) and stores the new shadow.
    private func replaceRow(table: String, names: [String], rowID: Int64, values: [String]?) throws {

        let shadowKey = "\(table).\(rowID)"

        if let old = try db.scalarText("SELECT value FROM meta WHERE key = ?", [.text(shadowKey)]),
           let data = old.data(using: .utf8),
           let oldValues = try? JSONDecoder().decode([String].self, from: data),
           oldValues.count == names.count {

            let columns = names.joined(separator: ", ")
            let marks = Array(repeating: "?", count: names.count).joined(separator: ", ")
            try db.run(
                "INSERT INTO \(table)(\(table), rowid, \(columns)) VALUES ('delete', ?, \(marks))",
                [.int(rowID)] + oldValues.map { .text($0) }
            )
            try db.run("DELETE FROM meta WHERE key = ?", [.text(shadowKey)])
        }

        guard let values, values.count == names.count else { return }

        let columns = names.joined(separator: ", ")
        let marks = Array(repeating: "?", count: names.count).joined(separator: ", ")
        try db.run(
            "INSERT INTO \(table)(rowid, \(columns)) VALUES (?, \(marks))",
            [.int(rowID)] + values.map { .text($0) }
        )

        if let data = try? JSONEncoder().encode(values), let json = String(data: data, encoding: .utf8) {
            try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", [.text(shadowKey), .text(json)])
        }
    }

    /// About 140 characters around the first search word. Cut in Swift because the index holds no text.
    static func snippet(from text: String, terms: [String], radius: Int = 70) -> String {

        let flat = text.split(whereSeparator: { $0.isNewline || $0.isWhitespace }).joined(separator: " ")
        guard !flat.isEmpty else { return "" }

        var best: Range<String.Index>?
        for term in terms where !term.isEmpty {
            if let range = flat.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]),
               best == nil || range.lowerBound < best!.lowerBound {
                best = range
            }
        }

        guard let hit = best else {
            return flat.count <= radius * 2 ? flat : String(flat.prefix(radius * 2)) + "…"
        }

        let start = flat.index(hit.lowerBound, offsetBy: -radius, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(hit.upperBound, offsetBy: radius, limitedBy: flat.endIndex) ?? flat.endIndex

        return (start > flat.startIndex ? "…" : "") + String(flat[start..<end]) + (end < flat.endIndex ? "…" : "")
    }
}
