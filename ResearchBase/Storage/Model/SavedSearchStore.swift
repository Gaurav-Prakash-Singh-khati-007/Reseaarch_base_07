//
//  SavedSearchStore.swift
//  ResearchBase
//
//  Phase 1, Step 1B (F-09)
//
//  Rule-based smart lists. Rules are stored as JSON in saved_searches.rules_json
//  exactly like the schema comment: [{"field":"year","op":">=","value":2020}, ...]
//
//  Rules are turned into SQL with `?` placeholders only. A field or operator
//  that is not on the list below is refused, so a stored rule can never
//  put text into the SQL.
//
//  Fields:  title, venue, abstract, publisher, doi, key      text      = != contains "not contains"
//           year, rating, queue (0/1)                         number    = != > >= < <=
//           type, status, review                              choice    = !=
//           tag, author                                       text      = != contains
//
//  Smart lists show papers that are accepted (not in the Inbox) and not in the Trash.
//

import Foundation

// MARK: - Rules

enum SearchRuleValue: Codable, Equatable {

    case number(Int)
    case text(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            self = .number(number)
        } else {
            self = .text(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let number): try container.encode(number)
        case .text(let text): try container.encode(text)
        }
    }
}

struct SearchRule: Codable, Equatable {
    var field: String
    var op: String
    var value: SearchRuleValue

    init(field: String, op: String, value: SearchRuleValue) {
        self.field = field
        self.op = op
        self.value = value
    }
}

// MARK: - Rule to SQL

enum SearchRuleCompiler {

    private enum Kind { case text, number, choice, tag, author }

    private struct FieldInfo {
        let kind: Kind
        let column: String
        let choices: Set<String>
    }

    private static let fields: [String: FieldInfo] = [
        "title": FieldInfo(kind: .text, column: "items.title", choices: []),
        "venue": FieldInfo(kind: .text, column: "items.venue", choices: []),
        "abstract": FieldInfo(kind: .text, column: "items.abstract", choices: []),
        "publisher": FieldInfo(kind: .text, column: "items.publisher", choices: []),
        "doi": FieldInfo(kind: .text, column: "items.doi", choices: []),
        "key": FieldInfo(kind: .text, column: "items.citation_key", choices: []),
        "year": FieldInfo(kind: .number, column: "items.year", choices: []),
        "rating": FieldInfo(kind: .number, column: "items.rating", choices: []),
        "queue": FieldInfo(kind: .number, column: "items.in_queue", choices: []),
        "type": FieldInfo(kind: .choice, column: "items.item_type", choices: Set(ItemType.allCases.map { $0.rawValue })),
        "status": FieldInfo(kind: .choice, column: "items.reading_status", choices: ["unread", "reading", "read"]),
        "review": FieldInfo(kind: .choice, column: "items.review_state", choices: ["inbox", "accepted"]),
        "tag": FieldInfo(kind: .tag, column: "", choices: []),
        "author": FieldInfo(kind: .author, column: "", choices: [])
    ]

    static let knownFields: [String] = fields.keys.sorted()

