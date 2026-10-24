//
//  CitationKeyStore.swift
//  ResearchBase
//
//  Phase 1, Step 1B (F-13)
//
//  Stable citation keys.
//    * A key is generated ONCE, when the item is created. Editing the
//      title or authors later never changes it.
//    * A key LOCKS (items.key_locked = 1) once a draft cites it
//      (a row in draft_citations). It stays locked.
//    * Changing a locked key needs `confirmed: true` (the screen asks
//      first). The change updates draft_citations and reports which
//      drafts were affected, so Phase 5 can rewrite their \cite{} text.
//    * Keys are unique ignoring case, across ALL items including ones in
//      the Trash, so restoring from the Trash can never collide.
//

import Foundation

// MARK: - Generator (pure)

enum CitationKeyGenerator {

    private static let stopWords: Set<String> = [
        "a", "an", "the", "on", "of", "in", "for", "and", "to", "with",
        "from", "by", "at", "is", "are", "as", "or", "via", "using",
        "toward", "towards"
    ]

    /// authorYYYYword, for example mcmahan2017communication.
    /// No author -> "unknown". No year -> "nd".
    static func base(firstCreator: CreatorInput?, year: Int?, title: String) -> String {

        var author = firstCreator.map { TextNormalizer.asciiLettersAndDigits($0.family) } ?? ""
        if author.isEmpty { author = "unknown" }

        let yearPart = year.map { String($0) } ?? "nd"
        return author + yearPart + firstSignificantWord(of: title)
    }

    static func firstSignificantWord(of title: String) -> String {
        let pieces = title.split(whereSeparator: { !($0.isLetter || $0.isNumber) })
        for piece in pieces {
            let word = TextNormalizer.asciiLettersAndDigits(String(piece))
            if word.count >= 2, !stopWords.contains(word) {
                return word
            }
        }
        return ""
    }

    /// Letters, digits and - _ : . only. Not empty.
    static func isValid(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        return key.allSatisfy { character in
            (character.isASCII && (character.isLetter || character.isNumber))
                || character == "-" || character == "_" || character == ":" || character == "."
        }
    }
}

// MARK: - Result of a key change

struct CitationKeyChange: Equatable {
    let itemID: String
    let oldKey: String
    let newKey: String
    /// Drafts whose citations were updated. Phase 5 rewrites their .tex files.
    let draftIDs: [String]
    let wasLocked: Bool
}

// MARK: - Store

final class CitationKeyStore {

    unowned let model: LibraryModel

    init(model: LibraryModel) {
        self.model = model
    }

    /// True when another item (any state, even in the Trash) already uses this key.
    func isTaken(_ key: String, excluding itemID: String? = nil) throws -> Bool {
        let count = try model.database.scalarInt(
            "SELECT COUNT(*) FROM items WHERE lower(citation_key) = lower(?) AND id != ?",
            [.text(key), .text(itemID ?? "")]
        ) ?? 0
        return count > 0
    }

    /// The first free key: base, then base+a ... base+z, then base-2, base-3 ...
    func generate(firstCreator: CreatorInput?, year: Int?, title: String) throws -> String {

        let base = CitationKeyGenerator.base(firstCreator: firstCreator, year: year, title: title)
        if try !isTaken(base) { return base }

        for letter in "abcdefghijklmnopqrstuvwxyz" {
            let candidate = base + String(letter)
            if try !isTaken(candidate) { return candidate }
        }

        var number = 2
        while true {
            let candidate = "\(base)-\(number)"
            if try !isTaken(candidate) { return candidate }
            number += 1
        }
    }

    // MARK: Locking

    func isLocked(itemID: String) throws -> Bool {
        let value = try model.database.scalarInt("SELECT key_locked FROM items WHERE id = ?", [.text(itemID)])
        guard let value else { throw ModelError.notFound(kind: "paper", id: itemID) }
        return value != 0
    }

    /// Locks every key that a draft cites. Safe to call again (the second call changes nothing).
    /// Phase 5 calls this after each save of a draft. Returns how many keys became locked.
    @discardableResult
    func lockKeysUsedByDrafts() throws -> Int {
        try model.atomically {
            let rows = try model.database.rows(
                """
                SELECT id FROM items
                WHERE key_locked = 0
                  AND id IN (SELECT item_id FROM draft_citations WHERE item_id IS NOT NULL)
                """
            )
            for row in rows {
                guard let id = row.text("id") else { continue }
                try model.database.run(
                    "UPDATE items SET key_locked = 1, updated_at = ? WHERE id = ?",
                    [.text(model.now()), .text(id)]
                )
                try model.record("item", id, .update, field: "key_locked", old: "0", new: "1")
            }
            return rows.count
        }
    }

    // MARK: Changing a key

    /// Changes an item's citation key.
    /// - A locked key needs `confirmed: true`, otherwise nothing changes and `.citationKeyLocked` is thrown.
    /// - The new key must be valid and unused.
    /// - draft_citations rows for this item are updated to the new key.
    @discardableResult
    func change(itemID: String, to requestedKey: String, confirmed: Bool) throws -> CitationKeyChange {

        let newKey = requestedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CitationKeyGenerator.isValid(newKey) else {
            throw ModelError.citationKeyInvalid(newKey)
        }

        return try model.atomically {

            guard let row = try model.database.rows(
                "SELECT citation_key, key_locked FROM items WHERE id = ?", [.text(itemID)]
            ).first, let oldKey = row.text("citation_key") else {
                throw ModelError.notFound(kind: "paper", id: itemID)
            }
            let wasLocked = (row.int("key_locked") ?? 0) != 0

            if oldKey == newKey {
                return CitationKeyChange(itemID: itemID, oldKey: oldKey, newKey: newKey, draftIDs: [], wasLocked: wasLocked)
            }
            if wasLocked && !confirmed {
                throw ModelError.citationKeyLocked(oldKey)
            }
            if try isTaken(newKey, excluding: itemID) {
                throw ModelError.citationKeyInUse(newKey)
            }

            let draftRows = try model.database.rows(
                "SELECT DISTINCT draft_id FROM draft_citations WHERE item_id = ? ORDER BY draft_id",
                [.text(itemID)]
            )
            let draftIDs = draftRows.compactMap { $0.text("draft_id") }

            try model.database.run(
                "UPDATE items SET citation_key = ?, updated_at = ? WHERE id = ?",
                [.text(newKey), .text(model.now()), .text(itemID)]
            )

            // draft_citations is rebuilt from the .tex on every save, so if the new key already
            // sits in the same file and line as an unresolved row, that row is replaced.
            try model.database.run(
                "UPDATE OR REPLACE draft_citations SET citation_key = ? WHERE item_id = ?",
                [.text(newKey), .text(itemID)]
            )

            try model.record("item", itemID, .update, field: "citation_key", old: oldKey, new: newKey)

            return CitationKeyChange(
                itemID: itemID, oldKey: oldKey, newKey: newKey,
                draftIDs: draftIDs, wasLocked: wasLocked
            )
        }
    }
}
