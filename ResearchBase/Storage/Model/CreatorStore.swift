//
//  CreatorStore.swift
//  ResearchBase
//
//  Phase 1, Step 1B (F-08, X-03)
//
//  Authors, editors and translators as real records: family, given,
//  suffix, organisation. One creator record can belong to many items.
//
//  Sharing rule: a creator is shared only when the ORCID matches or the
//  family, given name, suffix and organisation flag are exactly the same.
//  Spellings that merely look alike ("Li, Tian" and "Li, T.") stay
//  separate until the user merges them (`lookalikes`, `merge`).
//

import Foundation

struct CreatorUsage: Equatable {
    let creator: Creator
    let itemCount: Int
}

struct CreatorLookalike: Equatable {
    let first: CreatorUsage
    let second: CreatorUsage
}

final class CreatorStore {

    unowned let model: LibraryModel

    init(model: LibraryModel) {
        self.model = model
    }

    // MARK: Find or create

    @discardableResult
    func findOrCreate(_ input: CreatorInput) throws -> Creator {

        let family = input.family.trimmingCharacters(in: .whitespacesAndNewlines)
        let given = input.isOrganisation ? "" : input.given.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = input.isOrganisation ? "" : input.suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        let orcid = input.orcid?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasOrcid = !(orcid ?? "").isEmpty

        guard !family.isEmpty else { throw ModelError.emptyName }

        return try model.atomically {

            if hasOrcid, let orcid,
               let row = try model.database.rows(
                "SELECT * FROM creators WHERE orcid = ? ORDER BY id LIMIT 1", [.text(orcid)]
               ).first {
                return try Self.creator(from: row)
            }

            if !hasOrcid,
               let row = try model.database.rows(
                "SELECT * FROM creators WHERE family = ? AND given = ? AND suffix = ? AND is_org = ? ORDER BY id LIMIT 1",
                [.text(family), .text(given), .text(suffix), LibraryModel.bool(input.isOrganisation)]
               ).first {
                return try Self.creator(from: row)
            }

            let id = model.newID()
            let norm = Self.norm(family: family, given: given, isOrganisation: input.isOrganisation)

            try model.database.run(
                "INSERT INTO creators (id, family, given, suffix, is_org, orcid, norm) VALUES (?, ?, ?, ?, ?, ?, ?)",
                [.text(id), .text(family), .text(given), .text(suffix),
                 LibraryModel.bool(input.isOrganisation),
                 LibraryModel.text(hasOrcid ? orcid : nil), .text(norm)]
            )
            try model.record("creator", id, .create, field: "name", new: norm)

            return Creator(
                id: id, family: family, given: given, suffix: suffix,
                isOrganisation: input.isOrganisation,
                orcid: hasOrcid ? orcid : nil, norm: norm
            )
        }
    }

    // MARK: Read

    func creator(id: String) throws -> Creator? {
        guard let row = try model.database.rows("SELECT * FROM creators WHERE id = ?", [.text(id)]).first else {
            return nil
        }
        return try Self.creator(from: row)
    }

    /// The people on one item, authors first, then editors, then translators, each in order.
    func creators(of itemID: String) throws -> [ItemCreator] {
        let rows = try model.database.rows(
            """
            SELECT c.*, ic.role AS item_role, ic.position AS item_position
            FROM item_creators ic JOIN creators c ON c.id = ic.creator_id
            WHERE ic.item_id = ?
            ORDER BY CASE ic.role WHEN 'author' THEN 0 WHEN 'editor' THEN 1 ELSE 2 END, ic.position
            """,
            [.text(itemID)]
        )
        return try rows.map { row in
            let roleText = row.text("item_role") ?? ""
            guard let role = CreatorRole(rawValue: roleText) else {
                throw ModelError.invalidValue("creator role \(roleText)")
            }
            return ItemCreator(
                creator: try Self.creator(from: row),
                role: role,
                position: Int(row.int("item_position") ?? 0)
            )
        }
    }

    /// Every creator with the number of (non-trashed) items they appear on, by name.
    func allWithUsage() throws -> [CreatorUsage] {
        let rows = try model.database.rows(
            """
            SELECT c.*, COUNT(DISTINCT i.id) AS item_count
            FROM creators c
            LEFT JOIN item_creators ic ON ic.creator_id = c.id
            LEFT JOIN items i ON i.id = ic.item_id AND i.deleted_at IS NULL
            GROUP BY c.id
            ORDER BY c.norm, c.id
            """
        )
        return try rows.map {
            CreatorUsage(creator: try Self.creator(from: $0), itemCount: Int($0.int("item_count") ?? 0))
        }
    }