    /// One rule as a SQL condition plus its parameters.
    static func condition(for rule: SearchRule) throws -> (sql: String, params: [SQLValue]) {

        guard let info = fields[rule.field] else {
            throw ModelError.invalidRule("unknown field “\(rule.field)”")
        }

        func invalidOp() -> ModelError {
            ModelError.invalidRule("“\(rule.op)” does not work with “\(rule.field)”")
        }

        func textValue() throws -> String {
            switch rule.value {
            case .text(let text): return text
            case .number(let number): return String(number)
            }
        }

        switch info.kind {

        case .number:
            guard case .number(let number) = rule.value else {
                throw ModelError.invalidRule("“\(rule.field)” needs a number")
            }
            guard ["=", "!=", ">", ">=", "<", "<="].contains(rule.op) else { throw invalidOp() }
            return ("\(info.column) \(rule.op) ?", [.int(Int64(number))])

        case .choice:
            let value = try textValue()
            guard info.choices.contains(value) else {
                throw ModelError.invalidRule("“\(value)” is not a choice for “\(rule.field)”")
            }
            guard ["=", "!="].contains(rule.op) else { throw invalidOp() }
            return ("\(info.column) \(rule.op) ?", [.text(value)])

        case .text:
            let value = try textValue()
            switch rule.op {
            case "=": return ("lower(\(info.column)) = lower(?)", [.text(value)])
            case "!=": return ("(\(info.column) IS NULL OR lower(\(info.column)) != lower(?))", [.text(value)])
            case "contains": return ("instr(lower(\(info.column)), lower(?)) > 0", [.text(value)])
            case "not contains": return ("(\(info.column) IS NULL OR instr(lower(\(info.column)), lower(?)) = 0)", [.text(value)])
            default: throw invalidOp()
            }

        case .tag:
            let value = try textValue()
            let exists = "EXISTS (SELECT 1 FROM item_tags it JOIN tags t ON t.id = it.tag_id WHERE it.item_id = items.id AND "
            switch rule.op {
            case "=": return (exists + "t.name = ? COLLATE NOCASE)", [.text(value)])
            case "!=": return ("NOT " + exists + "t.name = ? COLLATE NOCASE)", [.text(value)])
            case "contains": return (exists + "instr(lower(t.name), lower(?)) > 0)", [.text(value)])
            default: throw invalidOp()
            }

        case .author:
            // "Li, Tian" and "Li Tian" both become "li tian", the form stored in creators.norm.
            let value = TextNormalizer.norm(try textValue().replacingOccurrences(of: ",", with: " "))
            let exists = "EXISTS (SELECT 1 FROM item_creators ic JOIN creators c ON c.id = ic.creator_id WHERE ic.item_id = items.id AND "
            switch rule.op {
            case "=": return (exists + "c.norm = ?)", [.text(value)])
            case "!=": return ("NOT " + exists + "c.norm = ?)", [.text(value)])
            case "contains": return (exists + "instr(c.norm, ?) > 0)", [.text(value)])
            default: throw invalidOp()
            }
        }
    }

    /// All rules joined with AND (`matchAll`) or OR. At least one rule is required.
    static func whereClause(rules: [SearchRule], matchAll: Bool) throws -> (sql: String, params: [SQLValue]) {

        guard !rules.isEmpty else { throw ModelError.invalidRule("add at least one rule") }

        var parts: [String] = []
        var params: [SQLValue] = []
        for rule in rules {
            let piece = try condition(for: rule)
            parts.append("(" + piece.sql + ")")
            params.append(contentsOf: piece.params)
        }
        return (parts.joined(separator: matchAll ? " AND " : " OR "), params)
    }
}

// MARK: - Store

final class SavedSearchStore {

    unowned let model: LibraryModel

    init(model: LibraryModel) {
        self.model = model
    }

    @discardableResult
    func create(name rawName: String, rules: [SearchRule], matchAll: Bool = true) throws -> SavedSearch {

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ModelError.emptyName }
        _ = try SearchRuleCompiler.whereClause(rules: rules, matchAll: matchAll)   // refuses bad rules

