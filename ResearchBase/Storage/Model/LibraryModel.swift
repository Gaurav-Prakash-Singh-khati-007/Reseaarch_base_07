//
//  LibraryModel.swift
//  ResearchBase
//
//  Phase 1, Step 1B
//
//  The one object the stores share: the open `Library`, the change sink,
//  and `atomically`, which makes several store calls one all-or-nothing
//  action. (LibraryDatabase transactions do not nest, so stores never
//  open their own transaction directly; they call `atomically`.)
//
//  Nothing in this folder hard-deletes a record that has a `deleted_at`
//  column. Removal of such records is Step 1C (Trash).
//

import Foundation

final class LibraryModel {

    let library: Library
    let changeSink: ChangeSink

    private var depth = 0

    init(library: Library, changeSink: ChangeSink? = nil) {
        self.library = library
        self.changeSink = changeSink ?? NullChangeSink()
    }

    var database: LibraryDatabase { library.database }

    // MARK: Stores

    lazy var items = ItemStore(model: self)
    lazy var creators = CreatorStore(model: self)
    lazy var tags = TagStore(model: self)
    lazy var collections = CollectionStore(model: self)
    lazy var savedSearches = SavedSearchStore(model: self)
    lazy var attachments = AttachmentStore(model: self)
    lazy var links = LinkStore(model: self)
    lazy var citationKeys = CitationKeyStore(model: self)
    lazy var search = SearchService(model: self)

    // MARK: Atomic work

    /// Runs `body` as ONE transaction. Called inside another `atomically`,
    /// it simply joins it, so the outermost call decides commit or undo.
    func atomically<T>(_ body: () throws -> T) throws -> T {
        if depth > 0 { return try body() }
        depth += 1
        defer { depth -= 1 }
        return try database.transaction(body)
    }

    // MARK: Helpers shared by the stores

    func newID() -> String { UUID().uuidString }

    func now() -> String { Library.nowISO() }

    func record(
        _ entityType: String,
        _ entityID: String,
        _ action: ChangeAction,
        field: String? = nil,
        old: String? = nil,
        new: String? = nil
    ) throws {
        try changeSink.record(
            entityType: entityType,
            entityID: entityID,
            action: action,
            field: field,
            oldValue: old,
            newValue: new
        )

        keepSearchIndexCurrent(entityType: entityType, entityID: entityID, action: action, new: new)
    }

    // MARK: Search index upkeep

    /// Every change to a paper, its authors or its tags passes through `record`, so this is
    /// the one place that keeps the full-text index in step. Before this, nothing added
    /// papers to the index and search found nothing until a manual rebuild.
    ///
    /// A problem here is logged and never undoes the change that was just made.
    private func keepSearchIndexCurrent(
        entityType: String,
        entityID: String,
        action: ChangeAction,
        new: String?
    ) {
        do {
            switch entityType {

            case "item":
                try search.indexItem(id: entityID)

            case "creator" where action == .update || action == .merge:
                for id in try itemIDs(
                    "SELECT DISTINCT item_id FROM item_creators WHERE creator_id = ?",
                    [entityID] + (new.map { [$0] } ?? [])
                ) {
                    try search.indexItem(id: id)
                }

            case "tag" where action == .update || action == .merge:
                for id in try itemIDs(
                    "SELECT DISTINCT item_id FROM item_tags WHERE tag_id = ?",
                    [entityID] + (new.map { [$0] } ?? [])
                ) {
                    try search.indexItem(id: id)
                }

            case "attachment" where action == .create:
                // A new file: let the app read its text into the index (see LibraryHost).
                NotificationCenter.default.post(name: .rbAttachmentAdded, object: nil)

            default:
                break
            }
        } catch {
            AppLogger.shared.warning(
                "Search index could not be updated for \(entityType) \(entityID): \(error.localizedDescription)",
                category: "search"
            )
        }
    }

    /// Item ids found by `sql`, run once for each id in `keys`.
    private func itemIDs(_ sql: String, _ keys: [String]) throws -> [String] {
        var found: [String] = []
        for key in keys {
            let rows = try database.rows(sql, [.text(key)])
            for row in rows {
                if let id = row.text("item_id"), !found.contains(id) { found.append(id) }
            }
        }
        return found
    }

    /// Compact, sorted JSON for the old/new snapshots handed to the change sink.
    /// Use `NSNull()` for missing values.
    static func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// SQL value helpers.
    static func text(_ value: String?) -> SQLValue {
        value.map { .text($0) } ?? .null
    }

    static func int(_ value: Int?) -> SQLValue {
        value.map { .int(Int64($0)) } ?? .null
    }

    static func bool(_ value: Bool) -> SQLValue {
        .int(value ? 1 : 0)
    }
}