    // MARK: Set the list on an item

    private struct Slot: Codable, Equatable {
        let creator: String
        let role: String
        let position: Int
    }

    /// Replaces the people on an item. Order in `inputs` is the order shown.
    /// The old and new lists are reported to the change sink as JSON
    /// (creator id, role, position) so Step 1C can restore the old list.
    func setCreators(itemID: String, _ inputs: [CreatorInput]) throws {

        try model.atomically {

            let oldSlots = try slots(of: itemID)

            var counters: [CreatorRole: Int] = [:]
            var newSlots: [Slot] = []
            var resolved: [(Creator, CreatorRole, Int)] = []

            for input in inputs {
                let creator = try findOrCreate(input)
                let position = counters[input.role, default: 0]
                counters[input.role] = position + 1
                resolved.append((creator, input.role, position))
                newSlots.append(Slot(creator: creator.id, role: input.role.rawValue, position: position))
            }

            newSlots.sort { ($0.role, $0.position) < ($1.role, $1.position) }
            if oldSlots == newSlots { return }

            try model.database.run("DELETE FROM item_creators WHERE item_id = ?", [.text(itemID)])

            for (creator, role, position) in resolved {
                try model.database.run(
                    "INSERT INTO item_creators (item_id, creator_id, role, position) VALUES (?, ?, ?, ?)",
                    [.text(itemID), .text(creator.id), .text(role.rawValue), .int(Int64(position))]
                )
            }

            try model.record(
                "item", itemID, .update, field: "creators",
                old: Self.encode(oldSlots), new: Self.encode(newSlots)
            )
        }
    }

    private func slots(of itemID: String) throws -> [Slot] {
        try model.database.rows(
            "SELECT creator_id, role, position FROM item_creators WHERE item_id = ? ORDER BY role, position",
            [.text(itemID)]
        ).map {
            Slot(
                creator: $0.text("creator_id") ?? "",
                role: $0.text("role") ?? "",
                position: Int($0.int("position") ?? 0)
            )
        }.sorted { ($0.role, $0.position) < ($1.role, $1.position) }
    }