        return try model.atomically {

            let id = model.newID()
            let position = Int(try model.database.scalarInt("SELECT COALESCE(MAX(position) + 1, 0) FROM saved_searches") ?? 0)

            try model.database.run(
                "INSERT INTO saved_searches (id, name, rules_json, match_all, position) VALUES (?, ?, ?, ?, ?)",
                [.text(id), .text(name), .text(try Self.encode(rules)), LibraryModel.bool(matchAll), .int(Int64(position))]
            )
            try model.record("saved_search", id, .create, field: "name", new: name)

            return SavedSearch(id: id, name: name, rules: rules, matchAll: matchAll, position: position)
        }
    }

    func search(id: String) throws -> SavedSearch? {
        guard let row = try model.database.rows("SELECT * FROM saved_searches WHERE id = ?", [.text(id)]).first else {
            return nil
        }
        return try Self.search(from: row)
    }

    func all() throws -> [SavedSearch] {
        try model.database.rows("SELECT * FROM saved_searches ORDER BY position, name COLLATE NOCASE, id")
            .map { try Self.search(from: $0) }
    }

    /// Changes name, rules or match mode. Bad rules are refused and nothing changes.
    @discardableResult
    func update(id: String, name rawName: String? = nil, rules: [SearchRule]? = nil, matchAll: Bool? = nil) throws -> SavedSearch {

        try model.atomically {

            guard var current = try search(id: id) else { throw ModelError.notFound(kind: "smart list", id: id) }
            let before = current

            if let rawName {
                let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { throw ModelError.emptyName }
                current.name = name
            }
            if let rules { current.rules = rules }
            if let matchAll { current.matchAll = matchAll }

            _ = try SearchRuleCompiler.whereClause(rules: current.rules, matchAll: current.matchAll)
            if current == before { return before }

            try model.database.run(
                "UPDATE saved_searches SET name = ?, rules_json = ?, match_all = ? WHERE id = ?",
                [.text(current.name), .text(try Self.encode(current.rules)), LibraryModel.bool(current.matchAll), .text(id)]
            )
            try model.record("saved_search", id, .update, field: "definition",
                             old: Self.snapshot(before), new: Self.snapshot(current))
            return current
        }
    }

    /// Removes a smart list. The schema has no deleted_at for saved searches; the full
    /// definition is reported to the change sink so Step 1C can bring it back.
    func remove(id: String) throws {
        try model.atomically {
            guard let current = try search(id: id) else { throw ModelError.notFound(kind: "smart list", id: id) }
            try model.database.run("DELETE FROM saved_searches WHERE id = ?", [.text(id)])
            try model.record("saved_search", id, .delete, field: "definition", old: Self.snapshot(current), new: nil)
        }
    }

    // MARK: Running a smart list

    /// The papers that match, newest first.
    func items(matching id: String, limit: Int = 500, offset: Int = 0) throws -> [ModelItem] {
        guard let saved = try search(id: id) else { throw ModelError.notFound(kind: "smart list", id: id) }
        return try items(matching: saved.rules, matchAll: saved.matchAll, limit: limit, offset: offset)
    }

    func items(matching rules: [SearchRule], matchAll: Bool, limit: Int = 500, offset: Int = 0) throws -> [ModelItem] {
        let clause = try SearchRuleCompiler.whereClause(rules: rules, matchAll: matchAll)
        let rows = try model.database.rows(
            """
            SELECT items.* FROM items
            WHERE items.deleted_at IS NULL AND items.review_state = 'accepted' AND (\(clause.sql))
            ORDER BY items.added_at DESC, items.id
            LIMIT ? OFFSET ?
            """,
            clause.params + [.int(Int64(limit)), .int(Int64(offset))]
        )
        return try rows.map { try ItemStore.item(from: $0) }
    }

    // MARK: Helpers

    static func encode(_ rules: [SearchRule]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(rules)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    static func search(from row: SQLRow) throws -> SavedSearch {
        guard let id = row.text("id"), let name = row.text("name"), let json = row.text("rules_json") else {
            throw ModelError.invalidValue("smart list row")
        }
        guard let data = json.data(using: .utf8),
              let rules = try? JSONDecoder().decode([SearchRule].self, from: data) else {
            throw ModelError.invalidRule("the saved rules of “\(name)” cannot be read")
        }
        return SavedSearch(
            id: id, name: name, rules: rules,
            matchAll: (row.int("match_all") ?? 1) != 0,
            position: Int(row.int("position") ?? 0)
        )
    }

    private static func snapshot(_ search: SavedSearch) -> String {
        LibraryModel.json([
            "name": search.name,
            "rules": (try? encode(search.rules)) ?? "[]",
            "match_all": search.matchAll ? 1 : 0,
            "position": search.position
        ] as [String: Any])
    }
}