    private static func encode(_ slots: [Slot]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(slots), let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    // MARK: Edit

    /// Edits a creator record (spelling, suffix, ORCID). Every item that uses it shows the new spelling.
    @discardableResult
    func update(id: String, _ change: (inout Creator) -> Void) throws -> Creator {

        try model.atomically {

            guard let before = try creator(id: id) else {
                throw ModelError.notFound(kind: "author", id: id)
            }

            var after = before
            change(&after)
            after.id = before.id
            after.family = after.family.trimmingCharacters(in: .whitespacesAndNewlines)
            after.given = after.isOrganisation ? "" : after.given.trimmingCharacters(in: .whitespacesAndNewlines)
            after.suffix = after.isOrganisation ? "" : after.suffix.trimmingCharacters(in: .whitespacesAndNewlines)
            if let orcid = after.orcid?.trimmingCharacters(in: .whitespacesAndNewlines), !orcid.isEmpty {
                after.orcid = orcid
            } else {
                after.orcid = nil
            }
            guard !after.family.isEmpty else { throw ModelError.emptyName }
            after.norm = Self.norm(family: after.family, given: after.given, isOrganisation: after.isOrganisation)

            if after == before { return before }

            try model.database.run(
                "UPDATE creators SET family = ?, given = ?, suffix = ?, is_org = ?, orcid = ?, norm = ? WHERE id = ?",
                [.text(after.family), .text(after.given), .text(after.suffix),
                 LibraryModel.bool(after.isOrganisation), LibraryModel.text(after.orcid),
                 .text(after.norm), .text(id)]
            )
            try model.record("creator", id, .update, field: "name", old: before.displayName, new: after.displayName)
            return after
        }
    }

    // MARK: Merge (X-03)

    /// Moves every item of `source` to `target`, then removes the `source` record.
    /// Returns how many item lists were changed.
    ///
    /// The reported change carries a JSON snapshot of the merged-away creator and
    /// every (item, role, position) it held, so Step 1C can undo the merge.
    @discardableResult
    func merge(_ sourceID: String, into targetID: String) throws -> Int {

        guard sourceID != targetID else { throw ModelError.sameRecord }

        return try model.atomically {

            guard let source = try creator(id: sourceID) else { throw ModelError.notFound(kind: "author", id: sourceID) }
            guard try creator(id: targetID) != nil else { throw ModelError.notFound(kind: "author", id: targetID) }

            let held = try model.database.rows(
                "SELECT item_id, role, position FROM item_creators WHERE creator_id = ? ORDER BY item_id, role, position",
                [.text(sourceID)]
            )
            let heldJSON: [[String: Any]] = held.map {
                [
                    "item": $0.text("item_id") ?? "",
                    "role": $0.text("role") ?? "",
                    "position": Int($0.int("position") ?? 0)
                ]
            }

            try model.database.run(
                "UPDATE item_creators SET creator_id = ? WHERE creator_id = ?",
                [.text(targetID), .text(sourceID)]
            )

            let orcidValue: Any = source.orcid.map { $0 as Any } ?? NSNull()
            let creatorJSON: [String: Any] = [
                "id": source.id,
                "family": source.family,
                "given": source.given,
                "suffix": source.suffix,
                "is_org": source.isOrganisation ? 1 : 0,
                "orcid": orcidValue,
                "norm": source.norm
            ]
            let snapshot = LibraryModel.json(["creator": creatorJSON, "held": heldJSON] as [String: Any])

            // Needed: the schema has no deleted_at on creators. The row is fully described
            // in the snapshot above.
            try model.database.run("DELETE FROM creators WHERE id = ?", [.text(sourceID)])

            try model.record("creator", sourceID, .merge, field: "merged_into", old: snapshot, new: targetID)

            return Set(held.compactMap { $0.text("item_id") }).count
        }
    }

    // MARK: Look-alikes ("Authors that look the same")

    /// Pairs of creators with the same family name whose given names match
    /// by initial or by name: "McMahan, H. Brendan" and "McMahan, Brendan",
    /// "Li, Tian" and "Li, T.". Organisations and empty given names are not paired.
    func lookalikes() throws -> [CreatorLookalike] {

        let usage = try allWithUsage().filter { !$0.creator.isOrganisation && !$0.creator.given.isEmpty }

        var buckets: [String: [CreatorUsage]] = [:]
        for entry in usage {
            buckets[TextNormalizer.norm(entry.creator.family), default: []].append(entry)
        }

        var result: [CreatorLookalike] = []
        for key in buckets.keys.sorted() {
            let group = buckets[key] ?? []
            guard group.count > 1 else { continue }
            for firstIndex in 0..<group.count {
                for secondIndex in (firstIndex + 1)..<group.count {
                    if Self.givenNamesLookAlike(group[firstIndex].creator.given, group[secondIndex].creator.given) {
                        result.append(CreatorLookalike(first: group[firstIndex], second: group[secondIndex]))
                    }
                }
            }
        }
        return result
    }

    /// Every piece of the shorter given name matches a piece of the longer one
    /// (same first letter, and a full word only matches the same word or an initial).
    static func givenNamesLookAlike(_ first: String, _ second: String) -> Bool {

        func pieces(_ text: String) -> [String] {
            TextNormalizer.norm(text)
                .split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" })
                .map(String.init)
        }

        let a = pieces(first)
        let b = pieces(second)
        guard !a.isEmpty, !b.isEmpty else { return false }

        let (short, long) = a.count <= b.count ? (a, b) : (b, a)

        return short.allSatisfy { shortPiece in
            long.contains { longPiece in
                guard shortPiece.first == longPiece.first else { return false }
                return shortPiece.count == 1 || longPiece.count == 1 || shortPiece == longPiece
            }
        }
    }

    // MARK: Helpers

    static func norm(family: String, given: String, isOrganisation: Bool) -> String {
        isOrganisation
            ? TextNormalizer.norm(family)
            : TextNormalizer.norm("\(family) \(given)")
    }

    static func creator(from row: SQLRow) throws -> Creator {
        guard let id = row.text("id"), let family = row.text("family") else {
            throw ModelError.invalidValue("creator row")
        }
        return Creator(
            id: id,
            family: family,
            given: row.text("given") ?? "",
            suffix: row.text("suffix") ?? "",
            isOrganisation: (row.int("is_org") ?? 0) != 0,
            orcid: row.text("orcid"),
            norm: row.text("norm") ?? ""
        )
    }
}
